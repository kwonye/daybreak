import DaybreakKit
import Foundation
import Observation

/// Whitelist and engine settings, backed by the preserving `ConfigStore`.
@MainActor
@Observable
final class ConfigModel {
    let store: ConfigStore
    @ObservationIgnored private unowned let app: AppModel

    private(set) var entries: [WhitelistEntry] = []
    private(set) var settings = EngineSettings()
    /// Set when the file cannot be parsed; all edits are refused until it is fixed.
    private(set) var loadError: String?
    /// Last failed edit (shown as an alert).
    var actionError: String?

    init(store: ConfigStore, app: AppModel) {
        self.store = store
        self.app = app
    }

    var patterns: [String] { entries.map(\.pattern) }
    var canEdit: Bool { loadError == nil }

    func reload() {
        do {
            let document = try store.load()
            entries = try document.whitelistEntries()
            settings = try document.settings()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func contains(_ pattern: String) -> Bool { patterns.contains(pattern) }

    /// Exact entries (not globs) that list this bundle ID.
    func exactEntry(for bundleID: String) -> WhitelistEntry? {
        entries.first { $0.pattern == bundleID }
    }

    /// Adds entries to `whitelist`; registers an undo that removes the ones actually added.
    func add(_ patterns: [String], undoManager: UndoManager? = nil) {
        var added: [String] = []
        let ok = mutate { document in
            for pattern in patterns {
                if try document.addWhitelistPattern(pattern) {
                    added.append(pattern.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        guard ok, !added.isEmpty, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.remove(added, undoManager: undoManager) }
        }
        undoManager.setActionName(added.count == 1 ? "Add to Whitelist" : "Add \(added.count) to Whitelist")
    }

    func add(_ pattern: String, undoManager: UndoManager? = nil) {
        add([pattern], undoManager: undoManager)
    }

    /// Removes entries (from `whitelist` and legacy `exclude`); undo restores them to their original key.
    func remove(_ patterns: some Sequence<String>, undoManager: UndoManager? = nil) {
        let list = Set(patterns)
        let removed = entries.filter { list.contains($0.pattern) }
        guard !removed.isEmpty else { return }
        let ok = mutate { document in
            for entry in removed { try document.removeWhitelistPattern(entry.pattern) }
        }
        guard ok, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(removed, undoManager: undoManager) }
        }
        undoManager.setActionName(removed.count == 1 ? "Remove from Whitelist" : "Remove \(removed.count) from Whitelist")
    }

    private func restore(_ removed: [WhitelistEntry], undoManager: UndoManager?) {
        let ok = mutate { document in
            for entry in removed { try document.restoreWhitelistEntry(entry) }
        }
        guard ok, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.remove(removed.map(\.pattern), undoManager: undoManager) }
        }
    }

    func save(settings newSettings: EngineSettings) -> Bool {
        let original = settings
        return mutate { try $0.applySettings(newSettings, original: original) }
    }

    @discardableResult
    private func mutate(_ change: (inout ConfigDocument) throws -> Void) -> Bool {
        do {
            let document = try store.update(change)
            entries = try document.whitelistEntries()
            settings = try document.settings()
            loadError = nil
            // The engine reports `whitelisted` per app; refresh so badges reflect the new config.
            Task { await app.inventory.refresh() }
            return true
        } catch let error as ConfigError {
            // A parse failure means the file changed underneath us; surface it and stop editing.
            switch error {
            case .invalidJSON, .notAnObject, .unexpectedType: loadError = error.localizedDescription
            case .invalidSettings: break
            }
            actionError = error.localizedDescription
        } catch {
            actionError = error.localizedDescription
        }
        return false
    }
}
