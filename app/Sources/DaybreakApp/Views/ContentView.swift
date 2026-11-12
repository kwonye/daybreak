import DaybreakKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
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
            await model.bootstrap()
            if let directory = model.launchOptions.snapshotDirectory {
                await Snapshotter.run(model: model, directory: directory)
            }
        }
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
        case .whitelist: model.config.entries.count
        default: 0
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.engineState {
        case .locating:
            LoadingView(message: "Locating the Daybreak engine…")
        // The whitelist only edits the config file, so it stays usable without an engine.
        case .unavailable(let title, let message) where model.selection != .whitelist:
            EngineUnavailableView(title: title, message: message) { Task { await model.bootstrap() } }
                .navigationTitle(model.selection?.title ?? "Daybreak")
        default:
            switch model.selection ?? .runningApps {
            case .runningApps:
                RunningAppsView(inventory: model.inventory, config: model.config)
            case .whitelist:
                WhitelistView(config: model.config, inventory: model.inventory,
                              revealConfig: model.revealConfigInFinder)
            case .run:
                RunView(runner: model.runner, isEngineReady: model.isEngineReady)
            case .history:
                HistoryView(history: model.history, stateDirectory: model.stateDirectory,
                            reveal: model.revealStateDirectoryInFinder)
            }
        }
    }
}

private struct EngineUnavailableView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        } actions: {
            HStack {
                SettingsLink { Text("Open Settings…") }
                Button("Try Again", action: retry)
            }
            .fixedSize()
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
        case .ready: model.runner.isBusy ? .blue : .green
        case .locating: .yellow
        case .unavailable: .red
        }
    }

    private var text: String {
        switch model.engineState {
        case .ready:
            switch model.runner.phase {
            case .applying: return "Updating apps…"
            case .previewing, .preparingApply: return "Previewing…"
            case .idle: return "Engine ready · Python \(model.python?.version ?? "?")"
            }
        case .locating: return "Locating engine…"
        case .unavailable(let title, _): return title
        }
    }

    private var help: String {
        var lines: [String] = []
        if let location = model.engineLocation { lines.append("Engine (\(location.source.rawValue)): \(location.root.path)") }
        if let python = model.python { lines.append("Python \(python.version): \(python.url.path)") }
        lines.append("State: \(model.stateDirectory.path)")
        return lines.joined(separator: "\n")
    }
}
