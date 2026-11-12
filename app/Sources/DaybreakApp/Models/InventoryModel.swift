import DaybreakKit
import Foundation
import Observation

@MainActor
@Observable
final class InventoryModel {
    @ObservationIgnored private unowned let app: AppModel

    private(set) var apps: [InventoryApp] = []
    private(set) var state: LoadState = .idle
    private(set) var lastRefreshed: Date?
    var searchText = ""
    /// Hides system/helper/host apps that Daybreak never touches anyway.
    var hideProtected: Bool = UserDefaults.standard.object(forKey: "hideProtectedApps") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hideProtected, forKey: "hideProtectedApps") }
    }

    init(app: AppModel) {
        self.app = app
    }

    @ObservationIgnored private var refreshQueued = false

    /// Coalesces overlapping requests: a refresh requested mid-load runs once more afterwards,
    /// so whitelist edits are always reflected in the engine's per-app flags.
    func refresh() async {
        guard let client = app.client else { return }
        if state.isLoading {
            refreshQueued = true
            return
        }
        state = .loading
        repeat {
            refreshQueued = false
            do {
                let result = try await client.inventory()
                apps = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                lastRefreshed = Date()
                state = .loaded
            } catch {
                state = .failed(error.localizedDescription)
            }
        } while refreshQueued
    }

    var filteredApps: [InventoryApp] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return apps.filter { app in
            (!hideProtected || !app.isProtected)
                && (query.isEmpty || app.name.localizedCaseInsensitiveContains(query)
                    || app.bundleID.localizedCaseInsensitiveContains(query))
        }
    }

    var protectedCount: Int { apps.filter(\.isProtected).count }

    func isWhitelisted(_ app: InventoryApp) -> Bool {
        app.isWhitelisted(by: self.app.config.patterns)
    }

    /// Running apps currently matched by a whitelist pattern.
    func matches(for pattern: String) -> [InventoryApp] {
        apps.filter { Whitelist.matches(pattern: pattern, bundleID: $0.bundleID) }
    }

    /// Unique running apps (by bundle ID) that are not protected, for the "Add Running App" picker.
    var candidatesForWhitelist: [InventoryApp] {
        var seen = Set<String>()
        return apps.filter { !$0.isProtected && !$0.isSelf && seen.insert($0.bundleID).inserted }
    }

    func app(withBundleID bundleID: String) -> InventoryApp? {
        apps.first { $0.bundleID == bundleID }
    }
}
