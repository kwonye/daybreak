import DaybreakKit
import Foundation
import Observation

@MainActor
@Observable
final class HistoryModel {
    @ObservationIgnored private unowned let app: AppModel

    /// `status` output (latest.json), or nil before the first load.
    private(set) var latest: RunReport?
    private(set) var runs: [StoredRun] = []
    private(set) var state: LoadState = .idle

    init(app: AppModel) {
        self.app = app
    }

    /// Reads the configured state directory: latest via the engine's `status`, stored runs
    /// directly from `runs/*.json` off the main thread.
    func refresh() async {
        guard let client = app.client, !state.isLoading else { return }
        state = .loading
        let directory = client.stateDirectory
        let stored = Task.detached(priority: .userInitiated) { HistoryStore.runs(in: directory) }
        do {
            latest = try await client.status()
            runs = await stored.value
            state = .loaded
        } catch {
            latest = nil
            runs = await stored.value
            state = .failed(error.localizedDescription)
        }
    }
}
