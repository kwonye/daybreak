import Darwin
import Foundation

public struct UpdateItem: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case readyToCheck, available, current, newerRelease, checkInApp, openUpdater, excluded, inconclusive, failed
    }

    public enum Action: Sendable, Equatable {
        case install, openApp, openSystemSettings, openStore, openRelease(URL), openLink(URL)

        public var title: String {
            switch self {
            case .install: "Update…"
            case .openApp: "Open App"
            case .openSystemSettings, .openStore, .openLink: "Open Updater"
            case .openRelease: "View Release"
            }
        }
    }

    public let name: String
    public let bundleID: String?
    public let path: String?
    public var id: String { path ?? "macos" }
    public let installedVersion: String
    public let isRunning: Bool
    public let repository: ReleaseRepository?
    public internal(set) var status: Status
    public internal(set) var action: Action?
    public internal(set) var detail = ""
    public internal(set) var offeredVersion = ""
}

struct UpdateCatalog: Sendable {
    private enum Route: Sendable {
        case backend(UpdateBackend)
        case system, store, app, github(ReleaseRepository)
        case microsoft(String)
    }

    private let config: EngineConfiguration
    private let platform: MacApplications
    private let process: UpdaterProcess
    private let registry: BackendRegistry
    private let repositories: [String: JSONValue]
    private let state: NativeState

    init(configURL: URL, stateDirectory: URL, process: UpdaterProcess = .forGUI()) throws {
        self.process = process
        config = try EngineConfiguration(url: configURL)
        registry = BackendRegistry(process: process, config: config, includeBundledSparkle: true)
        platform = MacApplications(process: process, quitTimeout: config.quitTimeout)
        let document = try ConfigStore(url: configURL).load()
        if case .object(let mappings) = document.root["release_repositories"] {
            repositories = mappings
        } else {
            repositories = [:]
        }
        state = NativeState(directory: stateDirectory)
    }

    static let installedOSVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    private static let microsoftUpdater = "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"

    /// Only include registered paths, never infer ownership from a vendor-looking bundle identifier.
    private func microsoftApps() -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: Self.microsoftUpdater),
              let result = try? process.checked([Self.microsoftUpdater, "--config", "--format", "plist"], 20),
              let start = result.range(of: "<?xml"), let end = result.range(of: "</plist>"),
              start.lowerBound < end.upperBound,
              let data = result[start.lowerBound..<end.upperBound].data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let apps = plist["RegisteredApplications"] as? [String: [String: Any]] else { return [:] }
        let applications: [(String, String)] = apps.compactMap { path, fields in
            guard let id = fields["Application ID"] as? String, id.wholeMatch(of: /[A-Za-z0-9]{3,16}/) != nil,
                  let resolved = canonicalPath(path) else { return nil }
            return (resolved, id)
        }
        return Dictionary(applications, uniquingKeysWith: { first, _ in first })
    }

    private var system: UpdateItem {
        UpdateItem(name: "macOS", bundleID: nil, path: nil, installedVersion: Self.installedOSVersion, isRunning: true,
                   repository: nil, status: .readyToCheck, action: .openSystemSettings)
    }

    private func repository(for app: ManagedApp) -> ReleaseRepository? {
        repositories[app.bundleID]?.stringValue.flatMap(ReleaseRepository.init)
    }

    private func route(for app: ManagedApp, microsoft: [String: String]) throws -> Route {
        let spec = config.apps[app.bundleID] ?? [:]
        if let kind = spec["backend"]?.stringValue, !kind.isEmpty {
            if kind == "restart-only" {
                return repository(for: app).map(Route.github) ?? .app
            }
            if kind == "app-store" { return .store }
            if kind == "docker", spec["allow_workload_interruption"]?.boolValue != true { return .app }
            return .backend(try registry.backend(for: app))
        }
        if app.metadata.hints.contains("app-store") { return .store }
        if let appID = microsoft[app.path] { return .microsoft(appID) }
        if let repository = repository(for: app) { return .github(repository) }
        let backend = try registry.backend(for: app)
        if backend.kind != .restart { return .backend(backend) }
        return .app
    }

    private func item(for app: ManagedApp, microsoft: [String: String]) -> (UpdateItem, Route) {
        var item = UpdateItem(name: app.name, bundleID: app.bundleID, path: app.path,
                              installedVersion: app.metadata.version.isEmpty ? app.metadata.build : app.metadata.version,
                              isRunning: !app.processes.isEmpty, repository: repository(for: app),
                              status: .readyToCheck, action: nil)
        if config.whitelisted(app.bundleID) {
            item.status = .excluded
            item.detail = "Excluded by your whitelist."
            return (item, .app)
        }
        let route: Route
        do { route = try self.route(for: app, microsoft: microsoft) }
        catch {
            item.status = .failed
            item.detail = "This app’s configured updater couldn’t be used."
            item.action = .openApp
            return (item, .app)
        }
        switch route {
        case .app:
            item.status = .checkInApp
            item.action = .openApp
        case .store:
            item.action = .openStore
        case .github(let repository):
            item.action = .openRelease(repository.releasesURL)
        case .backend(let backend) where backend.kind == .google:
            item.action = .openLink(URL(string: "chrome://settings/help")!)
        default: break
        }
        return (item, route)
    }

    func inventory() throws -> [UpdateItem] {
        let microsoft = microsoftApps()
        return [system] + (try platform.installedApps().map { item(for: $0, microsoft: microsoft).0 })
    }

    func install(_ target: UpdateItem) throws -> UpdateItem {
        guard geteuid() != 0, target.action == .install, let path = target.path else {
            throw EngineFailure("This update needs to be opened in its updater.")
        }
        return try state.withLock {
            let microsoft = microsoftApps()
            guard let app = try platform.installedApps().first(where: { $0.path == path && $0.bundleID == target.bundleID }),
                  !app.isProtected, !config.whitelisted(app.bundleID), target.isRunning == !app.processes.isEmpty,
                  (app.metadata.version.isEmpty ? app.metadata.build : app.metadata.version) == target.installedVersion
            else { throw EngineFailure("This app changed. Check for updates again.") }
            let backend: UpdateBackend
            let check: UpdateCheck
            switch try route(for: app, microsoft: microsoft) {
            case .backend(let adapter) where adapter.kind != .restart && adapter.kind != .appStore:
                backend = adapter
                check = try adapter.check(app)
            case .microsoft(let id):
                backend = UpdateBackend(kind: .microsoft, process: process, executable: Self.microsoftUpdater, identifier: id)
                guard let updates = microsoftUpdates() else {
                    throw EngineFailure("Couldn’t confirm an update. Open the app to check.")
                }
                check = UpdateCheck(state: updates[id] == nil ? .current : .available)
            default:
                throw EngineFailure("This app’s update action changed. Check again.")
            }

            var result = target
            if check.state == .current {
                result.status = .current
                result.action = nil
                result.detail = ""
                result.offeredVersion = ""
                return result
            }
            guard check.state == .available else { throw EngineFailure("Couldn’t confirm an update.") }
            let date = Date()
            let outcome: AppOutcome
            if target.isRunning {
                let coordinator = UpdateCoordinator(platform: platform, config: config, backend: { _ in backend })
                outcome = coordinator.handle(app, apply: true, revalidateSelection: true, confirmedUpdate: check)
            } else {
                outcome = try installClosed(app, using: backend, check: check)
            }
            try state.save(NativeState.json([
                "started_at": ISO8601DateFormatter().string(from: date), "apply": true,
                "timezone": config.timeZoneID, "results": [outcome.row],
            ]), at: date)
            switch outcome.status {
            case .updated, .updatedAndRelaunched, .unchanged, .checkedAndRelaunched, .current:
                result = UpdateItem(name: target.name, bundleID: target.bundleID, path: target.path,
                                    installedVersion: outcome.after.isEmpty ? target.installedVersion : outcome.after,
                                    isRunning: target.isRunning, repository: target.repository,
                                    status: .current, action: nil)
                if outcome.status == .unchanged || (outcome.status == .checkedAndRelaunched && outcome.updateOutcome != "no_update") {
                    result.status = .inconclusive
                    result.detail = "The updater finished. The installed version is unchanged."
                } else if outcome.status == .updated || outcome.status == .updatedAndRelaunched {
                    result.detail = "Update installed."
                }
                return result
            default:
                throw EngineFailure(outcome.status == .deferred
                                    ? "The app couldn’t close. Save your work and try again."
                                    : "Daybreak couldn’t verify the update. See History for details.")
            }
        }
    }

    private func installClosed(_ app: ManagedApp, using backend: UpdateBackend, check: UpdateCheck) throws -> AppOutcome {
        guard try platform.current(app).isEmpty else { throw EngineFailure("This app opened. Check for updates again.") }
        var outcome = AppOutcome(app: app)
        outcome.backend = backend.kind.rawValue
        do {
            let before = try BundleMetadata.read(app.path, observed: [])
            let signer = try platform.signer(app)
            guard try platform.current(app).isEmpty else { throw EngineFailure("This app opened. Check for updates again.") }
            let result = try backend.apply(app)
            try platform.checkSignature(app, expectedTeam: signer)
            let after = try BundleMetadata.read(app.path, observed: [])
            outcome.after = after.version
            outcome.afterBuild = after.build
            outcome.updateOutcome = result?.outcome ?? ""
            outcome.verification = "Installed bundle identity and signing team verified. App was left closed."
            if let result, result.outcome == "no_update" {
                outcome.status = .current
                outcome.detail = "No update was offered. App was left closed."
            } else {
                guard check.target.isEmpty || check.target == after.version || check.target == after.build else {
                    throw EngineFailure("The installed bundle did not match the offered version.")
                }
                let changed = (before.version, before.build, before.fingerprint) != (after.version, after.build, after.fingerprint)
                outcome.status = changed ? .updated : .unchanged
                outcome.detail = changed ? "Installed update. App was left closed." : "Updater finished. Version unchanged."
            }
        } catch let error as UpdaterTimeout {
            outcome.status = .uncertain
            outcome.detail = error.localizedDescription
        } catch {
            outcome.status = .failed
            outcome.detail = error.localizedDescription
        }
        return outcome
    }

    func check(_ items: [UpdateItem], progress: @Sendable (UpdateItem) async -> Void) async throws {
        let microsoft = microsoftApps()
        let apps = try Dictionary(uniqueKeysWithValues: platform.installedApps().map { ($0.path, $0) })
        let storeIDs = Set(items.compactMap { row in row.action == .openStore ? row.bundleID : nil })
        let store = storeIDs.isEmpty ? nil : Task.detached(priority: .utility) { storeUpdates() }
        let microsoftAvailable = apps.values.contains { microsoft[$0.path] != nil }
            ? Task.detached(priority: .utility) { microsoftUpdates() } : nil
        defer {
            store?.cancel()
            microsoftAvailable?.cancel()
        }
        // Use bounded parallelism. Each app can run an independent network probe.
        for offset in stride(from: 0, to: items.count, by: 6) {
            try Task.checkCancellation()
            let batch = Array(items[offset..<min(offset + 6, items.count)])
            try await withThrowingTaskGroup(of: UpdateItem.self) { group in
                for target in batch {
                    if let path = target.path, let app = apps[path], target.bundleID == app.bundleID {
                        let (row, route) = item(for: app, microsoft: microsoft)
                        group.addTask { try await self.check(row, app: app, route: route, store: store, microsoft: microsoftAvailable) }
                    } else if target.path == nil {
                        group.addTask { self.checkSystem() }
                    } else {
                        var missing = target
                        missing.status = .inconclusive
                        missing.detail = "This app moved or was removed."
                        missing.action = nil
                        await progress(missing)
                    }
                }
                for try await result in group { await progress(result) }
            }
        }
    }

    private func check(_ item: UpdateItem, app: ManagedApp, route: Route, store: Task<StoreUpdates?, Never>?,
                       microsoft: Task<[String: String]?, Never>?) async throws -> UpdateItem {
        guard item.status == .readyToCheck else { return item }
        var item = item
        do {
            switch route {
            case .app, .system: break
            case .backend(let backend):
                switch backend.kind {
                case .google:
                    _ = try backend.check(app) // Exact registration is required by the engine.
                    item.status = .openUpdater
                    item.action = .install
                    item.detail = "Daybreak can ask this app’s updater to check and install."
                case .docker:
                    let output = try process.checked([backend.executable, "desktop", "update", "--check-only"], 120)
                    if let result = Self.dockerStatus(output) {
                        item.status = result
                        item.action = result == .available ? .install : nil
                    } else {
                        item.status = .openUpdater
                        item.action = .install
                        item.detail = "Daybreak can ask this app’s updater to check and install."
                    }
                default:
                    let result = try backend.check(app)
                    switch result.state {
                    case .available:
                        item.status = .available
                        item.action = .install
                        item.offeredVersion = result.target
                    case .current: item.status = .current
                    case .unknown:
                        item.status = .checkInApp
                        item.action = .openApp
                    }
                }
            case .store:
                guard let store = await store?.value, let id = storeID(for: app), store.installed.contains(id) else {
                    item.status = .openUpdater
                    item.detail = "Open Updates to see what’s available for your account."
                    break
                }
                item.status = store.outdated[id] != nil ? .available : .current
                item.offeredVersion = store.outdated[id] ?? ""
            case .microsoft(let id):
                guard let microsoft = await microsoft?.value else {
                    item.status = .openUpdater
                    item.action = .openApp
                    item.detail = "Open the app to check for updates."
                    break
                }
                item.status = microsoft[id] != nil ? .available : .current
                item.offeredVersion = microsoft[id] ?? ""
                item.action = item.status == .available ? .install : nil
            case .github(let repository):
                guard let tag = try await repository.latestTag() else {
                    item.status = .inconclusive
                    item.detail = "No public stable release was found."
                    break
                }
                item.offeredVersion = tag
                if let comparison = ReleaseRepository.compare(tag, installed: item.installedVersion) {
                    item.status = comparison == .orderedDescending ? .newerRelease : .current
                } else {
                    item.status = .inconclusive
                    item.detail = "The published version uses a different format."
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            item.status = .failed
            item.detail = "Couldn’t check this app. Try again or open it to check."
            if item.action == nil { item.action = .openApp }
        }
        return item
    }

    private func checkSystem() -> UpdateItem {
        var item = system
        do {
            let result = try process.run(["/usr/sbin/softwareupdate", "--list"], 120)
            guard result.exitCode == 0 else { throw EngineFailure("Software Update could not complete the check.") }
            let output = String(decoding: result.stdout, as: UTF8.self) + "\n" + result.stderrText
            let updates = Self.systemLabels(output)
            if !updates.isEmpty {
                item.status = .available
                item.detail = updates.joined(separator: ", ")
            } else if output.localizedCaseInsensitiveContains("No new software available") {
                item.status = .current
            } else {
                item.status = .inconclusive
                item.detail = "Open System Settings to check."
            }
        } catch {
            item.status = .failed
            item.detail = "Couldn’t check for system updates. Open System Settings to retry."
        }
        return item
    }

    static func systemLabels(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("* Label:") else { return nil }
            return text.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    static func dockerStatus(_ output: String) -> UpdateItem.Status? {
        let output = output.lowercased()
        if output.contains("up to date") || output.contains("no update available") { return .current }
        if output.contains("update available") || output.contains("update is available") { return .available }
        return nil
    }

    private struct StoreUpdates: Sendable { let installed: Set<String>; let outdated: [String: String] }

    private func storeID(for app: ManagedApp) -> String? {
        guard let output = try? process.checked(["/usr/bin/mdls", "-raw", "-name", "kMDItemAppStoreAdamID", app.path], 10)
        else { return nil }
        let id = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.wholeMatch(of: /[0-9]+/) != nil else { return nil }
        let aliases = (try? process.checked(["/usr/bin/mdfind", "kMDItemAppStoreAdamID == \(id)"], 10)) ?? ""
        let paths = Set(aliases.split(whereSeparator: \.isNewline).compactMap { canonicalPath(String($0)) })
        return paths == [app.path] ? id : nil
    }

    private func storeUpdates() -> StoreUpdates? {
        guard let mas = process.executable(named: "mas"),
              let installed = try? process.checked([mas, "list"], 30),
              let outdated = try? process.checked([mas, "outdated"], 90) else { return nil }
        func rows(_ text: String) -> [Substring] { text.split(whereSeparator: \.isNewline) }
        func id(_ line: Substring) -> String? {
            guard let value = line.split(whereSeparator: \.isWhitespace).first,
                  value.wholeMatch(of: /[0-9]+/) != nil else { return nil }
            return String(value)
        }
        return StoreUpdates(installed: Set(rows(installed).compactMap(id)),
                            outdated: Dictionary(rows(outdated).compactMap { line in
            id(line).map { ($0, "") }
        }, uniquingKeysWith: { first, _ in first }))
    }

    private func microsoftUpdates() -> [String: String]? {
        guard let output = try? process.checked([Self.microsoftUpdater, "--list", "--format", "plist"], 120) else { return nil }
        return Self.microsoftVersions(output)
    }

    static func microsoftVersions(_ output: String) -> [String: String]? {
        if let start = output.range(of: "<?xml"), let end = output.range(of: "</plist>"),
           start.lowerBound < end.upperBound,
           let plist = try? PropertyListSerialization.propertyList(
            from: Data(output[start.lowerBound..<end.upperBound].utf8), format: nil
           ) {
            func updates(_ value: Any) -> [(String, String)] {
                if let list = value as? [Any] { return list.flatMap(updates) }
                guard let fields = value as? [String: Any] else { return [] }
                let id = (fields["Application ID"] ?? fields["AppID"] ?? fields["ApplicationID"]) as? String
                if let id {
                    return [(id, (fields["Version"] ?? fields["UpdateVersion"]) as? String ?? "")]
                }
                return fields.values.flatMap(updates)
            }
            let rows = updates(plist)
            if !rows.isEmpty { return Dictionary(rows, uniquingKeysWith: { first, _ in first }) }
        }
        return output.localizedCaseInsensitiveContains("No updates available") ? [:] : nil
    }
}
