import DaybreakKit
import SwiftUI

/// Manual bundle ID / glob entry with live validation and a preview of running matches.
struct AddPatternSheet: View {
    let config: ConfigModel
    let inventory: InventoryModel
    /// The main window's undo manager (a sheet has its own).
    var undoManager: UndoManager?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validation: String? {
        if trimmed.isEmpty { return nil }
        if let problem = Whitelist.validationError(for: trimmed) { return problem }
        if config.contains(trimmed) { return "Already in the whitelist." }
        return nil
    }
    private var matches: [InventoryApp] {
        var seen = Set<String>()
        return inventory.matches(for: trimmed).filter { seen.insert($0.bundleID).inserted }
    }
    private var canAdd: Bool { !trimmed.isEmpty && validation == nil && config.canEdit }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Bundle ID or Pattern").font(.headline)
            Text("Use an exact bundle ID like com.google.Chrome, or a case-sensitive pattern like com.jetbrains.* (* any characters, ? one character, [abc] one of a set).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Bundle ID or pattern", text: $text, prompt: Text("com.example.*"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .focused($focused)
                .onSubmit(add)
            if let validation {
                Label(validation, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if trimmed.isEmpty {
                        Text("Matching running apps appear here.").foregroundStyle(.secondary)
                    } else if matches.isEmpty {
                        Text("Matches no running apps right now. It still applies when a matching app is running.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matches) { app in
                            HStack(spacing: 6) {
                                AppIconView(path: app.path, size: 18)
                                Text(app.name).lineLimit(1)
                                Text(app.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if app.isProtected {
                                    TagBadge(title: "Protected", symbol: "lock.fill", tint: .purple)
                                }
                            }
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            } label: {
                Text(matches.isEmpty ? "Running Matches" : "Running Matches (\(matches.count))")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private func add() {
        guard canAdd else { return }
        config.add(trimmed, undoManager: undoManager)
        dismiss()
    }
}

/// Pick one or more running apps to whitelist.
struct AddRunningAppSheet: View {
    let config: ConfigModel
    let inventory: InventoryModel
    var undoManager: UndoManager?
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<String>()
    @State private var filter = ""

    private var candidates: [InventoryApp] {
        inventory.candidatesForWhitelist.filter { app in
            !inventory.isWhitelisted(app)
                && (filter.isEmpty || app.name.localizedCaseInsensitiveContains(filter)
                    || app.bundleID.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Running Apps").font(.headline)
            TextField("Filter", text: $filter, prompt: Text("Filter by name or bundle ID"))
                .textFieldStyle(.roundedBorder)
            List(candidates, id: \.bundleID, selection: $selection) { app in
                HStack(spacing: 8) {
                    AppIconView(path: app.path, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1)
                        Text(app.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(app.bundleID)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .overlay {
                if candidates.isEmpty {
                    Text("No other running apps to add.").foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Protected and already whitelisted apps are not listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selection.count > 1 ? "Add \(selection.count) Apps" : "Add") {
                    config.add(selection.sorted(), undoManager: undoManager)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || !config.canEdit)
            }
        }
        .padding(20)
        .frame(width: 480, height: 440)
    }
}
