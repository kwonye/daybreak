import AppKit
import DaybreakKit
import Observation

@MainActor
@Observable
final class UpdatesModel {
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var loading: Task<Void, Never>?
    private(set) var items: [UpdateItem] = []
    private(set) var state: LoadState = .idle
    private(set) var isChecking = false
    private(set) var installingID: String?
    private(set) var checkedAt: Date?
    var error: String?

    init(app: AppModel) { self.app = app }

    var isBusy: Bool { isChecking || state.isLoading || installingID != nil }
    var canCheck: Bool { !isBusy && app.runner.canStart }
    var hasUpdates: Int { items.filter { $0.status == .available }.count }

    func load() async {
        guard state == .idle else { return }
        await reloadInventory()
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
                items = try await client.updateInventory()
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
        guard !isChecking, installingID == nil, !app.runner.isBusy, app.runner.pendingPlan == nil,
              let client = app.client else { return }
        isChecking = true
        defer { isChecking = false }
        checkedAt = nil
        await reloadInventory()
        guard state == .loaded else { return }
        do {
            try await client.checkForUpdates(items) { [weak self] result in
                await self?.replace(result)
            }
            checkedAt = Date()
        } catch is CancellationError {
            return
        } catch {
            self.error = "The check couldn’t finish. Try again."
        }
    }

    func install(_ item: UpdateItem) async {
        guard canCheck, item.action == .install, let client = app.client else { return }
        installingID = item.id
        defer { installingID = nil }
        do {
            replace(try await client.installUpdate(item))
        } catch {
            self.error = error.localizedDescription
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
            url = URL(string: "macappstore://showUpdatesPage")
        case .openRelease(let link), .openLink(let link):
            url = link
        }
        if let url, NSWorkspace.shared.open(url) { return }
        error = "Daybreak couldn’t open the update for \(item.name)."
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
