import AppKit
import EvergreenKit
import Observation

@MainActor
@Observable
final class ScheduledRunsModel {
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var queuedRun: Date?
    private(set) var isBusy = false
    private(set) var missed: ScheduleReminder? {
        didSet {
            NSApp.dockTile.badgeLabel = missed.map { String($0.updateCount) }
            if let oldValue, oldValue.scheduledAt != missed?.scheduledAt { ScheduleNotifications.clear(oldValue) }
        }
    }
    var error: String?

    init(app: AppModel) { self.app = app }

    func runScheduledIfDue() async {
        guard app.isEngineReady, let client = app.client else { return }
        if !app.config.settings.automaticRuns {
            missed = nil
            queuedRun = nil
            return
        }
        if let queuedRun, !isBusy && !app.updates.isBusy {
            await runMissedNow(expectedAt: queuedRun)
            return
        }
        app.backgroundUpdates.refresh()
        if app.backgroundUpdates.isEnabled {
            missed = try? await client.pendingSchedule()
            let lastRun = app.history.latest?.startedAt
            await app.history.refresh()
            if let finishedRun = app.history.latest?.startedAt, finishedRun != lastRun {
                await app.inventory.refresh()
                await app.updates.check()
            }
            return
        }
        guard !isBusy, !app.updates.isBusy else { return }
        // The idle check is cheap. Only occupy the UI while a run or reminder check is due.
        do {
            guard try await client.scheduleNeedsService(), !isBusy, !app.updates.isBusy, app.client === client else {
                missed = try? await client.pendingSchedule()
                return
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        isBusy = true
        var ran = false
        do {
            let result = try await client.serviceSchedule()
            missed = result.reminder
            if result.shouldNotify, let reminder = result.reminder { await ScheduleNotifications.post(reminder) }
            ran = await record(result.outcome)
        } catch {
            self.error = error.localizedDescription
        }
        isBusy = false
        if ran { await app.updates.check() }
    }

    func runMissedNow(expectedAt: Date) async {
        guard !isBusy, !app.updates.isBusy, let client = app.client else {
            queuedRun = expectedAt
            return
        }
        queuedRun = nil
        isBusy = true
        var ran = false
        do {
            ran = await record(try await client.runMissedSchedule(expectedAt: expectedAt))
            missed = try await client.pendingSchedule()
        } catch {
            self.error = error.localizedDescription
        }
        isBusy = false
        if ran { await app.updates.check() }
    }

    private func record(_ outcome: RunOutcome?) async -> Bool {
        guard let outcome else { return false }
        error = outcome.needsAttention ? "Some scheduled updates need attention. See History for details." : nil
        await app.history.refresh()
        await app.inventory.refresh()
        return true
    }
}
