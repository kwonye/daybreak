import AppKit
import EvergreenKit
import Observation

@MainActor
@Observable
final class UpdatesModel {
    enum Scope: Equatable {
        case software, brew

        func includes(_ item: UpdateItem) -> Bool {
            switch self {
            case .software: item.brewPackage == nil
            case .brew: item.brewPackage != nil
            }
        }
    }

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private weak var cacheClient: EngineClient?
    @ObservationIgnored private var recentCheck: UpdateCheckCache?
    @ObservationIgnored private var launchCheckStarted = false
    @ObservationIgnored private var displayedWhitelist: [String] = []
    private(set) var items: [UpdateItem] = []
    private(set) var state: LoadState = .idle
    private(set) var isChecking = false
    private(set) var installingID: String?
    private(set) var installingScope: Scope?
    private var batchProgress: (current: Int, total: Int)?
    private(set) var checkedAt: Date?
    var error: String?
    private(set) var offerAppStoreOnError = false

    init(app: AppModel) { self.app = app }

    var isBusy: Bool { isChecking || state.isLoading || installingID != nil }
    var canCheck: Bool { !isBusy && app.isEngineReady && !app.scheduler.isBusy }
    func batchProgress(in scope: Scope) -> (current: Int, total: Int)? {
        installingScope == scope ? batchProgress : nil
    }
    func updateCount(in scope: Scope) -> Int {
        items.count {
            scope.includes($0) && ($0.status == .available || ($0.status == .newerRelease && $0.action == .install))
        }
    }
    func batchCandidates(in scope: Scope) -> [UpdateItem] {
        items.filter { scope.includes($0) && ($0.status == .available || $0.status == .newerRelease) && $0.action == .install }
    }

    func load() async {
        let needsInventory = state == .idle || cacheClient !== app.client
        if needsInventory {
            await reloadInventory()
        } else if state == .loaded, !isBusy, displayedWhitelist != app.config.patterns {
            // Whitelist edits invalidate affected rows without checking every app again.
            let previous = UpdateCheckCache(attemptedAt: Date(), checkedAt: checkedAt,
                                            items: items.filter { $0.status != .excluded })
            await reloadInventory(preserving: previous)
        }
        guard state == .loaded, launchCheckStarted else { return }
        await check(automatic: true, reuseInventory: needsInventory)
    }

    private func reloadInventory(preserving previous: UpdateCheckCache? = nil) async {
        guard let client = app.client else { return }
        app.refreshHomebrewAvailability()
        if let loading {
            await loading.value
            return
        }
        state = .loading
        let task = Task {
            do {
                let patterns = app.config.patterns
                let inventory = try await client.updateInventory()
                displayedWhitelist = patterns
                if cacheClient !== client {
                    let cached = await client.cachedUpdateCheck()
                    recentCheck = cached?.check
                    checkedAt = cached?.matchesConfig == true ? cached?.check.checkedAt : nil
                    items = cached?.matchesConfig == true ? cached?.check.restore(into: inventory) ?? inventory : inventory
                    cacheClient = client
                } else {
                    items = previous?.restore(into: inventory) ?? inventory
                }
                state = .loaded
            } catch {
                state = .failed("Evergreen couldn’t read your installed apps or configuration.")
            }
        }
        loading = task
        await task.value
        loading = nil
    }

    func check() async {
        await check(automatic: false, reuseInventory: false)
    }

    func checkOnLaunch() {
        guard !launchCheckStarted else { return }
        launchCheckStarted = true
        // Opening the app is a new check. Pane-driven checks use the cooldown.
        _ = startCheck(automatic: false, reuseInventory: state == .loaded && cacheClient === app.client)
    }

    private func check(automatic: Bool, reuseInventory: Bool) async {
        await startCheck(automatic: automatic, reuseInventory: reuseInventory)?.value
    }

    private func startCheck(automatic: Bool, reuseInventory: Bool) -> Task<Void, Never>? {
        guard !isChecking, installingID == nil, !app.scheduler.isBusy, let client = app.client else { return nil }
        if automatic, recentCheck?.allowsAutomaticCheck(at: Date()) == false { return nil }
        isChecking = true
        offerAppStoreOnError = false
        error = nil
        // A check belongs to the app, so leaving the pane doesn't cancel it.
        return Task { await performCheck(client, reuseInventory: reuseInventory) }
    }

    private func performCheck(_ client: EngineClient, reuseInventory: Bool) async {
        defer { isChecking = false }
        let previousItems = items
        let previousDate = checkedAt
        if !reuseInventory { await reloadInventory() }
        guard state == .loaded else { return }
        let started = Date()
        let fingerprint = await client.updateConfigFingerprint()
        let attempted = UpdateCheckCache(attemptedAt: started, checkedAt: previousDate ?? checkedAt,
                                         items: previousItems.isEmpty ? items : previousItems)
        recentCheck = attempted
        try? await client.saveUpdateCheck(attempted, configFingerprint: fingerprint)
        checkedAt = nil
        do {
            try await client.checkForUpdates(items) { [weak self] result in
                await self?.replace(result)
            }
            checkedAt = Date()
            let completed = UpdateCheckCache(attemptedAt: started, checkedAt: checkedAt, items: items)
            recentCheck = completed
            try? await client.saveUpdateCheck(completed, configFingerprint: fingerprint)
        } catch is CancellationError {
            return
        } catch {
            self.error = "The check couldn’t finish. Try again."
        }
    }

    func install(_ item: UpdateItem) async {
        await install([item], asBatch: false)
    }

    func installAll(_ approved: [UpdateItem], in scope: Scope) async {
        let current = Set(batchCandidates(in: scope).map(\.id))
        await install(approved.filter { current.contains($0.id) }, asBatch: true)
    }

    private func install(_ targets: [UpdateItem], asBatch: Bool) async {
        guard canCheck, let first = targets.first, first.action == .install, let client = app.client else { return }
        installingScope = Scope.brew.includes(first) ? .brew : .software
        installingID = first.id
        error = nil
        offerAppStoreOnError = false
        defer {
            installingID = nil
            installingScope = nil
            batchProgress = nil
        }
        var messages: [String] = []
        for (index, item) in targets.enumerated() {
            installingID = item.id
            if asBatch { batchProgress = (index + 1, targets.count) }
            do {
                replace(try await client.installUpdate(item))
            } catch is CancellationError {
                if asBatch { messages.append("Update All stopped. Any remaining apps can be updated later.") }
                break
            } catch {
                let message = error.localizedDescription
                messages.append(asBatch ? "\(item.name)\n\(message)" : message)
                offerAppStoreOnError = offerAppStoreOnError || item.isMacAppStoreApp
            }
        }
        await app.history.refresh()
        await app.inventory.refresh()
        if !messages.isEmpty { error = messages.joined(separator: "\n\n") }
    }

    func open(_ item: UpdateItem) {
        guard let action = item.action else { return }
        let url: URL?
        switch action {
        case .install: return
        case .openApp:
            if let path = item.path, let bundleID = item.bundleID {
                openApp(at: path, bundleID: bundleID, name: item.name)
                return
            }
            url = nil
        case .openSystemSettings:
            openSystemSettings()
            return
        case .openStore:
            openAppStore()
            return
        case .openRelease(let link), .openLink(let link):
            url = link
        }
        if let url, NSWorkspace.shared.open(url) { return }
        error = "Evergreen couldn’t open the update for \(item.name)."
    }

    private func openApp(at path: String, bundleID: String, name: String) {
        let identity = ApplicationIdentity(bundleID: bundleID, path: path)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        if let exact = running.first(where: { app in
            app.bundleURL.map { ApplicationIdentity(bundleID: bundleID, path: $0.path) == identity } == true
        }) {
            exact.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = !running.isEmpty
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
            } catch {
                self.error = "Evergreen couldn’t open \(name)."
            }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"),
           NSWorkspace.shared.open(url) { return }
        error = "Evergreen couldn’t open Software Update in System Settings."
    }

    func openAppStore() {
        if let url = URL(string: "macappstore://showUpdatesPage"), NSWorkspace.shared.open(url) { return }
        offerAppStoreOnError = false
        error = "Evergreen couldn’t open App Store Updates."
    }

    private func replace(_ result: UpdateItem) {
        if let index = items.firstIndex(where: { $0.id == result.id }) { items[index] = result }
    }
}
