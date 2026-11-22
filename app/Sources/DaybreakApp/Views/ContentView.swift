import DaybreakKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showingSetup = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .badge(badge(for: section))
                    .help("\(section.title) (⌘\(String(section.shortcut)))")
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { EngineStatusFooter(model: model) }
        } detail: {
            detail
                .frame(minWidth: 600, minHeight: 420)
        }
        .task {
            await model.startIfNeeded()
            if model.shouldOfferSetup { showingSetup = true }
            if let directory = model.launchOptions.snapshotDirectory {
                await Snapshotter.run(model: model, directory: directory)
            }
        }
        .sheet(isPresented: $showingSetup) { SetupView(model: model) }
        .onAppear {
            if model.launchOptions.openSettings { openSettings() }
        }
        .onChange(of: model.settingsRequest) { openSettings() }
        .alert("Couldn’t Update Whitelist", isPresented: Binding(
            get: { model.config.actionError != nil }, set: { if !$0 { model.config.actionError = nil } })
        ) {
            Button("OK") { model.config.actionError = nil }
        } message: {
            Text(model.config.actionError ?? "")
        }
    }

    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .updates: model.updates.hasUpdates
        case .whitelist: model.config.entries.count
        default: 0
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.engineState {
        case .loading:
            LoadingView(message: "Starting Daybreak…")
        default:
            switch model.selection ?? .updates {
            case .updates:
                UpdatesView(model: model.updates)
            case .runningApps:
                RunningAppsView(inventory: model.inventory, config: model.config)
            case .whitelist:
                WhitelistView(config: model.config, inventory: model.inventory,
                              revealConfig: model.revealConfigInFinder, addRequest: model.whitelistAddRequest)
            case .history:
                HistoryView(history: model.history, stateDirectory: model.stateDirectory,
                            reveal: model.revealStateDirectoryInFinder)
            }
        }
    }
}

private struct EngineStatusFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch model.engineState {
        case .ready:
            if model.scheduler.isBusy || model.updates.isBusy { .blue }
            else if model.scheduler.error != nil { .orange }
            else { .green }
        case .loading: .yellow
        }
    }

    private var text: String {
        switch model.engineState {
        case .ready:
            if model.updates.installingID != nil { return "Installing update…" }
            if model.updates.isChecking { return "Checking for updates…" }
            if !model.scheduler.isBusy, model.scheduler.error != nil { return "Scheduled run needs attention" }
            return model.scheduler.isBusy ? "Updating apps…" : "Engine ready"
        case .loading: return "Starting engine…"
        }
    }

    private var help: String {
        model.scheduler.error ?? "State: \(model.stateDirectory.path)"
    }
}
