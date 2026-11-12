import DaybreakKit
import SwiftUI

struct RunView: View {
    @Bindable var runner: RunModel
    let isEngineReady: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle("Run")
        .sheet(item: $runner.pendingPlan) { plan in
            ApplyConfirmationSheet(plan: plan) {
                Task { await runner.confirmApply(plan) }
            } cancel: {
                runner.cancelApply()
            }
        }
        .alert("Nothing to Update", isPresented: $runner.nothingToApply) {
            Button("OK") {}
        } message: {
            Text("The preview found no running apps that Daybreak would quit and relaunch. Every running app is protected, whitelisted, or blocked by configuration.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Update Running Apps").font(.title2.weight(.semibold))
                Text("Preview is read-only. Update Now checks each supported updater, then gracefully quits and relaunches apps after you confirm. Apps are never force-quit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                Task { await runner.preview() }
            } label: {
                Label("Preview (Dry Run)", systemImage: "eye")
            }
            .controlSize(.large)
            .disabled(!runner.canStart)
            .help("Show what would happen without changing anything (⇧⌘P)")

            Button {
                Task { await runner.prepareApply() }
            } label: {
                Label("Update Now…", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!runner.canStart)
            .help("Review and confirm before any app is quit (⇧⌘U)")
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if runner.isBusy {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(runner.phase.message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if runner.phase == .applying {
                    Text("Save prompts or quit refusals defer an app instead of forcing it. You can keep using your Mac.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = runner.error {
            ErrorStateView(title: "The Engine Reported an Error", message: error, retryTitle: "Preview Again") {
                Task { await runner.preview() }
            }
        } else if let outcome = runner.outcome {
            VStack(alignment: .leading, spacing: 0) {
                OutcomeHeader(outcome: outcome, finishedAt: runner.finishedAt)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                if outcome.report.results.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "tray",
                                           description: Text("The engine returned no per-app results."))
                } else {
                    ResultsTable(results: outcome.report.results)
                }
            }
        } else if !isEngineReady {
            ContentUnavailableView("Engine Unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text("Fix the engine setup in Settings to preview or run updates."))
        } else {
            ContentUnavailableView {
                Label("No Run Yet", systemImage: "sunrise")
            } description: {
                Text("Preview to see what Daybreak would do for each running app.")
            } actions: {
                Button("Preview (Dry Run)") { Task { await runner.preview() } }
            }
        }
    }
}

private struct OutcomeHeader: View {
    let outcome: RunOutcome
    let finishedAt: Date?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: outcome.report.apply
                  ? (outcome.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                  : "eye.circle.fill")
                .font(.title2)
                .foregroundStyle(outcome.report.apply ? (outcome.needsAttention ? .orange : .green) : .blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    if let finishedAt {
                        Text("· \(finishedAt.relativeDescription)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                ResultsSummary(report: outcome.report)
            }
        }
    }

    private var title: String {
        if !outcome.report.apply { return "Dry-run preview — nothing was changed" }
        return outcome.needsAttention
            ? "Update finished — \(outcome.report.attentionCount) app(s) need attention"
            : "Update finished"
    }
}

/// The only path to `--apply`. States plainly what will happen and to how many apps.
struct ApplyConfirmationSheet: View {
    let plan: ApplyPlan
    let confirm: () -> Void
    let cancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quit, Update and Relaunch \(plan.affected.count) \(plan.affected.count == 1 ? "App" : "Apps")?")
                        .font(.headline)
                    Text("Daybreak will gracefully quit each app below, install available updates where a supported updater exists, and relaunch it. Unsaved work may prompt you to save; apps that refuse to quit are deferred, never force-quit. Browser tabs, meetings and other in-app state may not be restored.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            List(plan.affected) { result in
                HStack(spacing: 8) {
                    BundleIconView(bundleID: result.bundleID, size: 20)
                    Text(result.name).lineLimit(1)
                    Text(result.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(result.backend).font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 120, maxHeight: 240)
            if !plan.skipped.isEmpty {
                Text("\(plan.skipped.count) other running \(plan.skipped.count == 1 ? "app is" : "apps are") protected, whitelisted, blocked by configuration, or Daybreak itself, and will not be touched. Apps launched after you confirm are not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Quit & Update \(plan.affected.count) \(plan.affected.count == 1 ? "App" : "Apps")", role: .destructive) {
                    confirm()
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
