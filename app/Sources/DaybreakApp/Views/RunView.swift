import DaybreakKit
import SwiftUI

struct RunView: View {
    @Bindable var runner: RunModel
    @State private var showProtected = false

    var body: some View {
        content
            .navigationTitle("Run")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await runner.preview() }
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .disabled(!runner.canStart)
                    .help("Show what would happen without changing anything (⇧⌘P)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await runner.prepareApply() }
                    } label: {
                        Label("Update Now…", systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!runner.canStart)
                    .help("Review and confirm before any app is quit (⇧⌘U)")
                }
            }
            .sheet(item: $runner.pendingPlan) { plan in
                ApplyConfirmationSheet(plan: plan, runner: runner)
            }
            .alert("Nothing to Update", isPresented: $runner.nothingToApply) {
                Button("OK") {}
            } message: {
                Text("There are no eligible running apps in this preview. The results explain why each app was skipped.")
            }
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
            let results = outcome.report.results
            let protected = results.filter(\.isProtected)
            let available = results.filter { !$0.isProtected }
            let visible = available.filter(\.status.needsAttention) + available.filter { $0.status == .planned }
                + available.filter { !$0.status.needsAttention && $0.status != .planned }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    OutcomeHeader(outcome: outcome, finishedAt: runner.finishedAt)
                    Spacer(minLength: 12)
                    if !protected.isEmpty {
                        Toggle("Show protected apps", isOn: $showProtected)
                            .toggleStyle(.checkbox)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                if results.isEmpty {
                    ContentUnavailableView("No Results", systemImage: "tray")
                } else if visible.isEmpty && !showProtected {
                    ContentUnavailableView("No Apps in Scope", systemImage: "checkmark.shield",
                                           description: Text("Show protected apps to see why each app was skipped."))
                } else {
                    ResultsTable(results: showProtected ? visible + protected : visible)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Run Yet", systemImage: "sunrise")
            } description: {
                Text("Preview to see what Daybreak would do for each running app.")
            } actions: {
                if #available(macOS 26, *) {
                    previewButton.buttonStyle(.glassProminent)
                } else {
                    previewButton.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var previewButton: some View {
        Button("Preview") { Task { await runner.preview() } }
            .disabled(!runner.canStart)
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
        if !outcome.report.apply { return "Preview complete" }
        return outcome.needsAttention
            ? "Update finished — \(outcome.report.attentionCount) app(s) need attention"
            : "Update finished"
    }
}

private struct ApplyConfirmationSheet: View {
    let plan: ApplyPlan
    let runner: RunModel
    @State private var selectedIDs: Set<RunResult.ID>
    @Environment(\.dismiss) private var dismiss

    init(plan: ApplyPlan, runner: RunModel) {
        self.plan = plan
        self.runner = runner
        _selectedIDs = State(initialValue: Set(plan.affected.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Review Apps to Update", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text("Choose which apps Daybreak may quit and relaunch. Supported updaters will check for updates. Save prompts can defer apps, and some in-app state may be lost.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            List(plan.affected) { result in
                Toggle(isOn: selection(for: result.id)) {
                    HStack(spacing: 8) {
                        AppIconView(path: result.path, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name).lineLimit(1)
                            Text(result.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(result.backend == "restart-only" ? "Restart only" : result.backend)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(result.path)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(result.name)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 120, maxHeight: 240)

            HStack {
                Button(selectedIDs.isEmpty ? "Select All" : "Deselect All") {
                    selectedIDs = selectedIDs.isEmpty ? Set(plan.affected.map(\.id)) : []
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Quit & Update \(selectedIDs.count) \(selectedIDs.count == 1 ? "App" : "Apps")", role: .destructive) {
                    Task { await runner.confirmApply(plan, choosing: selectedIDs) }
                }
                .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private func selection(for id: RunResult.ID) -> Binding<Bool> {
        Binding(get: { selectedIDs.contains(id) }, set: { selected in
            if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        })
    }
}
