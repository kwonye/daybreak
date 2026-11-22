import AppKit
import DaybreakKit
import Observation

@MainActor
@Observable
final class UpdatesModel {
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private weak var cacheClient: EngineClient?
    @ObservationIgnored private var recentCheck: UpdateCheckCache?
    private(set) var items: [UpdateItem] = []
    private(set) var state: LoadState = .idle
    private(set) var isChecking = false
    private(set) var installingID: String?
    private(set) var checkedAt: Date?
    var error: String?
    private(set) var offerAppStoreOnError = false

    init(app: AppModel) { self.app = app }

    var isBusy: Bool { isChecking || state.isLoading || installingID != nil }
    var canCheck: Bool { !isBusy && app.isEngineReady && !app.scheduler.isBusy }
    var hasUpdates: Int { items.filter { $0.status == .available }.count }

    func load() async {
        let needsInventory = state == .idle || cacheClient !== app.client
        if needsInventory { await reloadInventory() }
        guard state == .loaded, app.launchOptions.snapshotDirectory == nil else { return }
        await check(automatic: true, reuseInventory: needsInventory)
    }

    private func reloadInventory() async {
        guard let client = app.client else { return }
        if let loading {
            await loading.value
            return
        }
        state = .loading
        let task = Task {
            do {
                let inventory = try await client.updateInventory()
                if cacheClient !== client {
                    let cached = await client.cachedUpdateCheck()
                    recentCheck = cached?.check
                    checkedAt = cached?.matchesConfig == true ? cached?.check.checkedAt : nil
                    items = cached?.matchesConfig == true ? cached?.check.restore(into: inventory) ?? inventory : inventory
                    cacheClient = client
                } else {
                    items = inventory
                }
                state = .loaded
            } catch {
                state = .failed("Daybreak couldn’t read your installed apps or configuration.")
            }
        }
        loading = task
        await task.value
        loading = nil
    }

    func check() async {
        await check(automatic: false, reuseInventory: false)
    }

    private func check(automatic: Bool, reuseInventory: Bool) async {
        guard !isChecking, installingID == nil, !app.scheduler.isBusy, let client = app.client else { return }
        if automatic, recentCheck?.allowsAutomaticCheck(at: Date()) == false { return }
        isChecking = true
        offerAppStoreOnError = false
        error = nil
        // A check belongs to the app, so leaving the pane doesn't cancel it.
        let operation = Task { await performCheck(client, reuseInventory: reuseInventory) }
        await operation.value
    }

    private func performCheck(_ client: EngineClient, reuseInventory: Bool) async {
        defer { isChecking = false }
        let previousItems = items
        let previousDate = checkedAt
        if !reuseInventory { await reloadInventory() }
        guard state == .loaded else { return }
        let started = Date()
        let fingerprint = await client.updateConfigFingerprint()
        let attempted = UpdateCheckCache(attemptedAt: started, checkedAt: previousDate, items: previousItems)
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
        guard canCheck, item.action == .install, let client = app.client else { return }
        installingID = item.id
        offerAppStoreOnError = false
        defer { installingID = nil }
        do {
            replace(try await client.installUpdate(item))
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            offerAppStoreOnError = item.isMacAppStoreApp
        }
        await app.history.refresh()
        await app.inventory.refresh()
    }

    func open(_ item: UpdateItem) {
        guard let action = item.action else { return }
        let url: URL?
        switch action {
        case .install: return
        case .openApp:
            url = item.path.map { URL(fileURLWithPath: $0) }
        case .openSystemSettings:
            url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")
        case .openStore:
            openAppStore()
            return
        case .openRelease(let link), .openLink(let link):
            url = link
        }
        if let url, NSWorkspace.shared.open(url) { return }
        error = "Daybreak couldn’t open the update for \(item.name)."
    }

    func openAppStore() {
        if let url = URL(string: "macappstore://showUpdatesPage"), NSWorkspace.shared.open(url) { return }
        offerAppStoreOnError = false
        error = "Daybreak couldn’t open App Store Updates."
    }

    func saveRepository(_ repository: ReleaseRepository?, for item: UpdateItem) async -> Bool {
        guard !isBusy, let bundleID = item.bundleID else { return false }
        do {
            try app.configStore.update { try $0.setReleaseRepository(repository, for: bundleID) }
            // Refresh the edited row only, preserving the other check results.
            if let replacement = try await app.client?.updateInventory().first(where: { $0.id == item.id }) {
                replace(replacement)
            }
            return true
        } catch {
            self.error = "Daybreak couldn’t save the release page. Check your configuration and try again."
            return false
        }
    }

    private func replace(_ result: UpdateItem) {
        if let index = items.firstIndex(where: { $0.id == result.id }) { items[index] = result }
    }
}
