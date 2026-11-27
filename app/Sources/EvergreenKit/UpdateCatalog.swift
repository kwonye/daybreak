import Darwin
import Foundation

public struct UpdateItem: Identifiable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case readyToCheck, available, current, newerRelease, checkInApp, openUpdater, excluded, inconclusive, failed
    }

    public enum Action: Sendable, Equatable {
        case install, openApp, openSystemSettings, openStore, openRelease(URL), openLink(URL)

        public var title: String {
            switch self {
            case .install: "Update"
            case .openApp: "Open App"
            case .openSystemSettings, .openStore, .openLink: "Open Updater"
            case .openRelease: "View Release"
            }
        }
    }

    public let name: String
    public let bundleID: String?
    public let path: String?
    public internal(set) var brewPackage: BrewPackage? = nil
    var brewCanUpgrade = false
    public var id: String { path ?? brewPackage?.id ?? "macos" }
    public let installedVersion: String
    public internal(set) var isRunning: Bool
    public let isMacAppStoreApp: Bool
    public internal(set) var repository: ReleaseRepository?
    public internal(set) var status: Status
    public internal(set) var action: Action?
    public internal(set) var detail = ""
    public internal(set) var offeredVersion = ""

    public func withRunningStatus(_ isRunning: Bool) -> Self {
        var item = self
        item.isRunning = isRunning
        return item
    }
}

struct UpdateCatalog: Sendable {
    private enum Route: Sendable {
        case backend(UpdateBackend)
        case system, store, app, publicCatalog, github(ReleaseRepository)
        case electron(ElectronUpdateFeed)
        case vendor(VendorUpdateFeed)
        case microsoft(String)
    }

    private let config: EngineConfiguration
    private let platform: MacApplications
    private let process: UpdaterProcess
    private let registry: BackendRegistry
    private var brewPackages: BrewPackages? { registry.brew.map { BrewPackages(executable: $0, process: process) } }
    private let repositories: [String: JSONValue]
    private let electronFeeds: [String: JSONValue]
    private let state: NativeState

    init(configURL: URL?, stateDirectory: URL, process: UpdaterProcess = .forGUI(), skip: [String] = []) throws {
        self.process = process
        config = try EngineConfiguration(url: configURL, skip: skip)
        registry = BackendRegistry(process: process, config: config, includeBundledSparkle: true)
        platform = MacApplications(process: process, quitTimeout: config.quitTimeout)
        let document = try configURL.map { try ConfigStore(url: $0).load() }
        if case .object(let mappings) = document?.root["release_repositories"] {
            repositories = mappings
        } else {
            repositories = [:]
        }
        if case .object(let mappings) = document?.root["electron_update_feeds"] {
            electronFeeds = mappings
        } else {
            electronFeeds = [:]
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
        let byUpdaterID = Dictionary(grouping: applications, by: { $0.1 })
        return Dictionary(byUpdaterID.values.compactMap { $0.count == 1 ? $0.first : nil },
                          uniquingKeysWith: { first, _ in first })
    }

    private var system: UpdateItem {
        UpdateItem(name: "macOS", bundleID: nil, path: nil, installedVersion: Self.installedOSVersion, isRunning: true,
                   isMacAppStoreApp: false, repository: nil, status: .readyToCheck, action: .openSystemSettings)
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
            return try scopedBackend(for: app)
        }
        if app.metadata.hints.contains("app-store") { return .store }
        if let appID = microsoft[app.path] { return .microsoft(appID) }
        if let repository = repository(for: app) { return .github(repository) }
        let route = try scopedBackend(for: app)
        guard case .app = route else { return route }
        if let override = electronFeeds[app.bundleID] {
            guard let url = override.stringValue, let feed = ElectronUpdateFeed(app: app, manifestURL: url) else { return .app }
            return .electron(feed)
        }
        if let feed = ElectronUpdateFeed(app: app) { return .electron(feed) }
        if let feed = VendorUpdateFeed(bundleID: app.bundleID) { return .vendor(feed) }
        if app.bundleID == "net.mullvad.vpn", let repository = ReleaseRepository("mullvad/mullvadvpn-app") {
            return .github(repository)
        }
        return .publicCatalog
    }

    private func scopedBackend(for app: ManagedApp) throws -> Route {
        var backend = try registry.backend(for: app)
        if backend.kind == .restart { return .app }
        if backend.kind == .homebrew {
            guard registry.casks.values.count(where: { $0 == backend.identifier }) == 1 else { return .app }
            backend.preventVendorQuit = true
        }
        return .backend(backend)
    }

    private func item(for app: ManagedApp, microsoft: [String: String]) -> (UpdateItem, Route) {
        var item = UpdateItem(name: app.name, bundleID: app.bundleID, path: app.path,
                              installedVersion: app.metadata.version.isEmpty ? app.metadata.build : app.metadata.version,
                              isRunning: !app.processes.isEmpty, isMacAppStoreApp: app.metadata.hints.contains("app-store"),
                              repository: repository(for: app),
                              status: .readyToCheck, action: nil)
        if let name = registry.casks[app.path], !item.isMacAppStoreApp {
            item.brewPackage = BrewPackage(name: name, kind: .cask)
        }
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
        case .publicCatalog, .electron, .vendor:
            item.action = .openApp
        case .store:
            item.action = .openStore
        case .github(let repository):
            item.repository = repository
            item.action = .openRelease(repository.releasesURL)
        case .backend(let backend) where backend.kind == .google:
            item.action = .openLink(URL(string: "chrome://settings/help")!)
        default: break
        }
        return (item, route)
    }

    func inventory() throws -> [UpdateItem] {
        let microsoft = microsoftApps()
        let apps = try platform.installedApps().map { item(for: $0, microsoft: microsoft).0 }
        let matched = Set(apps.compactMap(\.brewPackage))
        let packages = ((try? brewPackages?.installed()) ?? [:]).values.filter { !matched.contains($0.package) }
        return [system] + apps + packages.sorted { ($0.package.name, $0.package.kind.rawValue) < ($1.package.name, $1.package.kind.rawValue) }
            .map(packageItem)
    }

    func scheduledCheckItems(scope: ScheduleScope) throws -> [UpdateItem] {
        let microsoft = microsoftApps()
        let installed = try platform.installedApps()
        let apps = installed.map { app in (app, item(for: app, microsoft: microsoft)) }
        var rows = apps.compactMap { app, entry -> UpdateItem? in
            let (row, route) = entry
            if row.brewPackage != nil, scope != .apps, case .backend(let backend) = route, backend.kind == .homebrew {
                return row
            }
            guard scope != .brew, row.brewPackage == nil, !row.isMacAppStoreApp else { return nil }
            switch route {
            case .publicCatalog, .github, .electron, .vendor: return row
            case .backend where !app.processes.isEmpty:
                return row
            default: return nil
            }
        }
        if scope != .apps, let brew = brewPackages {
            let matched = Set(apps.compactMap { $0.1.0.brewPackage })
            rows += try brew.installed().values.filter { !matched.contains($0.package) }.map(packageItem)
        }
        return rows
    }

    func install(_ target: UpdateItem) async throws -> UpdateItem {
        guard geteuid() != 0, target.action == .install else {
            throw EngineFailure("This update needs to be opened in its updater.")
        }
        if target.path == nil, let package = target.brewPackage {
            return try await state.withAsyncLock { try installPackage(package, target: target) }
        }
        guard let path = target.path else { throw EngineFailure("This update needs to be opened in its updater.") }
        return try await state.withAsyncLock {
            let microsoft = microsoftApps()
            guard let discovered = try platform.installedApps().first(where: { $0.path == path && $0.bundleID == target.bundleID }),
                  !discovered.isProtected, !config.whitelisted(discovered.bundleID), target.isRunning == !discovered.processes.isEmpty,
                  (discovered.metadata.version.isEmpty ? discovered.metadata.build : discovered.metadata.version) == target.installedVersion
            else { throw EngineFailure("This app changed. Check for updates again.") }
            let app = try fingerprinted(discovered)
            let route = try route(for: app, microsoft: microsoft)
            if case .store = route { return try await installStoreApp(app, target: target) }
            let backend: UpdateBackend
            let check: UpdateCheck
            var stagedRelease: StagedRelease?
            defer { stagedRelease?.cleanUp() }
            switch route {
            case .publicCatalog, .github, .electron, .vendor:
                guard target.status == .newerRelease || target.status == .available else {
                    throw EngineFailure("This app’s update action changed. Check again.")
                }
                var manual = item(for: app, microsoft: microsoft).0
                manual.status = target.status
                manual.offeredVersion = target.offeredVersion
                let release: PublishedRelease?
                switch route {
                case .github(let repository):
                    manual.detail = "View the release to update this app."
                    release = try await repository.latestRelease()
                case .electron(let feed):
                    manual.detail = "Open the app to finish updating."
                    release = try await feed.check()
                case .vendor(let feed):
                    manual.detail = "Open the app to finish updating."
                    release = try await feed.release(for: app)
                default:
                    manual.detail = "Open the app to check for updates."
                    guard let catalog = await HomebrewCatalog.fetch() else {
                        throw EngineFailure("Couldn’t confirm the release. Try again.")
                    }
                    release = catalog.newerRelease(
                        bundleID: app.bundleID, appPath: app.path, installed: target.installedVersion
                    )
                }
                guard let release, release.version == target.offeredVersion else { return manual }
                do {
                    guard let staged = try await prepareRelease(release, for: app) else { return manual }
                    stagedRelease = staged
                } catch is UpdateRequiresApp {
                    manual.detail = "Evergreen couldn’t verify this update. " + manual.detail
                    return manual
                }
                backend = UpdateBackend(kind: .release, process: process, stagedRelease: stagedRelease)
                check = try backend.check(app)
            case .backend(var adapter) where adapter.kind != .restart && adapter.kind != .appStore:
                adapter.interactiveInstallation = true
                backend = adapter
                check = try adapter.check(app, interactiveCatalog: true)
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
            if check.requiresUserAction {
                result.status = .available
                result.action = .openApp
                result.detail = check.detail
                return result
            }
            if check.state == .current {
                result.status = .current
                result.action = nil
                result.detail = ""
                result.offeredVersion = ""
                return result
            }
            guard check.state == .available else { throw EngineFailure("Couldn’t confirm an update.") }
            let date = Date()
            let outcome = try applyConfirmed(app, using: backend, check: check)
            try state.save(NativeState.json([
                "started_at": ISO8601DateFormatter().string(from: date), "apply": true,
                "timezone": config.timeZoneID, "results": [outcome.row],
            ]), at: date)
            if outcome.wasCancelled { throw CancellationError() }
            if outcome.needsApp {
                result.action = .openApp
                result.detail = UpdateRequiresApp().localizedDescription
                return result
            }
            switch outcome.status {
            case .updated, .updatedAndRelaunched, .unchanged, .checkedAndRelaunched, .current:
                result = UpdateItem(name: target.name, bundleID: target.bundleID, path: target.path,
                                    brewPackage: target.brewPackage,
                                    installedVersion: outcome.after.isEmpty ? target.installedVersion : outcome.after,
                                    isRunning: target.isRunning, isMacAppStoreApp: target.isMacAppStoreApp,
                                    repository: target.repository,
                                    status: .current, action: nil)
                if outcome.status == .unchanged || (outcome.status == .checkedAndRelaunched && outcome.updateOutcome != "no_update") {
                    result.status = .inconclusive
                    result.detail = "The updater finished. The installed version is unchanged."
                } else if outcome.status == .updated || outcome.status == .updatedAndRelaunched {
                    result.detail = "Update installed."
                }
                return result
            default:
                throw EngineFailure(Self.installFailureMessage(for: outcome))
            }
        }
    }

    private func fingerprinted(_ app: ManagedApp) throws -> ManagedApp {
        let metadata = try BundleMetadata.read(app.path, observed: app.processes.map(\.executable))
        guard !metadata.fingerprint.isEmpty, metadata.version == app.metadata.version, metadata.build == app.metadata.build else {
            throw EngineFailure("Evergreen couldn’t verify this installed copy. Open the app to check.")
        }
        return ManagedApp(bundleID: app.bundleID, name: app.name, path: app.path,
                          processes: app.processes, metadata: metadata, stale: false)
    }

    private func prepareRelease(_ release: PublishedRelease, for app: ManagedApp) async throws -> StagedRelease? {
        let installer = ReleaseInstaller(platform: platform, process: process)
        guard ReleaseRepository.compare(release.version, installed: app.metadata.version) == .orderedDescending,
              let artifact = release.artifact, let team = installer.publisher(of: app) else { return nil }
        return try await installer.prepare(artifact, for: app, version: release.version, team: team)
    }

    private func applyConfirmed(_ app: ManagedApp, using backend: UpdateBackend, check: UpdateCheck) throws -> AppOutcome {
        if app.processes.isEmpty { return try installClosed(app, using: backend, check: check) }
        return UpdateCoordinator(platform: platform, config: config, backend: { _ in backend })
            .handle(app, apply: true, revalidateSelection: true, confirmedUpdate: check)
    }

    /// The scheduler holds the run lock. Every downloaded release uses the same installer as the Apps pane.
    func scheduledReleases(_ installed: [ManagedApp], only: Set<String>) async throws -> [AppOutcome] {
        let eligible = installed.filter { app in
            (only.isEmpty || only.contains(app.bundleID)) && !app.isProtected && !config.whitelisted(app.bundleID) &&
                registry.casks[app.path] == nil && !app.metadata.hints.contains("app-store") &&
                canonicalPath(app.path) == app.path
        }
        guard !eligible.isEmpty else { return [] }
        let microsoft = microsoftApps()
        let releases: [(app: ManagedApp, route: Route)] = eligible.compactMap {
            guard let route = try? route(for: $0, microsoft: microsoft) else { return nil }
            switch route {
            case .publicCatalog, .github, .electron, .vendor: return ($0, route)
            default: return nil
            }
        }
        let publicCatalog: HomebrewCatalog?
        if releases.contains(where: { if case .publicCatalog = $0.route { true } else { false } }) {
            publicCatalog = await HomebrewCatalog.fetch()
        } else {
            publicCatalog = nil
        }
        var outcomes: [AppOutcome] = []
        for (app, route) in releases {
            try Task.checkCancellation()
            do {
                let release: PublishedRelease?
                switch route {
                case .github(let repository): release = try await repository.latestRelease()
                case .electron(let feed): release = try await feed.check()
                case .vendor(let feed): release = try await feed.release(for: app)
                default:
                    release = publicCatalog?.newerRelease(bundleID: app.bundleID, appPath: app.path, installed: app.metadata.version)
                }
                guard let release, ReleaseRepository.compare(release.version, installed: app.metadata.version) == .orderedDescending
                else { continue }
                let current = try fingerprinted(app)
                guard let staged = try await prepareRelease(release, for: current) else {
                    throw UpdateRequiresApp()
                }
                defer { staged.cleanUp() }
                let backend = UpdateBackend(kind: .release, process: process, stagedRelease: staged)
                outcomes.append(try applyConfirmed(current, using: backend, check: backend.check(current)))
            } catch is CancellationError {
                throw CancellationError()
            } catch is UpdateRequiresApp {
                outcomes.append(AppOutcome(app: app, status: .unsupported, detail: "A newer release needs to be installed manually."))
            } catch {
                outcomes.append(AppOutcome(app: app, status: .failed, detail: error.localizedDescription))
            }
        }
        return outcomes
    }

    private func packageItem(_ installed: BrewPackages.Installed) -> UpdateItem {
        UpdateItem(name: installed.package.name, bundleID: nil, path: nil, brewPackage: installed.package,
                   brewCanUpgrade: installed.canUpgrade,
                   installedVersion: installed.version, isRunning: false, isMacAppStoreApp: false,
                   repository: nil, status: installed.pinned ? .excluded : .readyToCheck, action: nil,
                   detail: installed.pinned ? "Pinned in Homebrew." : "")
    }

    private func packageResult(_ target: UpdateItem, offers: [String: BrewPackages.Offer]?,
                               canUpgrade: Bool) -> UpdateItem {
        var item = target
        guard let package = item.brewPackage, let offers else {
            item.status = .failed
            item.action = nil
            item.detail = "Couldn’t check Homebrew. Try again."
            return item
        }
        if let offer = offers[package.offerID] {
            let canInstall = canUpgrade && !["HEAD", "latest"].contains(offer.version)
            item.status = offer.pinned ? .excluded : .available
            item.offeredVersion = offer.version
            item.action = !offer.pinned && canInstall ? .install : nil
            item.detail = offer.pinned ? "Pinned in Homebrew." : canInstall ? "" : "Update this package in Terminal."
        } else {
            item.status = .current
            item.action = nil
            item.offeredVersion = ""
            item.detail = ""
        }
        return item
    }

    private func installPackage(_ package: BrewPackage, target: UpdateItem) throws -> UpdateItem {
        guard let brew = brewPackages, let before = try brew.installed()[package] else {
            throw EngineFailure("This Homebrew package is no longer installed. Check for updates again.")
        }
        if before.pinned { return packageItem(before) }
        let offers = try brew.outdated()
        guard let offer = offers[package.offerID] else { return packageResult(packageItem(before), offers: offers, canUpgrade: false) }
        guard before.canUpgrade, !offer.pinned, !["HEAD", "latest"].contains(offer.version), before.version == target.installedVersion,
              offer.version == target.offeredVersion else {
            throw EngineFailure("This Homebrew package changed. Check for updates again.")
        }
        try Task.checkCancellation()
        let date = Date()
        let (outcome, after) = upgradePackage(before, offer: offer, brew: brew)
        try state.save(NativeState.json([
            "started_at": ISO8601DateFormatter().string(from: date), "apply": true,
            "timezone": config.timeZoneID, "results": [outcome.row],
        ]), at: date)
        guard let after else {
            throw EngineFailure(outcome.status == .uncertain ? "The Homebrew upgrade timed out. Check its status before retrying."
                                : "Couldn’t complete the Homebrew upgrade. See History for details.")
        }
        var result = packageItem(after)
        result.status = .current
        result.detail = "Update installed."
        return result
    }

    private func upgradePackage(_ before: BrewPackages.Installed, offer: BrewPackages.Offer, brew: BrewPackages)
        -> (AppOutcome, BrewPackages.Installed?) {
        var outcome = AppOutcome(package: before.package, before: before.version)
        do {
            try brew.upgrade(before.package)
            guard let after = try brew.installed()[before.package], after.versions != before.versions,
                  after.versions.contains(offer.version) else {
                throw EngineFailure("The installed package did not match the offered version.")
            }
            outcome.status = .updated
            outcome.after = after.version
            outcome.verification = "Homebrew reports the offered version installed."
            return (outcome, after)
        } catch {
            outcome.status = error is UpdaterTimeout ? .uncertain : .failed
            outcome.detail = error.localizedDescription
            return (outcome, nil)
        }
    }

    /// Called under the same run lock as the scheduled app updates.
    func scheduledBrew(apply: Bool, only: Set<String>) throws -> [AppOutcome] {
        guard let brew = brewPackages else {
            return [AppOutcome(package: nil, status: .failed, detail: "Homebrew is unavailable.")]
        }
        let installed = try brew.installed()
        let offers = try brew.outdated()
        let apps = registry.casks.isEmpty ? [] : try platform.installedApps()
        let byCask = Dictionary(grouping: apps.compactMap { app in
            registry.casks[app.path].map { (name: $0, app: app) }
        }, by: \.name)
        var results: [AppOutcome] = []
        for before in installed.values.sorted(by: { $0.package.id < $1.package.id }) {
            let package = before.package
            guard let offer = offers[package.offerID] else { continue }
            let caskApps = package.kind == .cask ? byCask[package.name] ?? [] : []
            if !only.isEmpty && !caskApps.contains(where: { only.contains($0.app.bundleID) }) { continue }
            let outcome: AppOutcome
            if before.pinned || offer.pinned {
                outcome = AppOutcome(package: package, before: before.version, status: .excluded, detail: "Pinned in Homebrew.")
            } else if caskApps.count == 1, let app = caskApps.first?.app {
                outcome = scheduledCask(app, apply: apply)
            } else {
                outcome = scheduledPackage(before, offer: offer, brew: brew, apply: apply)
            }
            results.append(outcome)
            if outcome.status == .uncertain { break }
        }
        return results
    }

    private func scheduledPackage(_ before: BrewPackages.Installed, offer: BrewPackages.Offer,
                                  brew: BrewPackages, apply: Bool) -> AppOutcome {
        let package = before.package
        guard before.canUpgrade, !["HEAD", "latest"].contains(offer.version) else {
            return AppOutcome(package: package, before: before.version, status: .unsupported, detail: "Open Terminal to update this package.")
        }
        guard apply else {
            return AppOutcome(package: package, before: before.version, detail: "Update to \(offer.version).")
        }
        do {
            guard let current = try brew.installed()[package], current.canUpgrade, !current.pinned,
                  let currentOffer = try brew.outdated()[package.offerID], !currentOffer.pinned else {
                return AppOutcome(package: package, before: before.version, status: .skipped, detail: "The update is no longer eligible.")
            }
            guard current.version == before.version, currentOffer.version == offer.version else {
                return AppOutcome(package: package, before: before.version, status: .skipped, detail: "The offered or installed version changed.")
            }
            return upgradePackage(current, offer: currentOffer, brew: brew).0
        } catch {
            return AppOutcome(package: package, before: before.version, status: .failed, detail: error.localizedDescription)
        }
    }

    private func scheduledCask(_ app: ManagedApp, apply: Bool) -> AppOutcome {
        if config.whitelisted(app.bundleID) {
            return AppOutcome(app: app, status: .excluded, detail: "Whitelisted by configuration.")
        }
        do {
            guard case .backend(var backend) = try scopedBackend(for: app), backend.kind == .homebrew else {
                return AppOutcome(app: app, status: .unsupported, detail: "This cask needs to be updated manually.")
            }
            guard apply else { return AppOutcome(app: app, detail: "Install the available update.") }
            backend.interactiveInstallation = true
            let updater = backend
            let check = try updater.check(app)
            guard check.state == .available else { return AppOutcome(app: app, status: .current) }
            let metadata = try BundleMetadata.read(app.path, observed: app.processes.map(\.executable))
            guard !metadata.fingerprint.isEmpty, metadata.version == app.metadata.version, metadata.build == app.metadata.build else {
                throw EngineFailure("The installed app changed before the update.")
            }
            let current = ManagedApp(bundleID: app.bundleID, name: app.name, path: app.path,
                                     processes: app.processes, metadata: metadata, stale: false)
            if current.processes.isEmpty { return try installClosed(current, using: updater, check: check) }
            return UpdateCoordinator(platform: platform, config: config, backend: { _ in updater })
                .handle(current, apply: true, revalidateSelection: true, confirmedUpdate: check)
        } catch {
            return AppOutcome(app: app, status: .failed, detail: error.localizedDescription)
        }
    }

    static func installFailureMessage(for outcome: AppOutcome) -> String {
        if outcome.status == .deferred { return "The app couldn’t close. Save your work and try again." }
        if outcome.status == .uncertain { return "The update took too long. Check the app before trying again." }
        switch outcome.phase {
        case .preparing: return "Evergreen couldn’t prepare this app for the update. See History for details."
        case .installing: return "The update couldn’t finish installing. See History for details."
        case .verifying: return "Evergreen couldn’t verify the installed copy. See History for details."
        case .reopening: return "Evergreen couldn’t verify the app reopened after the update. See History for details."
        }
    }

    private func installStoreApp(_ app: ManagedApp, target: UpdateItem) async throws -> UpdateItem {
        guard config.directAppStoreUpdates, target.status == .available, canInstallStoreApp(app),
              let id = storeID(for: app).flatMap(UInt64.init) else {
            throw EngineFailure("Direct updates are unavailable for this copy. Open the App Store to update it.")
        }
        let date = Date()
        var outcome = AppOutcome(app: app)
        outcome.backend = "app-store"
        let signer = try platform.signer(app)
        let running = try platform.current(app)
        guard app.processes.isEmpty ? running.isEmpty : app.stillMatches(running) else {
            throw EngineFailure("The app’s running state changed. Check for updates again.")
        }
        let wasRunning = !running.isEmpty
        guard try !wasRunning || platform.quit(app) else {
            throw EngineFailure("The app couldn’t close. Save your work and try again.")
        }
        var installerError: (any Error)?
        do {
            try await NativeStoreUpdate.install(id: id, app: app, process: process)
            try platform.checkSignature(app, expectedTeam: signer)
            let installed = try BundleMetadata.read(app.path, observed: [])
            let receipt = try StoreReceipt(verified: StoreBundleInstaller.readReceipt(app.path + "/Contents/_MASReceipt/receipt"))
            guard receipt.bundleID == app.bundleID, receipt.version == installed.version,
                  StoreBundleInstaller.isStoreSigned(app.path, bundleID: app.bundleID) else {
                throw EngineFailure("The updated App Store copy couldn’t be verified.")
            }
            guard StoreBundleInstaller.versionIncreases(oldVersion: app.metadata.version, oldBuild: app.metadata.build,
                                                        newVersion: installed.version, newBuild: installed.build) else {
                throw EngineFailure("The installed version hasn’t changed. Check the App Store before trying again.")
            }
            outcome.after = installed.version
            outcome.afterBuild = installed.build
            outcome.status = .updated
            outcome.verification = "The App Store bundle identity, signing team, receipt and newer version were checked."
            if wasRunning {
                if try platform.current(app).isEmpty { try platform.relaunch(app) }
                let (_, pids) = try platform.verify(app, since: date, target: installed.version)
                outcome.newPIDs = pids
                outcome.status = .updatedAndRelaunched
            }
        } catch {
            installerError = error
            outcome.status = error is CancellationError ? .deferred : .failed
            outcome.detail = error is CancellationError ? "Administrator approval was cancelled." : error.localizedDescription
            if wasRunning, !outcome.after.isEmpty || error is CancellationError {
                // Reopen only if the copy still verifies. A timed-out store request can finish later.
                if (try? platform.current(app).isEmpty) == true,
                   (try? platform.checkSignature(app, expectedTeam: signer)) != nil {
                    try? platform.relaunch(app)
                }
            }
        }
        try state.save(NativeState.json([
            "started_at": ISO8601DateFormatter().string(from: date), "apply": true,
            "timezone": config.timeZoneID, "results": [outcome.row],
        ]), at: date)
        if let installerError { throw installerError }
        return UpdateItem(name: target.name, bundleID: target.bundleID, path: target.path,
                          installedVersion: outcome.after, isRunning: wasRunning, isMacAppStoreApp: true,
                          repository: target.repository, status: .current, action: .openStore,
                          detail: "Update installed.")
    }

    private func canInstallStoreApp(_ app: ManagedApp) -> Bool {
        config.directAppStoreUpdates && app.metadata.hints.contains("app-store")
            && StoreBundleInstaller.supportedDestination(app.path) && NativeStoreUpdate.isAvailable
            && StoreBundleInstaller.isStoreSigned(app.path, bundleID: app.bundleID)
    }

    private func installClosed(_ app: ManagedApp, using backend: UpdateBackend, check: UpdateCheck) throws -> AppOutcome {
        guard try platform.current(app).isEmpty else { throw EngineFailure("This app opened. Check for updates again.") }
        var outcome = AppOutcome(app: app)
        outcome.backend = backend.kind.rawValue
        do {
            let before = app.metadata
            let signer = try platform.signer(app)
            guard try platform.current(app).isEmpty else { throw EngineFailure("This app opened. Check for updates again.") }
            outcome.phase = .installing
            let result = try backend.apply(app)
            outcome.phase = .verifying
            try platform.checkSignature(app, expectedTeam: signer)
            let after = try BundleMetadata.read(app.path, observed: [])
            outcome.after = after.version
            outcome.afterBuild = after.build
            outcome.updateOutcome = result?.outcome ?? ""
            let appIsClosed = try platform.current(app).isEmpty
            outcome.verification = "Installed bundle identity and signing team verified."
            if let result, result.outcome == "no_update" {
                outcome.status = .current
                outcome.detail = "No update was offered."
            } else {
                guard check.target.isEmpty || check.target == after.version || check.target == after.build else {
                    throw EngineFailure("The installed bundle did not match the offered version.")
                }
                let changed = (before.version, before.build, before.fingerprint) != (after.version, after.build, after.fingerprint)
                outcome.status = changed ? .updated : .unchanged
                outcome.detail = changed ? (appIsClosed ? "Installed update. App was left closed." : "Installed update.")
                    : "Updater finished. Version unchanged."
            }
        } catch is CancellationError {
            outcome.status = .deferred
            outcome.wasCancelled = true
            outcome.detail = "Update authorization was cancelled."
        } catch is UpdateRequiresApp {
            outcome.status = .deferred
            outcome.needsApp = true
            outcome.detail = UpdateRequiresApp().localizedDescription
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
        let discovered = Dictionary(items.compactMap { target -> (String, (app: ManagedApp, item: UpdateItem, route: Route))? in
            guard let path = target.path, let app = apps[path], target.bundleID == app.bundleID else { return nil }
            let (row, route) = item(for: app, microsoft: microsoft)
            return (path, (app, row, route))
        }, uniquingKeysWith: { first, _ in first })
        let needsPublicCatalog = discovered.values.contains { candidate in
            if case .publicCatalog = candidate.route { return true }
            return false
        }
        let publicCatalog = needsPublicCatalog ? Task.detached(priority: .utility) { await HomebrewCatalog.fetch() } : nil
        let stores = items.filter { $0.action == .openStore }
        let store = stores.isEmpty ? nil : Task.detached(priority: .utility) { await storeResults(stores, apps: apps) }
        let microsoftAvailable = apps.values.contains { microsoft[$0.path] != nil }
            ? Task.detached(priority: .utility) { microsoftUpdates() } : nil
        let brewOffers = items.contains { $0.brewPackage != nil }
            ? Task.detached(priority: .utility) { try? brewPackages?.outdated() } : nil
        defer {
            store?.cancel()
            microsoftAvailable?.cancel()
            publicCatalog?.cancel()
            brewOffers?.cancel()
        }
        // Use bounded parallelism. Each app can run an independent network probe.
        for offset in stride(from: 0, to: items.count, by: 6) {
            try Task.checkCancellation()
            let batch = Array(items[offset..<min(offset + 6, items.count)])
            try await withThrowingTaskGroup(of: UpdateItem.self) { group in
                for target in batch {
                    if let path = target.path, let entry = discovered[path], target.bundleID == entry.app.bundleID {
                        group.addTask {
                            try await self.check(entry.item, app: entry.app, route: entry.route, store: store,
                                                 microsoft: microsoftAvailable, publicCatalog: publicCatalog, brewOffers: brewOffers)
                        }
                    } else if target.path == nil, target.brewPackage != nil {
                        group.addTask {
                            guard target.status != .excluded else { return target }
                            return self.packageResult(target, offers: await brewOffers?.value, canUpgrade: target.brewCanUpgrade)
                        }
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

    private func check(_ item: UpdateItem, app: ManagedApp, route: Route, store: Task<[String: StoreResult], Never>?,
                       microsoft: Task<[String: String]?, Never>?,
                       publicCatalog: Task<HomebrewCatalog?, Never>?,
                       brewOffers: Task<[String: BrewPackages.Offer]?, Never>?) async throws -> UpdateItem {
        guard item.status == .readyToCheck else { return item }
        var item = item
        do {
            switch route {
            case .app, .system: break
            case .electron, .vendor:
                let published: PublishedRelease?
                if case .electron(let feed) = route { published = try await feed.check() }
                else if case .vendor(let feed) = route { published = try await feed.release(for: app) }
                else { published = nil }
                guard let release = published,
                      let comparison = ReleaseRepository.compare(release.version, installed: item.installedVersion) else {
                    item.status = .checkInApp
                    break
                }
                if comparison == .orderedDescending {
                    if case .vendor(.firefox) = route { item.status = .newerRelease }
                    else { item.status = .available }
                    item.offeredVersion = release.version
                    item.detail = "Open the app to finish updating."
                    offerReleaseInstall(release, for: app, item: &item)
                } else {
                    item.status = .current
                    item.action = nil
                }
            case .publicCatalog:
                if let release = await publicCatalog?.value?.newerRelease(bundleID: app.bundleID, appPath: app.path,
                                                                          installed: item.installedVersion) {
                    item.status = .newerRelease
                    item.offeredVersion = release.version
                    item.detail = "Open the app to check whether this version is available."
                    offerReleaseInstall(release, for: app, item: &item)
                } else {
                    item.status = .checkInApp
                }
            case .backend(let backend):
                switch backend.kind {
                case .homebrew:
                    return packageResult(item, offers: await brewOffers?.value, canUpgrade: true)
                case .google:
                    _ = try backend.check(app) // Exact registration is required by the engine.
                    item.status = .openUpdater
                    item.action = .install
                    item.detail = "Evergreen can ask this app’s updater to check and install."
                case .docker:
                    let output = try process.checked([backend.executable, "desktop", "update", "--check-only"], 120)
                    if let result = Self.dockerStatus(output) {
                        item.status = result
                        item.action = result == .available ? .install : nil
                    } else {
                        item.status = .openUpdater
                        item.action = .install
                        item.detail = "Evergreen can ask this app’s updater to check and install."
                    }
                default:
                    let result = try backend.check(app, interactiveCatalog: true)
                    switch result.state {
                    case .available:
                        item.status = .available
                        item.action = result.requiresUserAction ? .openApp : .install
                        item.offeredVersion = result.target
                        if result.requiresUserAction { item.detail = result.detail }
                    case .current: item.status = .current
                    case .unknown:
                        item.status = .checkInApp
                        item.action = .openApp
                    }
                }
            case .store:
                switch await store?.value[app.path] {
                case .available(let version, let direct):
                    item.status = .available
                    item.offeredVersion = version
                    if direct && canInstallStoreApp(app) { item.action = .install }
                case .current:
                    item.status = .current
                case nil:
                    item.status = .openUpdater
                }
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
                guard let release = try await repository.latestRelease() else {
                    item.status = .inconclusive
                    item.detail = "No public stable release was found."
                    break
                }
                item.offeredVersion = release.version
                if let comparison = ReleaseRepository.compare(release.version, installed: item.installedVersion) {
                    item.status = comparison == .orderedDescending ? .newerRelease : .current
                    if item.status == .newerRelease { offerReleaseInstall(release, for: app, item: &item) }
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

    private func offerReleaseInstall(_ release: PublishedRelease, for app: ManagedApp, item: inout UpdateItem) {
        guard release.artifact != nil, ReleaseInstaller(platform: platform, process: process).publisher(of: app) != nil else { return }
        item.action = .install
        item.detail = ""
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

    private enum StoreResult: Sendable { case current, available(String, direct: Bool) }

    private func storeResults(_ items: [UpdateItem], apps: [String: ManagedApp]) async -> [String: StoreResult] {
        let local = items.compactMap { item -> (ManagedApp, String)? in
            guard let path = item.path, let app = apps[path], let id = storeListingID(for: app) else { return nil }
            return (app, id)
        }
        guard !local.isEmpty else { return [:] }
        let listings = await AppStoreCatalog.listings(for: Array(Set(local.map(\.1))).sorted())
        var results: [String: StoreResult] = [:]
        for (app, id) in local {
            if let listing = listings[id],
               let comparison = listing.compareMacVersion(bundleID: app.bundleID, installed: app.metadata.version,
                                                           macOS: Self.installedOSVersion) {
                if comparison == .orderedDescending { results[app.path] = .available(listing.version, direct: true) }
                else { results[app.path] = .current }
            }
        }
        let unresolved = local.filter { results[$0.0.path] == nil }
        for offset in stride(from: 0, to: unresolved.count, by: 4) {
            if Task.isCancelled { break }
            await withTaskGroup(of: (String, StoreResult?).self) { group in
                for (app, id) in unresolved[offset..<min(offset + 4, unresolved.count)] {
                    group.addTask {
                        guard let version = await AppStoreCatalog.macStorefrontVersion(id: id),
                              let comparison = ReleaseRepository.compare(version, installed: app.metadata.version)
                        else { return (app.path, nil) }
                        return (app.path, comparison == .orderedDescending ? .available(version, direct: false) : .current)
                    }
                }
                for await (path, result) in group { results[path] = result }
            }
        }
        return results
    }

    private func storeListingID(for app: ManagedApp) -> String? {
        guard let output = try? process.checked(["/usr/bin/mdls", "-raw", "-name", "kMDItemAppStoreAdamID", app.path], 10)
        else { return nil }
        let id = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.wholeMatch(of: /[0-9]+/) != nil ? id : nil
    }

    private func storeID(for app: ManagedApp) -> String? {
        guard let id = storeListingID(for: app) else { return nil }
        let aliases = (try? process.checked(["/usr/bin/mdfind", "kMDItemAppStoreAdamID == \(id)"], 10)) ?? ""
        let paths = Set(aliases.split(whereSeparator: \.isNewline).compactMap { canonicalPath(String($0)) })
        return paths == [app.path] ? id : nil
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
