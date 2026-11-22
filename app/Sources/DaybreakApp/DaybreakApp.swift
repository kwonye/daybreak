import AppKit
import DaybreakKit
import SwiftUI

@main
struct DaybreakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        @Bindable var model = model
        Window("Daybreak", id: "main") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.applyAppearance(model.launchOptions.appearance)
                    if model.hideDockIcon { model.applyDockPreference() }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            DaybreakCommands(model: model)
        }

        MenuBarExtra("Daybreak", systemImage: "sunrise", isInserted: $model.showMenuBar) {
            MenuBarPanel(model: model)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.applyAppearance(model.launchOptions.appearance)
                    if model.hideDockIcon { model.applyDockPreference() }
                }
        }
        .menuBarExtraStyle(.window)

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

            Button("Add Whitelist Pattern…") { model.whitelistAddRequest += 1 }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.selection != .whitelist || !model.config.canEdit)

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
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
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
        !(model?.isApplying ?? false) && !(model?.showMenuBar ?? false)
    }

    /// Refuse to quit while an update run is in progress so its results are not lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.isApplying == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "An update run is in progress"
        alert.informativeText = "Daybreak needs to stay open until apps are relaunched and the report is saved."
        alert.addButton(withTitle: "Keep Running")
        alert.runModal()
        return .terminateCancel
    }
}
