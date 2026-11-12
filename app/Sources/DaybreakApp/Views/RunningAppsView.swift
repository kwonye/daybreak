import DaybreakKit
import SwiftUI

struct RunningAppsView: View {
    @Bindable var inventory: InventoryModel
    let config: ConfigModel
    @Environment(\.undoManager) private var undoManager
    @State private var selection = Set<InventoryApp.ID>()

    var body: some View {
        content
            .navigationTitle("Running Apps")
            .navigationSubtitle(subtitle)
            .searchable(text: $inventory.searchText, placement: .toolbar, prompt: "Search apps or bundle IDs")
            .toolbar {
                ToolbarItem {
                    Toggle(isOn: $inventory.hideProtected) {
                        Label("Hide Protected Apps", systemImage: "lock.slash")
                    }
                    .toggleStyle(.button)
                    .help(inventory.hideProtected ? "Show protected system, helper and host apps" : "Hide protected apps")
                }
                ToolbarItem {
                    if inventory.state.isLoading && !inventory.apps.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing")
                    } else {
                        Button {
                            Task { await inventory.refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh running apps (⌘R)")
                    }
                }
            }
    }

    private var subtitle: String {
        guard !inventory.apps.isEmpty else { return "" }
        let whitelisted = inventory.apps.filter(inventory.isWhitelisted).count
        var parts = ["\(inventory.apps.count) running", "\(whitelisted) whitelisted"]
        if inventory.hideProtected && inventory.protectedCount > 0 { parts.append("\(inventory.protectedCount) protected hidden") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if inventory.apps.isEmpty {
            switch inventory.state {
            case .failed(let message):
                ErrorStateView(title: "Couldn’t List Running Apps", message: message) {
                    Task { await inventory.refresh() }
                }
            case .loaded:
                ContentUnavailableView("No Running Apps", systemImage: "macwindow",
                                       description: Text("The engine reported no running apps."))
            default:
                LoadingView(message: "Reading running apps…")
            }
        } else if inventory.filteredApps.isEmpty {
            if inventory.searchText.isEmpty {
                ContentUnavailableView {
                    Label("Only Protected Apps Are Running", systemImage: "lock")
                } description: {
                    Text("Daybreak never quits protected system, helper or host apps.")
                } actions: {
                    Button("Show Protected Apps") { inventory.hideProtected = false }
                }
            } else {
                ContentUnavailableView.search(text: inventory.searchText)
            }
        } else {
            VStack(spacing: 0) {
                if let message = inventory.state.errorMessage {
                    InlineBanner(message: "Refresh failed: \(message)")
                }
                table
            }
        }
    }

    private var table: some View {
        Table(inventory.filteredApps, selection: $selection) {
            TableColumn("App") { app in
                HStack(spacing: 8) {
                    AppIconView(path: app.path, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                            .lineLimit(1)
                        Text(app.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help("\(app.bundleID)\n\(app.path)")
                .accessibilityElement(children: .combine)
            }
            .width(min: 200, ideal: 270)

            TableColumn("Version") { app in
                Text(app.versionDescription.isEmpty ? "—" : app.versionDescription)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(app.versionDescription)
            }
            .width(min: 70, ideal: 160, max: 240)

            TableColumn("Status") { app in
                badges(for: app)
            }
            .width(min: 120, ideal: 220)

            TableColumn("Whitelist") { app in
                WhitelistToggle(app: app, inventory: inventory, config: config, undoManager: undoManager)
            }
            .width(min: 64, ideal: 70, max: 80)
            .alignment(.center)
        }
        .contextMenu(forSelectionType: InventoryApp.ID.self) { ids in
            let apps = inventory.apps.filter { ids.contains($0.id) }
            let addable = apps.filter { !$0.isProtected && !$0.isSelf && config.exactEntry(for: $0.bundleID) == nil }
            let removable = apps.compactMap { config.exactEntry(for: $0.bundleID) }
            if !addable.isEmpty {
                Button("Add to Whitelist") { config.add(addable.map(\.bundleID), undoManager: undoManager) }
                    .disabled(!config.canEdit)
            }
            if !removable.isEmpty {
                Button("Remove from Whitelist") { config.remove(removable.map(\.pattern), undoManager: undoManager) }
                    .disabled(!config.canEdit)
            }
            if let app = apps.first, apps.count == 1 {
                Divider()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                }
                Button("Copy Bundle ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.bundleID, forType: .string)
                }
            }
        }
    }

    @ViewBuilder
    private func badges(for app: InventoryApp) -> some View {
        HStack(spacing: 4) {
            if app.isSelf {
                TagBadge(title: "This App", symbol: "sunrise.fill", tint: .blue)
                    .help("Daybreak never quits itself during an update run.")
            }
            if app.isProtected {
                TagBadge(title: "Protected", symbol: "lock.fill", tint: .purple)
                    .help("System, helper, updater or host app. Daybreak never quits it.")
            }
            if inventory.isWhitelisted(app) {
                TagBadge(title: "Whitelisted", symbol: "checkmark.shield.fill", tint: .teal)
                    .help(whitelistReason(app))
            }
            if app.stale {
                TagBadge(title: "Stale", symbol: "clock.arrow.circlepath", tint: .orange)
                    .help("The running process is older than the bundle on disk.")
            }
            if !app.isSelf && !app.isProtected && !inventory.isWhitelisted(app) && !app.stale {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Not whitelisted or protected")
            }
        }
    }

    private func whitelistReason(_ app: InventoryApp) -> String {
        if let pattern = Whitelist.firstMatch(in: config.patterns, bundleID: app.bundleID) {
            return pattern == app.bundleID ? "Whitelisted by bundle ID" : "Whitelisted by pattern \(pattern)"
        }
        return "Reported as whitelisted by the engine"
    }
}

/// Checkbox that adds/removes an exact bundle-ID entry. Apps matched only by a glob pattern
/// (or protected apps) show a disabled checkbox with an explanation.
private struct WhitelistToggle: View {
    let app: InventoryApp
    let inventory: InventoryModel
    let config: ConfigModel
    let undoManager: UndoManager?

    var body: some View {
        let exact = config.exactEntry(for: app.bundleID)
        let whitelisted = inventory.isWhitelisted(app)
        let byPatternOnly = whitelisted && exact == nil
        Toggle("Whitelist \(app.name)", isOn: Binding(
            get: { whitelisted },
            set: { newValue in
                if newValue {
                    config.add(app.bundleID, undoManager: undoManager)
                } else if let exact {
                    config.remove([exact.pattern], undoManager: undoManager)
                }
            }))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .disabled(!config.canEdit || app.isProtected || app.isSelf || byPatternOnly)
        .help(help(exact: exact, byPatternOnly: byPatternOnly))
    }

    private func help(exact: WhitelistEntry?, byPatternOnly: Bool) -> String {
        if app.isProtected { return "Protected apps are always skipped." }
        if app.isSelf { return "Daybreak never quits itself." }
        if byPatternOnly {
            let pattern = Whitelist.firstMatch(in: config.patterns, bundleID: app.bundleID) ?? "an engine rule"
            return "Whitelisted by \(pattern). Edit it in the Whitelist section."
        }
        return exact == nil ? "Always skip \(app.name) during updates" : "Stop skipping \(app.name)"
    }
}

struct InlineBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.1))
    }
}
