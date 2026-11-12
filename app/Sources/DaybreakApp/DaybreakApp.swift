import AppKit
import DaybreakKit
import SwiftUI

@main
struct DaybreakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Daybreak", id: "main") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.applyAppearance(model.launchOptions.appearance)
                }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            DaybreakCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

struct DaybreakCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Daybreak") { AboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .sidebar) {
            ForEach(SidebarSection.allCases) { section in
                Button(section.title) { model.selection = section }
                    .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: .command)
            }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Daybreak on GitHub") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
        }
        CommandMenu("Updates") {
            Button("Refresh") {
                Task { await model.refreshCurrentPane() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.isEngineReady)

            Divider()

            Button("Preview (Dry Run)") {
                model.selection = .run
                Task { await model.runner.preview() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!model.runner.canStart)

            // Opens the confirmation sheet; never applies directly.
            Button("Update Now…") {
                model.selection = .run
                Task { await model.runner.prepareApply() }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!model.runner.canStart)

            Divider()

            Button("Reveal Config in Finder") { model.revealConfigInFinder() }
            Button("Reveal Reports in Finder") { model.revealStateDirectoryInFinder() }
        }
    }
}

@MainActor
enum AboutPanel {
    static func show() {
        let info = AppInfo(infoDictionary: Bundle.main.infoDictionary)
        let credits = NSMutableAttributedString(
            string: AppInfo.summary + "\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: AppInfo.repositoryURL.absoluteString,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .link: AppInfo.repositoryURL]))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Daybreak",
            .applicationVersion: info.shortVersion,
            .version: info.build.isEmpty || info.build == info.shortVersion ? "" : info.build,
            .credits: credits,
        ])
        NSApp.activate()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable via `swift run` (no Info.plist).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// `--appearance light|dark` (screenshots/QA); otherwise follow the system.
    func applyAppearance(_ name: String?) {
        switch name?.lowercased() {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model?.isApplying ?? false)
    }

    /// Refuse to quit while an update run is in progress so its results are not lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.isApplying == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "An update run is in progress"
        alert.informativeText = "Wait for it to finish before quitting Daybreak. The engine keeps running regardless (it is never killed), but its results would not be shown here."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}
