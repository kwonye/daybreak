import AppKit
import CryptoKit
import Darwin
import EvergreenArchive
import Foundation
import Security

struct PublishedRelease: Sendable {
    let version: String
    let artifact: ReleaseArtifact?
}

struct ReleaseArtifact: Sendable, Hashable {
    enum Format: String, Sendable { case dmg, zip }
    enum Checksum: Hashable, Sendable {
        case sha256(String)
        case sha512(Data)
    }

    let url: URL
    let format: Format
    let checksum: Checksum
    let size: Int64?

    static var nativeArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    func matchesArchitecture(_ architecture: String) -> Bool {
        Self.matchesArchitecture(architecture, filename: url.lastPathComponent)
    }

    static func matchesArchitecture(_ architecture: String, filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let marker = architecture == "arm64"
            ? /(^|[._-])(arm64|aarch64|universal)($|[._-])/
            : /(^|[._-])(x64|x86_64|amd64|intel64|universal)($|[._-])/
        return stem.contains(marker)
    }

    init?(url: URL?, sha256: String?, format: Format? = nil, size: Int64? = nil) {
        guard let sha256,
              sha256.wholeMatch(of: /[0-9a-fA-F]{64}/) != nil else { return nil }
        self.init(url: url, checksum: .sha256(sha256.lowercased()), format: format, size: size)
    }

    init?(url: URL?, sha512: String?, size: Int64? = nil) {
        guard let sha512, let value = Data(base64Encoded: sha512), value.count == 64 else { return nil }
        self.init(url: url, checksum: .sha512(value), format: nil, size: size)
    }

    private init?(url: URL?, checksum: Checksum, format: Format?, size: Int64?) {
        guard let url, Self.isHTTPS(url), let format = format ?? Format(rawValue: url.pathExtension.lowercased()),
              size.map({ $0 > 0 }) ?? true else { return nil }
        self.url = url
        self.format = format
        self.checksum = checksum
        self.size = size
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }

    func verify(_ archive: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        if let size, try handle.seekToEnd() != UInt64(size) { throw UpdateRequiresApp() }
        try handle.seek(toOffset: 0)
        func digest<H: HashFunction>(_ hash: H) throws -> H.Digest {
            var hash = hash
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            return hash.finalize()
        }
        switch checksum {
        case .sha256(let expected):
            guard try digest(SHA256()).map({ String(format: "%02x", $0) }).joined() == expected else { throw UpdateRequiresApp() }
        case .sha512(let expected):
            guard try Data(digest(SHA512())) == expected else { throw UpdateRequiresApp() }
        }
    }
}

struct ReleaseInstaller: Sendable {
    let platform: MacApplications
    let process: UpdaterProcess

    func publisher(of app: ManagedApp) -> String? {
        let parent = (app.path as NSString).deletingLastPathComponent
        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        guard !app.isProtected, !app.metadata.version.isEmpty, !app.metadata.executable.isEmpty,
              !app.metadata.hints.contains("app-store"), canonicalPath(app.path) == app.path,
              ["/Applications", homeApps].contains(where: { parent == $0 || parent.hasPrefix($0 + "/") }),
              access(parent, W_OK | X_OK) == 0, access(app.path, W_OK) == 0,
              let team = try? platform.signer(app), Self.isDeveloperID(app.path, team: team) else { return nil }
        return team
    }

    private static func isDeveloperID(_ path: String, team: String) -> Bool {
        guard team.wholeMatch(of: /[A-Z0-9]{10}/) != nil else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        let terms = """
            anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "\(team)"
            """
        var requirement: SecRequirement?
        var code: SecStaticCode?
        return SecRequirementCreateWithString(terms as CFString, [], &requirement) == errSecSuccess
            && SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess
            && code.map { SecStaticCodeCheckValidity($0, flags, requirement) == errSecSuccess } == true
    }

    func prepare(_ artifact: ReleaseArtifact, for app: ManagedApp, version: String, team: String) async throws -> StagedRelease {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(for: URLRequest(url: artifact.url), delegate: ReleaseDownloadDelegate())
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, ReleaseArtifact.isHTTPS(url) else {
            throw EngineFailure("Couldn’t download the update. Try again.")
        }
        try artifact.verify(file)
        return try stage(file, format: artifact.format, for: app, version: version, team: team)
    }

    func stage(_ file: URL, format: ReleaseArtifact.Format, for app: ManagedApp, version: String, team: String) throws -> StagedRelease {
        try Task.checkCancellation()
        let files = FileManager.default
        let location = URL(fileURLWithPath: app.path, isDirectory: true)
        let directory = location.deletingLastPathComponent()
            .appendingPathComponent(".evergreen-update-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        var staged = false
        defer { if !staged { try? files.removeItem(at: directory) } }
        let copy = directory.appendingPathComponent(location.lastPathComponent)
        switch format {
        case .dmg: try copyDiskImage(file, to: copy, stagingDirectory: directory)
        case .zip: try unpackZip(file, to: copy, stagingDirectory: directory)
        }
        let offered = try verifyBundle(at: copy, app: app, version: version, team: team)
        guard try process.run(["/usr/sbin/spctl", "--assess", "--type", "execute", copy.path], 60).exitCode == 0 else {
            throw UpdateRequiresApp()
        }
        try Task.checkCancellation()
        staged = true
        return StagedRelease(directory: directory, bundle: copy, version: offered, team: team, platform: platform)
    }

    private func unpackZip(_ zip: URL, to copy: URL, stagingDirectory directory: URL) throws {
        let files = FileManager.default
        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        try files.createDirectory(at: unpacked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard evergreen_extract_zip(zip.path, unpacked.path) else { throw UpdateRequiresApp() }
        let source = try appBundle(in: unpacked)
        guard let entries = files.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw UpdateRequiresApp()
        }
        for case let item as URL in entries {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                guard let resolved = canonicalPath(item.path), resolved.hasPrefix(source.path + "/") else {
                    throw UpdateRequiresApp()
                }
            }
        }
        try files.moveItem(at: source, to: copy)
    }

    private func copyDiskImage(_ image: URL, to copy: URL, stagingDirectory directory: URL) throws {
        let files = FileManager.default
        let mountRoot = directory.appendingPathComponent("mount", isDirectory: true)
        try files.createDirectory(at: mountRoot, withIntermediateDirectories: false)
        defer {
            for mount in (try? files.contentsOfDirectory(at: mountRoot, includingPropertiesForKeys: nil)) ?? [] {
                _ = try? process.checked(["/usr/bin/hdiutil", "detach", mount.path], 30)
            }
        }

        let attached = try process.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse",
                                        "-noautoopen", "-noautofsck", "-mountroot", mountRoot.path, "-plist", image.path], 120)
        let result = (try? PropertyListSerialization.propertyList(from: attached.stdout, format: nil)) as? [String: Any]
        let entities = result?["system-entities"] as? [[String: Any]] ?? []
        let mounts = entities.compactMap { $0["mount-point"] as? String }
        guard attached.exitCode == 0, mounts.count == 1, let root = mounts.first,
              canonicalPath(root) == root, root.hasPrefix(mountRoot.path + "/") else { throw UpdateRequiresApp() }

        let source = try appBundle(in: URL(fileURLWithPath: root))
        _ = try process.checked(["/usr/bin/ditto", "--qtn", source.path, copy.path], 120)
    }

    private func appBundle(in root: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let apps = contents.filter { $0.pathExtension.lowercased() == "app" }
        guard apps.count == 1, let source = apps.first, canonicalPath(source.path) == source.path,
              contents.allSatisfy({ !["pkg", "mpkg"].contains($0.pathExtension.lowercased()) }) else {
            throw UpdateRequiresApp()
        }
        return source
    }

    private func verifyBundle(at url: URL, app: ManagedApp, version: String, team: String) throws -> String {
        guard let info = try? BundleMetadata.info(url.path), info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleIdentifier"] as? String == app.bundleID,
              let offered = info["CFBundleShortVersionString"] as? String,
              ReleaseRepository.compare(version, installed: offered) == .orderedSame,
              ReleaseRepository.compare(offered, installed: app.metadata.version) == .orderedDescending,
              let architectures = Bundle(url: url)?.executableArchitectures else { throw UpdateRequiresApp() }
        #if arch(arm64)
        let arm = NSNumber(value: NSBundleExecutableArchitectureARM64)
        let intel = NSNumber(value: NSBundleExecutableArchitectureX86_64)
        let installed = Bundle(path: app.path)?.executableArchitectures ?? []
        let intelOnly = !installed.contains(arm) && installed.contains(intel)
        let architecture = architectures.contains(arm) || !intelOnly ? arm : intel
        let architectureKey = architecture == arm ? "arm64" : "x86_64"
        #else
        let architecture = NSNumber(value: NSBundleExecutableArchitectureX86_64)
        let architectureKey = "x86_64"
        #endif
        guard architectures.contains(architecture) else { throw UpdateRequiresApp() }
        let minimumVersions = info["LSMinimumSystemVersionByArchitecture"] as? [String: String]
        if let minimum = minimumVersions?[architectureKey] ?? info["LSMinimumSystemVersion"] as? String {
            guard let comparison = ReleaseRepository.compare(minimum, installed: UpdateCatalog.installedOSVersion),
                  comparison != .orderedDescending else { throw UpdateRequiresApp() }
        }
        let metadata = try BundleMetadata.read(url.path, observed: [], fingerprintExecutable: false)
        let candidate = ManagedApp(bundleID: app.bundleID, name: app.name, path: url.path,
                                   processes: [], metadata: metadata, stale: false)
        guard !metadata.executable.isEmpty, !metadata.hints.contains("app-store"),
              Self.isDeveloperID(url.path, team: team),
              (try? platform.signer(candidate)) == team else { throw UpdateRequiresApp() }
        return offered
    }
}

final class ReleaseDownloadDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, ReleaseArtifact.isHTTPS(url) else { return nil }
        return request
    }
}

struct StagedRelease: Sendable {
    let directory: URL
    let bundle: URL
    let version: String
    let team: String
    let platform: MacApplications

    func install(over app: ManagedApp) throws {
        let current = try BundleMetadata.read(app.path, observed: [])
        guard canonicalPath(app.path) == app.path, current.version == app.metadata.version,
              current.build == app.metadata.build, current.fingerprint == app.metadata.fingerprint,
              try platform.current(app).isEmpty else {
            throw EngineFailure("This app changed. Check for updates again.")
        }
        try platform.checkSignature(app, expectedTeam: team)
        guard try platform.current(app).isEmpty else {
            throw EngineFailure("This app opened. Check for updates again.")
        }
        try Task.checkCancellation()
        guard renameatx_np(AT_FDCWD, bundle.path, AT_FDCWD, app.path, UInt32(RENAME_SWAP)) == 0 else {
            throw EngineFailure("Couldn’t replace the installed app (error \(errno)).")
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
