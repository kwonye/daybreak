import DaybreakKit
import Observation

@MainActor
@Observable
final class ScheduledRunsModel {
    @ObservationIgnored private unowned let app: AppModel
    private(set) var isBusy = false
    var error: String?

    init(app: AppModel) { self.app = app }

    func runScheduledIfDue() async {
        guard canStart, let client = app.client else { return }
        guard (try? await client.automaticRunIsDue()) == true, canStart, app.client === client else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if try await client.runAutomatically() != nil {
                error = nil
                await app.history.refresh()
                await app.inventory.refresh()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var canStart: Bool {
        app.isEngineReady && app.config.settings.automaticRuns && !isBusy && !app.updates.isBusy
    }
}
