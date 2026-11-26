import AppKit
import SwiftUI

struct MenuBarPanel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Evergreen", systemImage: "tree.fill")
                    .font(.headline)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                action("Open Evergreen", icon: "macwindow") { showWindow() }
                    .accessibilityIdentifier("menuBar.open")
                action("Check for Updates", icon: "arrow.down.app") {
                    showWindow(.updates)
                    Task {
                        await model.startIfNeeded()
                        await model.updates.check()
                    }
                }
                .accessibilityIdentifier("menuBar.checkForUpdates")
                action("History", icon: "clock.arrow.circlepath") { showWindow(.history) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                action("Settings…", icon: "gearshape") {
                    dismiss()
                    openSettings()
                    NSApp.activate()
                }
                .accessibilityIdentifier("menuBar.settings")
                action("Quit Evergreen", icon: "power") { NSApp.terminate(nil) }
                    .disabled(model.isApplying)
            }
        }
        .padding(14)
        .frame(width: 260)
        .task { await model.startIfNeeded() }
    }

    private var status: String {
        if model.updates.installingID != nil { return "Installing update…" }
        if model.updates.isChecking { return "Checking for updates…" }
        if model.scheduler.isBusy { return "Running scheduled updates…" }
        if let latest = model.history.latest, let date = latest.startedDate {
            return "Last run \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return model.isEngineReady ? "Ready" : "Starting…"
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
    }

    private func showWindow(_ section: SidebarSection? = nil) {
        if let section { model.selection = section }
        dismiss()
        openWindow(id: "main")
        NSApp.activate()
    }
}
