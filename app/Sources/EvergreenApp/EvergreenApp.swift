import AppKit
import EvergreenKit
import SwiftUI
import UserNotifications

@main
enum EvergreenEntryPoint {
    @MainActor static func main() {
        guard CommandLine.arguments.contains("--schedule-agent") else { return EvergreenApp.main() }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let path = UserDefaults.standard.string(forKey: AppModel.DefaultsKey.stateDirectory) ?? ""
        let options = LaunchOptions(arguments: CommandLine.arguments)
        let configURL = options.configPath.map { URL(fileURLWithPath: $0) } ?? ConfigStore.defaultURL
        let client = EngineClient(configURL: configURL, stateDirectory: HistoryStore.resolveStateDirectory(preference: path))
        RunLoop.main.add(Timer(timeInterval: 3600, repeats: true) { _ in }, forMode: .common)
        Task.detached(priority: .utility) {
            do {
                let result = try await client.serviceSchedule()
                if result.shouldNotify, let reminder = result.reminder { await ScheduleNotifications.post(reminder) }
                exit(0)
            } catch {
                NSLog("Evergreen background schedule: %@", error.localizedDescription)
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}

struct EvergreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        @Bindable var model = model
        Window("Evergreen", id: "main") {
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
            EvergreenCommands(model: model)
        }

        MenuBarExtra(isInserted: $model.showMenuBar) {
            MenuBarPanel(model: model)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.applyAppearance(model.launchOptions.appearance)
                    if model.hideDockIcon { model.applyDockPreference() }
                }
        } label: {
            Image(systemName: model.scheduler.missed == nil ? "tree" : "tree.circle.fill")
                .accessibilityLabel(model.scheduler.missed == nil ? "Evergreen" : "Evergreen, scheduled update missed")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

struct EvergreenCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Evergreen") { AboutPanel.show() }
            if let updater = model.appUpdater, updater.isAvailable {
                Button("Check for Evergreen Updates…", action: updater.check)
                    .disabled(!updater.canCheck || model.isApplying)
            }
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .sidebar) {
            ForEach(model.sidebarSections) { section in
                Button(section.title) { model.selection = section }
                    .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: .command)
            }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Evergreen on GitHub") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
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
            .applicationName: "Evergreen",
            .applicationVersion: info.shortVersion,
            .version: info.build.isEmpty || info.build == info.shortVersion ? "" : info.build,
            .credits: credits,
        ])
        NSApp.activate()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var model: AppModel? {
        didSet { if let requestedSlot { runRequestedSchedule(at: requestedSlot) } }
    }
    private var requestedSlot: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
            ScheduleNotifications.configure()
        }
        // Needed when launched as a bare executable via `swift run` (no Info.plist).
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == "evergreen.schedule.missed",
              response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let timestamp = content.userInfo["scheduledAt"] as? TimeInterval else { return }
        let slot = Date(timeIntervalSince1970: timestamp)
        await MainActor.run { runRequestedSchedule(at: slot) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    private func runRequestedSchedule(at slot: Date) {
        guard let model else { requestedSlot = slot; return }
        requestedSlot = nil
        Task {
            await model.startIfNeeded()
            await model.scheduler.runMissedNow(expectedAt: slot)
        }
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
        alert.informativeText = "Evergreen needs to stay open until apps are relaunched and the report is saved."
        alert.addButton(withTitle: "Keep Running")
        alert.runModal()
        return .terminateCancel
    }
}
