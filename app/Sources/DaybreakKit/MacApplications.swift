import AppKit
import CryptoKit
import Darwin
import Foundation

struct ApplicationIdentity: Hashable {
    let bundleID: String
    let path: String
}

struct ManagedApp: Sendable {
    let bundleID: String
    let name: String
    let path: String
    let processes: [AppProcess]
    let metadata: BundleMetadata
    let stale: Bool

    var identity: ApplicationIdentity { ApplicationIdentity(bundleID: bundleID, path: path) }
    var pids: [Int] { processes.map(\.pid) }
    var protectionReason: String? { InventoryApp.protectionReason(bundleID: bundleID, path: path) }
    var isProtected: Bool { protectionReason != nil }

    func stillMatches(_ running: [AppProcess]) -> Bool {
        !processes.isEmpty && running.count == processes.count && running.allSatisfy { row in
            processes.contains { $0.pid == row.pid && $0.launched == row.launched }
        }
    }

    func matchesPreview(_ target: RunResult) -> Bool {
        guard target.status == .planned, !processes.isEmpty, processes.count == target.oldPIDs.count,
              processes.count == target.originalLaunches.count else { return false }
        return processes.allSatisfy { app in
            app.launched > 0 && zip(target.oldPIDs, target.originalLaunches)
                .contains { $0 == app.pid && $1 == app.launched }
        }
    }

    func inventoryRow(config: EngineConfiguration?) -> [String: Any] {
        var row: [String: Any] = [
            "bundle_id": bundleID, "name": name, "path": path,
            "version": metadata.version, "build": metadata.build, "pids": pids,
            "launches": processes.map(\.launched), "executable": metadata.executable,
            "fingerprint": metadata.fingerprint, "hints": metadata.hints,
            "stale": stale, "executable_source": metadata.executableSource,
        ]
        if let config {
            row["protected"] = isProtected
            row["whitelisted"] = config.whitelisted(bundleID)
        }
        return row
    }
}

struct AppProcess: Decodable, Sendable {
    let bundleID: String
    let name: String
    let path: String
    let pid: Int
    let launched: TimeInterval
    let executable: String

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id", name, path, pid, launched, executable
    }
}

struct BundleMetadata: Sendable {
    let version: String
    let build: String
    let executable: String
    let fingerprint: String
    let hints: [String]
    let executableSource: String

    static func info(_ path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw EngineFailure("Invalid application Info.plist")
        }
        return info
    }

    static func read(_ path: String, observed: [String], fingerprintExecutable: Bool = true) throws -> BundleMetadata {
        let root = URL(fileURLWithPath: path)
        let info = try info(path)
        let declared = info["CFBundleExecutable"]
        var executable = ""
        var source = "unresolved"
        if let name = declared as? String, !name.isEmpty, name != ".", name != "..", !name.contains("/") {
            executable = safeExecutable(root.appendingPathComponent("Contents/MacOS/\(name)").path, root: root, observed: false) ?? ""
            if !executable.isEmpty { source = "plist" }
        } else if declared == nil || (declared as? String) == "" {
            let candidates = Set(observed.compactMap { safeExecutable($0, root: root, observed: true) })
            if candidates.count == 1, let candidate = candidates.first {
                executable = candidate
                source = "running-process"
            }
        }
        var fingerprint = ""
        if fingerprintExecutable && !executable.isEmpty {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: executable))
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let hints = [
            ("sparkle", "Contents/Frameworks/Sparkle.framework"),
            ("squirrel", "Contents/Frameworks/Squirrel.framework"),
            ("electron", "Contents/Frameworks/Electron Framework.framework"),
            ("app-store", "Contents/_MASReceipt/receipt"),
        ].compactMap { hint, relative in FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path) ? hint : nil }
        return BundleMetadata(version: info["CFBundleShortVersionString"].map { String(describing: $0) } ?? "",
                              build: info["CFBundleVersion"].map { String(describing: $0) } ?? "",
                              executable: executable, fingerprint: fingerprint, hints: hints, executableSource: source)
    }

    private static func safeExecutable(_ path: String, root: URL, observed: Bool) -> String? {
        guard path.hasPrefix("/") else { return nil }
        guard let contents = canonicalPath(root.path), let candidate = canonicalPath(path),
              candidate.hasPrefix(contents + "/Contents/"),
              isFile(candidate), FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        if observed {
            let parent = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
            guard parent == canonicalPath(root.appendingPathComponent("Contents/MacOS").path) else { return nil }
        }
        return candidate
    }
}

protocol ApplicationPlatform {
    func inventory() throws -> [ManagedApp]
    func current(_ app: ManagedApp) throws -> [AppProcess]
    func quit(_ app: ManagedApp) throws -> Bool
    func relaunch(_ app: ManagedApp) throws
    func verify(_ app: ManagedApp, since: Date, target: String) throws -> (BundleMetadata, [Int])
    func signer(_ app: ManagedApp) throws -> String
    func checkSignature(_ app: ManagedApp, expectedTeam: String) throws
}

struct MacApplications: ApplicationPlatform, Sendable {
    let process: UpdaterProcess
    let quitTimeout: TimeInterval
    var launchTimeout: TimeInterval = 60

    private func records() throws -> [AppProcess] {
        let records = NSWorkspace.shared.runningApplications.compactMap(Self.record)
        guard !records.isEmpty else {
            throw EngineFailure("No accessible app inventory; run in the logged-in GUI session with process access")
        }
        return records
    }

    private static func record(_ app: NSRunningApplication) -> AppProcess? {
        guard !app.isTerminated, app.activationPolicy != .prohibited,
              let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
        return AppProcess(bundleID: id, name: app.localizedName ?? url.lastPathComponent,
                          path: url.path, pid: Int(app.processIdentifier),
                          launched: app.launchDate?.timeIntervalSince1970 ?? 0,
                          executable: app.executableURL?.path ?? "")
    }

    func inventory() throws -> [ManagedApp] {
        let groups = Dictionary(grouping: try records()) { ApplicationIdentity(bundleID: $0.bundleID, path: $0.path) }
        return try groups.keys.sorted { ($0.bundleID, $0.path) < ($1.bundleID, $1.path) }.compactMap { key in
            guard let rows = groups[key], let first = rows.first,
                  let metadata = try? BundleMetadata.read(key.path, observed: rows.map(\.executable)) else { return nil }
            var stale = false
            for row in rows where !metadata.executable.isEmpty && !stale {
                let output = try process.run(["/usr/sbin/lsof", "-a", "-p", String(row.pid), "-d", "txt", "-Ffni"], 15)
                stale = Self.isStale(String(decoding: output.stdout, as: UTF8.self), executable: metadata.executable)
            }
            return ManagedApp(bundleID: key.bundleID, name: first.name, path: key.path,
                              processes: rows, metadata: metadata, stale: stale)
        }
    }

    /// Inventory for interactive updates, including closed apps and without hashing every binary.
    func installedApps() throws -> [ManagedApp] {
        let records = try records()
        let groups = Dictionary(grouping: records, by: \.path)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var paths = Set(groups.keys)
        for root in roots {
            guard let children = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in children {
                if url.pathExtension.lowercased() == "app" {
                    children.skipDescendants()
                    if let path = canonicalPath(url.path) { paths.insert(path) }
                }
            }
        }
        return paths.compactMap { path in
            guard let info = try? BundleMetadata.info(path),
                  let id = info["CFBundleIdentifier"] as? String, !id.isEmpty,
                  info["CFBundlePackageType"] as? String == "APPL",
                  InventoryApp.protectionReason(bundleID: id, path: path) == nil,
                  let metadata = try? BundleMetadata.read(path, observed: [], fingerprintExecutable: false)
            else { return nil }
            let name = groups[path]?.first?.name
                ?? (FileManager.default.displayName(atPath: path) as NSString).deletingPathExtension
            return ManagedApp(bundleID: id, name: name, path: path, processes: groups[path] ?? [],
                              metadata: metadata, stale: false)
        }.sorted { ($0.name.localizedLowercase, $0.path) < ($1.name.localizedLowercase, $1.path) }
    }

    static func isStale(_ output: String, executable: String) -> Bool {
        guard let inode = try? FileManager.default.attributesOfItem(atPath: executable)[.systemFileNumber] as? NSNumber else { return false }
        var path: String?
        var mappedInode: String?
        for line in output.split(separator: "\n").map(String.init) + ["fEND"] {
            switch line.first {
            case "f":
                if path == executable || path == executable + " (deleted)" {
                    return mappedInode.map { $0 != inode.stringValue } ?? false
                }
                path = nil
                mappedInode = nil
            case "n": path = String(line.dropFirst())
            case "i": mappedInode = String(line.dropFirst())
            default: break
            }
        }
        return false
    }

    func current(_ app: ManagedApp) throws -> [AppProcess] {
        return NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .compactMap(Self.record).filter { $0.path == app.path }
    }

    func quit(_ app: ManagedApp) throws -> Bool {
        guard !app.isProtected else { throw EngineFailure("Protected application") }
        for row in try current(app) {
            if let running = NSRunningApplication(processIdentifier: pid_t(row.pid)),
                      running.bundleIdentifier == app.bundleID, running.bundleURL?.path == app.path,
                      (running.launchDate?.timeIntervalSince1970 ?? 0) == row.launched {
                _ = running.terminate()
            }
        }
        let until = DispatchTime.now() + quitTimeout
        repeat {
            if try current(app).isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while DispatchTime.now() < until
        return false
    }

    func relaunch(_ app: ManagedApp) throws {
        guard !app.isProtected else { throw EngineFailure("Protected application") }
        _ = try process.checked(["/usr/bin/open", "-g", app.path], 15)
    }

    func verify(_ app: ManagedApp, since: Date, target: String) throws -> (BundleMetadata, [Int]) {
        let until = DispatchTime.now() + launchTimeout
        let original = Set(app.pids)
        repeat {
            let rows = try current(app)
            if !rows.isEmpty && !rows.contains(where: { original.contains($0.pid) }) {
                let metadata = try BundleMetadata.read(app.path, observed: [app.metadata.executable])
                guard !metadata.executable.isEmpty, !metadata.fingerprint.isEmpty else {
                    throw EngineFailure("Cannot resolve a unique executable within the app bundle")
                }
                if let pids = Self.verifiedPIDs(rows, metadata: metadata, original: original, since: since, target: target) {
                    return (metadata, pids)
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while DispatchTime.now() < until
        throw EngineFailure("Fresh primary process/path/version verification timed out")
    }

    static func verifiedPIDs(_ rows: [AppProcess], metadata: BundleMetadata,
                             original: Set<Int>, since: Date, target: String) -> [Int]? {
        guard !rows.contains(where: { original.contains($0.pid) }),
              target.isEmpty || target == metadata.version || target == metadata.build else { return nil }
        let primary = rows.filter { !$0.executable.isEmpty && canonicalPath($0.executable) == metadata.executable }
        guard !primary.isEmpty, primary.allSatisfy({ $0.launched >= since.timeIntervalSince1970 - 1 }) else { return nil }
        return primary.map(\.pid)
    }

    func signer(_ app: ManagedApp) throws -> String {
        let verification = try process.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app.path], 120)
        guard verification.exitCode == 0 else {
            if verification.stderrText.contains("resource fork, Finder information, or similar detritus not allowed") {
                throw EngineFailure("Strict signature verification blocked by Finder/resource metadata; no metadata was removed")
            }
            throw EngineFailure("Strict signature verification failed (codesign exited \(verification.exitCode))")
        }
        let result = try process.run(["/usr/bin/codesign", "-dv", "--verbose=4", app.path], 30)
        let prefix = "TeamIdentifier="
        let team = result.stderrText.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) } ?? ""
        guard result.exitCode == 0, !team.isEmpty, team != "not set" else {
            throw EngineFailure("Update requires an existing valid developer signing identity")
        }
        return team
    }

    func checkSignature(_ app: ManagedApp, expectedTeam: String) throws {
        guard try signer(app) == expectedTeam else { throw EngineFailure("Updated app signing team changed; manual review required") }
        guard try BundleMetadata.info(app.path)["CFBundleIdentifier"] as? String == app.bundleID else {
            throw EngineFailure("Updated app bundle identity changed")
        }
    }
}


func canonicalPath(_ path: String) -> String? {
    guard !path.contains("\0"), let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(validatingCString: resolved)
}
