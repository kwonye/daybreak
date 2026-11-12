import AppKit
import DaybreakKit
import Foundation
import Observation

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case runningApps, whitelist, run, history

    var id: Self { self }

    /// Accepts `--pane running|whitelist|run|history` (or the raw value).
    init?(launchName: String) {
        switch launchName.lowercased() {
        case "running", "apps", "runningapps": self = .runningApps
        case "whitelist": self = .whitelist
        case "run": self = .run
        case "history": self = .history
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .runningApps: "Running Apps"
        case .whitelist: "Whitelist"
        case .run: "Run"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .runningApps: "macwindow.on.rectangle"
        case .whitelist: "checklist"
        case .run: "arrow.triangle.2.circlepath"
        case .history: "clock.arrow.circlepath"
        }
    }

    var shortcut: Character {
        switch self {
        case .runningApps: "1"
        case .whitelist: "2"
        case .run: "3"
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

/// Root state: app preferences, engine discovery, and the feature view models.
@MainActor
@Observable
final class AppModel {
    enum EngineState: Equatable {
        case locating
        case ready
        case unavailable(title: String, message: String)
    }

    private enum DefaultsKey {
        static let pythonPath = "pythonPath"
        static let checkoutPath = "engineCheckoutPath"
        static let stateDirectory = "stateDirectory"
        static let selection = "selectedPane"
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

    // App-only preferences live in UserDefaults (co.kwon.daybreak), never in the engine config.
    // Writes happen only on a real change, so `-pythonPath …` style launch arguments (the
    // NSArgumentDomain) are honoured for one launch without being persisted.

    /// Interpreter override from Settings (empty = auto-detect).
    var pythonOverride: String {
        didSet { if pythonOverride != oldValue { UserDefaults.standard.set(pythonOverride, forKey: DefaultsKey.pythonPath) } }
    }

    /// Engine checkout fallback from Settings (used when the bundle has no embedded engine).
    var checkoutPath: String {
        didSet { if checkoutPath != oldValue { UserDefaults.standard.set(checkoutPath, forKey: DefaultsKey.checkoutPath) } }
    }

    /// Custom `--state-dir` (empty = engine default ~/Library/Application Support/Daybreak).
    var stateDirectoryPath: String {
        didSet { if stateDirectoryPath != oldValue { UserDefaults.standard.set(stateDirectoryPath, forKey: DefaultsKey.stateDirectory) } }
    }

    var stateDirectory: URL { HistoryStore.resolveStateDirectory(preference: stateDirectoryPath) }

    /// Incremented to ask the main window to open Settings (used by the snapshot QA mode).
    var settingsRequest = 0

    private(set) var engineState: EngineState = .locating
    private(set) var python: PythonInterpreter?
    private(set) var engineLocation: EngineLocation?
    private(set) var client: EngineClient?

    let configStore = ConfigStore()
    let launchOptions: LaunchOptions
    @ObservationIgnored private(set) lazy var config = ConfigModel(store: configStore, app: self)
    @ObservationIgnored private(set) lazy var inventory = InventoryModel(app: self)
    @ObservationIgnored private(set) lazy var runner = RunModel(app: self)
    @ObservationIgnored private(set) lazy var history = HistoryModel(app: self)

    init(launchOptions: LaunchOptions = LaunchOptions(arguments: CommandLine.arguments)) {
        let defaults = UserDefaults.standard
        self.launchOptions = launchOptions
        pythonOverride = defaults.string(forKey: DefaultsKey.pythonPath) ?? ""
        checkoutPath = defaults.string(forKey: DefaultsKey.checkoutPath) ?? ""
        stateDirectoryPath = defaults.string(forKey: DefaultsKey.stateDirectory) ?? ""
        let stored = defaults.string(forKey: DefaultsKey.selection).flatMap(SidebarSection.init(rawValue:))
        selection = launchOptions.pane.flatMap(SidebarSection.init(launchName:)) ?? stored ?? .runningApps
    }

    var isEngineReady: Bool { engineState == .ready }

    /// Locates python3 and the engine, then loads config, inventory and history.
    /// Never runs while a run is in flight (it would swap the client underneath it).
    func bootstrap() async {
        guard !runner.isBusy else { return }
        engineState = .locating
        client = nil
        config.reload()

        let location = EngineLocator.locate(
            bundleResources: Bundle.main.resourceURL,
            checkoutPath: checkoutPath,
            executable: Bundle.main.executableURL)
        let interpreter = await PythonLocator.locate(override: pythonOverride)
        engineLocation = try? location.get()
        python = try? interpreter.get()

        switch (location, interpreter) {
        case (.failure(let error), _):
            engineState = .unavailable(title: "Engine Not Found", message: error.localizedDescription)
        case (_, .failure(let error)):
            engineState = .unavailable(title: "Python 3.11+ Not Found", message: error.localizedDescription)
        case (.success(let location), .success(let interpreter)):
            client = EngineClient(python: interpreter, engine: location, configURL: configStore.url,
                                  stateDirectory: stateDirectory)
            engineState = .ready
            async let inventoryLoad: Void = inventory.refresh()
            async let historyLoad: Void = history.refresh()
            _ = await (inventoryLoad, historyLoad)
            if launchOptions.autoPreview { await runner.preview() }
        }
    }

    /// ⌘R: refreshes whatever the selected pane shows.
    func refreshCurrentPane() async {
        switch selection ?? .runningApps {
        case .history: await history.refresh()
        case .whitelist:
            config.reload()
            await inventory.refresh()
        case .runningApps, .run: await inventory.refresh()
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
    var isApplying: Bool { runner.phase == .applying }
}
