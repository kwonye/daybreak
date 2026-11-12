import AppKit
import DaybreakKit
import Foundation

/// QA aid for `--snapshot DIR`: renders the app's *own* windows into PNGs (via
/// `cacheDisplay`, no screen recording) for each pane, then the Settings window, then quits.
/// It only reads: combine with `--preview` to populate the Run pane with a dry run.
@MainActor
enum Snapshotter {
    static func run(model: AppModel, directory: String) async {
        let output = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suffix = model.launchOptions.appearance.map { "-\($0)" } ?? ""

        // Wait (up to ~60 s) for discovery, inventory, history and any requested preview.
        for _ in 0..<120 {
            let settled = model.engineState != .locating && !model.inventory.state.isLoading
                && !model.history.state.isLoading && !model.runner.isBusy
                && (!model.launchOptions.autoPreview || model.runner.outcome != nil || model.runner.error != nil
                    || !model.isEngineReady)
            if settled { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        for section in SidebarSection.allCases {
            model.selection = section
            try? await Task.sleep(for: .seconds(2))
            if let window = mainWindow() {
                write(window, to: output.appendingPathComponent("pane-\(section.rawValue)\(suffix).png"))
            }
        }

        let main = mainWindow()
        var known = Set(NSApp.windows.map(ObjectIdentifier.init))
        // Settings may already be open (`--settings`); otherwise ask the main window to open it.
        var settings = NSApp.windows.first { $0.isVisible && $0 !== main && $0.styleMask.contains(.titled) }
        if settings == nil {
            model.settingsRequest += 1
            try? await Task.sleep(for: .seconds(2))
            settings = newWindow(excluding: known)
        }
        if let settings {
            write(settings, to: output.appendingPathComponent("settings-\(model.launchOptions.settingsTab ?? "behavior")\(suffix).png"))
        }

        known = Set(NSApp.windows.map(ObjectIdentifier.init))
        AboutPanel.show()
        try? await Task.sleep(for: .seconds(1))
        if let about = newWindow(excluding: known) {
            write(about, to: output.appendingPathComponent("about\(suffix).png"))
        }
        NSApp.terminate(nil)
    }

    private static func newWindow(excluding known: Set<ObjectIdentifier>) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !known.contains(ObjectIdentifier($0)) }
            ?? NSApp.windows.first { $0.isVisible && $0.isKeyWindow && $0 !== mainWindow() }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.title == "Daybreak" }
    }

    private static func write(_ window: NSWindow, to url: URL) {
        // The theme frame (contentView's superview) includes the title bar and toolbar.
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path)")
    }
}
