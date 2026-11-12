import DaybreakKit
import Foundation
import Observation

/// The apps a confirmed `--apply` run is allowed to touch, taken from a fresh dry run.
struct ApplyPlan: Identifiable, Equatable {
    let id = UUID()
    let preview: RunReport

    /// Apps the engine would check/update and gracefully relaunch. Daybreak itself is left out:
    /// quitting the GUI mid-run would lose the results (and it has no updater to run).
    var affected: [RunResult] {
        preview.results.filter { $0.status == .planned && $0.bundleID != InventoryApp.ownBundleID }
    }
    var skipped: [RunResult] {
        preview.results.filter { $0.status != .planned || $0.bundleID == InventoryApp.ownBundleID }
    }
    var bundleIDs: [String] { Array(Set(affected.map(\.bundleID))).sorted() }
}

@MainActor
@Observable
final class RunModel {
    enum Phase: Equatable {
        case idle
        case previewing
        case preparingApply
        case applying

        var message: String {
            switch self {
            case .idle: ""
            case .previewing: "Previewing (dry run)…"
            case .preparingApply: "Checking which apps would be affected…"
            case .applying: "Updating — apps are being gracefully quit and relaunched. This can take several minutes…"
            }
        }
    }

    @ObservationIgnored private unowned let app: AppModel

    private(set) var phase: Phase = .idle
    private(set) var outcome: RunOutcome?
    private(set) var finishedAt: Date?
    private(set) var error: String?
    /// Non-nil while the confirmation sheet is shown.
    var pendingPlan: ApplyPlan?
    /// Shown when a preview found nothing that would be quit.
    var nothingToApply = false

    init(app: AppModel) {
        self.app = app
    }

    var isBusy: Bool { phase != .idle }
    var canStart: Bool { app.isEngineReady && !isBusy }

    func preview() async {
        guard canStart, let client = app.client else { return }
        phase = .previewing
        error = nil
        do {
            outcome = try await client.run(apply: false)
            finishedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
        phase = .idle
    }

    /// Step 1 of applying: a read-only dry run to build the confirmation. Never applies.
    func prepareApply() async {
        guard canStart, let client = app.client else { return }
        phase = .preparingApply
        error = nil
        do {
            let preview = try await client.run(apply: false)
            outcome = preview
            finishedAt = Date()
            let plan = ApplyPlan(preview: preview.report)
            if plan.affected.isEmpty {
                nothingToApply = true
            } else {
                pendingPlan = plan
            }
        } catch {
            self.error = error.localizedDescription
        }
        phase = .idle
    }

    /// Step 2: only reachable from the confirmation sheet. Limited with `--only` to the apps the
    /// user confirmed, so an app launched after confirming is never interrupted.
    func confirmApply(_ plan: ApplyPlan) async {
        pendingPlan = nil
        guard canStart, let client = app.client, !plan.bundleIDs.isEmpty else { return }
        phase = .applying
        error = nil
        do {
            outcome = try await client.run(apply: true, only: plan.bundleIDs)
            finishedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
        phase = .idle
        await app.history.refresh()
        await app.inventory.refresh()
    }

    func cancelApply() {
        pendingPlan = nil
    }
}
