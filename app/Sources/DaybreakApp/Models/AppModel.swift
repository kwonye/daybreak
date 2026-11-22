import AppKit
import DaybreakKit
import Foundation
import Observation

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case updates, runningApps, whitelist, history

    var id: Self { self }

    /// Accepts `--pane updates|running|whitelist|history` (or the raw value).
    init?(launchName: String) {
        switch launchName.lowercased() {
        case "updates": self = .updates
        case "running", "apps", "runningapps": self = .runningApps
        case "whitelist": self = .whitelist
        case "history": self = .history
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .updates: "Updates"
        case .runningApps: "Running Apps"
        case .whitelist: "Whitelist"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .updates: "arrow.down.app"
        case .runningApps: "macwindow.on.rectangle"
        case .whitelist: "checklist"
        case .history: "clock.arrow.circlepath"
        }
    }

    var shortcut: Character {
        switch self {
        case .updates: "5"
        case .runningApps: "1"
        case .whitelist: "2"
        case .history: "4"
        }
    }
}

enum LoadState: Equatable {
    case idle, loading, loaded, failed(String)

    var isLoading: Bool { self == .loading }
    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Root state: app preferences, the native engine, and the feature view models.
@MainActor
@Observable
final class AppModel {
    enum EngineState: Equatable {
        case loading
        case ready
    }

    private enum DefaultsKey {
        static let stateDirectory = "stateDirectory"
        static let menuBar = "showMenuBar"
        static let hideDock = "hideDockIcon"
        static let selection = "selectedPane"
        static let setupCompleted = "setupCompleted"
    }

    /// Sidebar selection, persisted across launches (a `--pane` launch argument overrides it).
    var selection: SidebarSection? {
        didSet {
            // Snapshot/QA runs must not overwrite the user's remembered pane.
            if selection != oldValue, launchOptions.snapshotDirectory == nil {
                UserDefaults.standard.set(selection?.rawValue, forKey: DefaultsKey.selection)
            }
        }
    }

    var showMenuBar: Bool {
        didSet {
            guard showMenuBar != oldValue else { return }
            UserDefaults.standard.set(showMenuBar, forKey: DefaultsKey.menuBar)
            if !showMenuBar && hideDockIcon { hideDockIcon = false }
        }
    }

    var hideDockIcon: Bool {
        didSet {
            guard hideDockIcon != oldValue else { return }
            if hideDockIcon && !showMenuBar { showMenuBar = true }
            UserDefaults.standard.set(hideDockIcon, forKey: DefaultsKey.hideDock)
            applyDockPreference()
        }
    }

    func applyDockPreference() {
        let policy: NSApplication.ActivationPolicy = hideDockIcon ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?

    var shouldOfferSetup: Bool {
        !UserDefaults.standard.bool(forKey: DefaultsKey.setupCompleted)
            && launchOptions.pane == nil && launchOptions.configPath == nil
            && launchOptions.snapshotDirectory == nil && !launchOptions.openSettings
    }

    func completeSetup() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.setupCompleted)
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        await bootstrap()
        if launchOptions.snapshotDirectory == nil {
            scheduleTask = Task { [weak self] in
                while !Task.isCancelled, self != nil {
                    await self?.scheduler.runScheduledIfDue()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }

    /// Custom `--state-dir` (empty = engine default ~/Library/Application Support/Daybreak).
    var stateDirectoryPath: String {
        didSet { if stateDirectoryPath != oldValue { UserDefaults.standard.set(stateDirectoryPath, forKey: DefaultsKey.stateDirectory) } }
    }

    var stateDirectory: URL { HistoryStore.resolveStateDirectory(preference: stateDirectoryPath) }

    /// Incremented to ask the main window to open Settings (used by the snapshot QA mode).
    var settingsRequest = 0
    var whitelistAddRequest = 0

    private(set) var engineState: EngineState = .loading
    private(set) var client: EngineClient?

    let configStore: ConfigStore
    let launchOptions: LaunchOptions
    @ObservationIgnored private(set) lazy var config = ConfigModel(store: configStore, app: self)
    @ObservationIgnored private(set) lazy var updates = UpdatesModel(app: self)
    @ObservationIgnored private(set) lazy var inventory = InventoryModel(app: self)
    @ObservationIgnored private(set) lazy var scheduler = ScheduledRunsModel(app: self)
    @ObservationIgnored private(set) lazy var history = HistoryModel(app: self)

    init(launchOptions: LaunchOptions = LaunchOptions(arguments: CommandLine.arguments)) {
        let defaults = UserDefaults.standard
        self.launchOptions = launchOptions
        configStore = ConfigStore(url: launchOptions.configPath.map { URL(fileURLWithPath: $0) } ?? ConfigStore.defaultURL)
        let hideDock = defaults.bool(forKey: DefaultsKey.hideDock)
        hideDockIcon = hideDock
        showMenuBar = hideDock || (defaults.object(forKey: DefaultsKey.menuBar) as? Bool ?? true)
        stateDirectoryPath = defaults.string(forKey: DefaultsKey.stateDirectory) ?? ""
        let stored = defaults.string(forKey: DefaultsKey.selection).flatMap(SidebarSection.init(rawValue:))
        selection = launchOptions.pane.flatMap(SidebarSection.init(launchName:)) ?? stored ?? .updates
    }

    var isEngineReady: Bool { engineState == .ready }

    /// Loads local configuration, inventory and history through the native engine.
    /// Never runs while a run is in flight (it would swap the client underneath it).
    func bootstrap() async {
        guard !scheduler.isBusy, !updates.isBusy else { return }
        engineState = .loading
        client = nil
        config.reload()

        client = EngineClient(configURL: configStore.url, stateDirectory: stateDirectory)
        engineState = .ready
        async let inventoryLoad: Void = inventory.refresh()
        async let historyLoad: Void = history.refresh()
        _ = await (inventoryLoad, historyLoad)
    }

    /// ⌘R: refreshes whatever the selected pane shows.
    func refreshCurrentPane() async {
        switch selection ?? .runningApps {
        case .updates: await updates.check()
        case .history: await history.refresh()
        case .whitelist:
            config.reload()
            await inventory.refresh()
        case .runningApps: await inventory.refresh()
        }
    }

    func revealStateDirectoryInFinder() {
        let directory = stateDirectory
        let target = FileManager.default.fileExists(atPath: directory.path) ? directory : directory.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func revealConfigInFinder() {
        if configStore.exists {
            NSWorkspace.shared.activateFileViewerSelecting([configStore.url])
        } else {
            let directory = configStore.url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: directory.path) {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.homeDirectoryForCurrentUser])
            }
        }
    }

    /// True while an `--apply` run is in flight; quitting the app is refused meanwhile.
    var isApplying: Bool { scheduler.isBusy || updates.installingID != nil }
}
