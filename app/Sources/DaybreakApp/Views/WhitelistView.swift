import AppKit
import DaybreakKit
import SwiftUI
import UniformTypeIdentifiers

struct WhitelistView: View {
    let config: ConfigModel
    let inventory: InventoryModel
    let revealConfig: () -> Void

    @Environment(\.undoManager) private var undoManager
    @State private var selection = Set<String>()
    @State private var sheet: AddSheet?
    @State private var openPanelError: String?

    enum AddSheet: String, Identifiable {
        case runningApp, manual
        var id: String { rawValue }
    }

    var body: some View {
        content
            .navigationTitle("Whitelist")
            .navigationSubtitle(config.entries.isEmpty ? "" : "\(config.entries.count) \(config.entries.count == 1 ? "entry" : "entries")")
            .toolbar {
                ToolbarItemGroup {
                    addMenu
                    Button {
                        removeSelected()
                    } label: {
                        Label("Remove", systemImage: "minus")
                    }
                    .help("Remove the selected entries (⌫)")
                    .disabled(selection.isEmpty || !config.canEdit)
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .runningApp: AddRunningAppSheet(config: config, inventory: inventory, undoManager: undoManager)
                case .manual: AddPatternSheet(config: config, inventory: inventory, undoManager: undoManager)
                }
            }
            .alert("Couldn’t Add App", isPresented: Binding(
                get: { openPanelError != nil }, set: { if !$0 { openPanelError = nil } })
            ) {
                Button("OK") { openPanelError = nil }
            } message: {
                Text(openPanelError ?? "")
            }
            .onChange(of: config.entries) {
                selection.formIntersection(config.patterns)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let error = config.loadError {
            ContentUnavailableView {
                Label("Configuration Can’t Be Read", systemImage: "doc.badge.exclamationmark")
            } description: {
                Text(error + "\n\n" + config.store.url.path).textSelection(.enabled)
            } actions: {
                HStack {
                    Button("Reveal in Finder", action: revealConfig)
                    Button("Reload") { config.reload() }
                }
                .fixedSize()
            }
        } else if config.entries.isEmpty {
            ContentUnavailableView {
                Label("No Whitelisted Apps", systemImage: "checkmark.shield")
            } description: {
                Text("Whitelisted apps are never quit, updated or relaunched by Daybreak. Add exact bundle IDs or patterns such as com.jetbrains.*")
            } actions: {
                HStack {
                    Button("Add Running App…") { sheet = .runningApp }
                        .disabled(inventory.candidatesForWhitelist.isEmpty)
                    Button("Add Installed App…", action: chooseInstalledApp)
                    Button("Add Pattern…") { sheet = .manual }
                }
                .fixedSize()
            }
        } else {
            List(selection: $selection) {
                Section {
                    ForEach(config.entries) { entry in
                        WhitelistRow(entry: entry, matches: inventory.matches(for: entry.pattern))
                            .tag(entry.pattern)
                            .contextMenu {
                                Button("Remove from Whitelist") { config.remove([entry.pattern], undoManager: undoManager) }
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.pattern, forType: .string)
                                }
                            }
                    }
                } footer: {
                    Text("Entries are exact bundle IDs or case-sensitive shell-style patterns (*, ?, [...]). Saved to \(config.store.url.path).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onDeleteCommand(perform: removeSelected)
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Running App…") { sheet = .runningApp }
                .disabled(inventory.candidatesForWhitelist.isEmpty)
            Button("Installed App…", action: chooseInstalledApp)
            Divider()
            Button("Bundle ID or Pattern…") { sheet = .manual }
                .keyboardShortcut("n", modifiers: [.command])
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add to whitelist (⌘N for a bundle ID or pattern)")
        .disabled(!config.canEdit)
    }

    private func removeSelected() {
        guard config.canEdit, !selection.isEmpty else { return }
        config.remove(selection, undoManager: undoManager)
        selection.removeAll()
    }

    private func chooseInstalledApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose Apps to Whitelist"
        panel.prompt = "Whitelist"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        var bundleIDs: [String] = []
        var unreadable: [String] = []
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty {
                bundleIDs.append(bundleID)
            } else {
                unreadable.append(url.lastPathComponent)
            }
        }
        if !bundleIDs.isEmpty { config.add(bundleIDs, undoManager: undoManager) }
        if !unreadable.isEmpty {
            openPanelError = "No bundle identifier found in: " + unreadable.joined(separator: ", ")
        }
    }
}

private struct WhitelistRow: View {
    let entry: WhitelistEntry
    let matches: [InventoryApp]

    private var isPattern: Bool { Whitelist.isGlob(entry.pattern) }
    private var installed: ResolvedApp? { IconStore.shared.app(forBundleID: entry.pattern) }

    private var displayName: String? {
        if isPattern { return nil }
        return matches.first?.name ?? installed?.name
    }

    var body: some View {
        HStack(spacing: 10) {
            if isPattern {
                Image(systemName: "asterisk.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.teal)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            } else {
                AppIconView(path: matches.first?.path ?? installed?.url.path, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let displayName {
                    Text(displayName).lineLimit(1)
                    Text(entry.pattern)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(entry.pattern)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(matchSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(entry.pattern)
            Spacer(minLength: 8)
            if entry.source == .exclude {
                TagBadge(title: "Legacy “exclude”", symbol: "clock", tint: .secondary)
                    .help("Listed under the legacy “exclude” key. Still honoured; removing it edits that key.")
            }
            if isPattern {
                TagBadge(title: "Pattern", symbol: "asterisk", tint: .teal)
            } else if !matches.isEmpty {
                TagBadge(title: "Running", symbol: "circle.fill", tint: .green)
            } else if installed == nil {
                TagBadge(title: "Not Found", symbol: "questionmark.app", tint: .secondary)
                    .help("No app with this bundle ID is running or registered with Launch Services.")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var matchSummary: String {
        guard isPattern else { return "Not running" }
        switch matches.count {
        case 0: return "Matches no running apps"
        case 1...3: return "Matches " + matches.map(\.name).joined(separator: ", ")
        default: return "Matches \(matches.prefix(3).map(\.name).joined(separator: ", ")) and \(matches.count - 3) more"
        }
    }
}
