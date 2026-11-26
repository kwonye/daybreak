import Darwin
import Foundation

struct NativeEngine {
    enum Command: String { case inventory, run, status }
    let configURL: URL?
    let stateDirectory: URL

    var process = UpdaterProcess()
    var platform: (any ApplicationPlatform)?

    func execute(_ command: Command, apply: Bool = false, due: Bool = false, only: [String] = [], skip: [String] = [],
                 confirmed: [RunResult]? = nil, requireAutomaticRuns: Bool = false,
                 now: @escaping () -> Date = Date.init) throws -> (data: Data, exitCode: Int32) {
        let state = NativeState(directory: stateDirectory)
        if command == .status { return (try state.status(), 0) }
        if apply && geteuid() == 0 { throw EngineFailure("Run as the logged-in desktop user, never root") }
        let config = try EngineConfiguration(url: configURL, skip: skip)
        let platform = self.platform ?? MacApplications(process: process, quitTimeout: config.quitTimeout)
        if command == .inventory {
            return (try NativeState.json(platform.inventory().map { $0.inventoryRow(config: configURL == nil ? nil : config) }), 0)
        }
        let run = {
            let date = now()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let started = formatter.string(from: date).replacingOccurrences(of: "Z", with: "+00:00")
            if due {
                if requireAutomaticRuns && !config.automaticRuns {
                    return (try NativeState.json(["status": "not_due", "timezone": config.timeZoneID, "hour": config.hour]), Int32(0))
                }
                let gate = try state.due(at: date, config: config)
                guard gate.isDue else {
                    return (try NativeState.json(["status": "not_due", "timezone": config.timeZoneID, "hour": config.hour]), Int32(0))
                }
                if apply { try state.consume(date: gate.localDate, startedAt: started) }
            }

            let apps = try platform.inventory()
            let allowed = Set(only)
            let registry = BackendRegistry(process: process, config: config)
            let coordinator = UpdateCoordinator(platform: platform, config: config, backend: registry.backend)
            let results: [AppOutcome]
            if let confirmed {
                let byIdentity = Dictionary(uniqueKeysWithValues: apps.map { ($0.identity, $0) })
                results = confirmed.map { target in
                    guard let app = byIdentity[ApplicationIdentity(bundleID: target.bundleID, path: target.path)],
                          app.matchesPreview(target) else { return AppOutcome(skipping: target) }
                    return coordinator.handle(app, apply: apply, revalidateSelection: true)
                }
            } else {
                results = apps.filter { allowed.isEmpty || allowed.contains($0.bundleID) }
                    .map { coordinator.handle($0, apply: apply) }
            }
            let data = try NativeState.json(["started_at": started, "apply": apply, "timezone": config.timeZoneID,
                                            "results": results.map(\.row)])
            if apply { try state.save(data) }
            return (data, Int32(results.contains(where: { $0.status.needsAttention }) ? 2 : 0))
        }
        return try apply ? state.withLock(run) : run()
    }
}

/// CLI parsing and JSON output are shared by the standalone binary and checkout launcher.
public enum EvergreenCommandLine {
    public struct Output {
        public let stdout: Data
        public let stderr: Data
        public let exitCode: Int32
    }

    private static let usage = """
        usage: evergreen {inventory,run,status} [--apply] [--due]
                        [--config PATH] [--state-dir PATH] [--only BUNDLE_ID]
                        [--skip BUNDLE_ID_OR_PATTERN]

        Check, update, relaunch and verify running macOS apps. Run without --apply to preview proposed actions.
        --due applies the once-per-local-date schedule gate from the config.

        """

    private struct ArgumentError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    public static func run(_ arguments: [String]) -> Output {
        if arguments.contains("-h") || arguments.contains("--help") {
            return Output(stdout: Data(usage.utf8), stderr: Data(), exitCode: 0)
        }
        do {
            let options = try parse(arguments)
            let engine = NativeEngine(configURL: options.config, stateDirectory: options.stateDirectory)
            let outcome = try engine.execute(options.command, apply: options.apply, due: options.due,
                                             only: options.only, skip: options.skip)
            return Output(stdout: outcome.data, stderr: Data(), exitCode: outcome.exitCode)
        } catch let error as ArgumentError {
            return Output(stdout: Data(), stderr: Data((usage + "evergreen: error: " + error.message + "\n").utf8), exitCode: 2)
        } catch {
            let data = (try? NativeState.json(["status": "error", "detail": error.localizedDescription])) ?? Data()
            return Output(stdout: Data(), stderr: data, exitCode: 1)
        }
    }

    private static func parse(_ arguments: [String]) throws -> (command: NativeEngine.Command, apply: Bool, due: Bool,
                                                                config: URL?, stateDirectory: URL,
                                                                only: [String], skip: [String]) {
        var command: NativeEngine.Command?
        var apply = false
        var due = false
        var config: URL?
        var state = HistoryStore.defaultStateDirectory

        var only: [String] = []
        var skip: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            let pieces = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let flag = String(pieces[0])
            switch flag {
            case "--apply":
                guard pieces.count == 1 else { throw ArgumentError("unexpected value for \(flag)") }
                apply = true
            case "--due" where pieces.count == 1:
                due = true
            case "--config", "--state-dir", "--only", "--skip":
                let value: String
                if pieces.count == 2 { value = String(pieces[1]) }
                else {
                    guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                        throw ArgumentError("\(flag) requires a value")
                    }
                    value = arguments[index]
                    index += 1
                }
                switch flag {
                case "--config": config = URL(fileURLWithPath: value)
                case "--state-dir": state = URL(fileURLWithPath: value)
                case "--only": only.append(value)
                default: skip.append(value)
                }
            default:
                guard command == nil, let parsed = NativeEngine.Command(rawValue: argument) else {
                    throw ArgumentError("unrecognized argument: \(argument)")
                }
                command = parsed
            }
        }
        guard let command else { throw ArgumentError("a command is required") }
        return (command, apply, due, config, state, only, skip)
    }
}
