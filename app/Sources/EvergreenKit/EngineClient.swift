import Foundation
import CryptoKit

public enum EngineError: Error, LocalizedError, Equatable {
    case failed(detail: String)
    case undecodable(command: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .failed(let detail): return detail
        case .undecodable(let command, let reason): return "Could not read the engine's \(command) output: \(reason)"
        }
    }
}

public struct RunOutcome: Sendable {
    public let report: RunReport
    public let exitCode: Int32
    public var needsAttention: Bool { exitCode == 2 }
}

/// Keeps blocking platform and updater work off the UI's main actor.
public actor EngineClient {
    public static var hasHomebrew: Bool { UpdaterProcess.forGUI().executable(named: "brew") != nil }

    public nonisolated let configURL: URL
    public nonisolated let stateDirectory: URL

    public init(configURL: URL, stateDirectory: URL = HistoryStore.defaultStateDirectory) {
        self.configURL = configURL
        self.stateDirectory = stateDirectory
    }

    private func invoke(_ command: NativeEngine.Command, apply: Bool = false, only: [String] = [],
                        confirmed: [RunResult]? = nil, automatic: Bool = false, scheduledFor: Date? = nil) async throws
        -> (data: Data, exitCode: Int32) {
        do {
            return try await NativeEngine(configURL: configURL, stateDirectory: stateDirectory, process: .forGUI())
                .execute(command, apply: apply, due: automatic, only: only, confirmed: confirmed,
                         requireAutomaticRuns: automatic, scheduledFor: scheduledFor)
        } catch {
            throw EngineError.failed(detail: error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, command: NativeEngine.Command) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw EngineError.undecodable(command: command.rawValue, reason: String(describing: error))
        }
    }

    public func inventory() async throws -> [InventoryApp] {
        try decode([InventoryApp].self, from: await invoke(.inventory).data, command: .inventory)
    }

    /// The caller obtains confirmation before passing apply: true.
    public func run(apply: Bool, only: [String] = []) async throws -> RunOutcome {
        let result = try await invoke(.run, apply: apply, only: only)
        let report = try decode(RunReport.self, from: result.data, command: .run)
        return RunOutcome(report: report, exitCode: result.exitCode)
    }

    /// Applies only the selected app instances, rechecking their identities before any update.
    public func apply(confirmed: [RunResult]) async throws -> RunOutcome {
        let result = try await invoke(.run, apply: true, confirmed: confirmed)
        let report = try decode(RunReport.self, from: result.data, command: .run)
        return RunOutcome(report: report, exitCode: result.exitCode)
    }

    public func status() async throws -> RunReport {
        try decode(RunReport.self, from: await invoke(.status).data, command: .status)
    }

    public func automaticRunIsDue() throws -> Bool {
        let config = try EngineConfiguration(url: configURL)
        return try config.automaticRuns && NativeState(directory: stateDirectory).due(at: Date(), config: config).isDue
    }

    /// The engine rechecks the opt-in and uses the same run lock and date marker as the CLI.
    public func runAutomatically(scheduledFor: Date? = nil) async throws -> RunOutcome? {
        let result = try await invoke(.run, apply: true, automatic: true, scheduledFor: scheduledFor)
        let report = try decode(RunReport.self, from: result.data, command: .run)
        return report.status == "not_due" ? nil : RunOutcome(report: report, exitCode: result.exitCode)
    }

    public func updateInventory() throws -> [UpdateItem] {
        try UpdateCatalog(configURL: configURL, stateDirectory: stateDirectory).inventory()
    }

    private struct CachedCheck: Codable {
        let configPath: String
        let configFingerprint: String
        let check: UpdateCheckCache
    }

    private var updateCheckURL: URL { stateDirectory.appendingPathComponent("update-check.json") }

    public func updateConfigFingerprint() -> String {
        guard let data = try? Data(contentsOf: configURL) else { return "" }
        return SHA256.hash(data: data).description
    }

    public func cachedUpdateCheck() -> (check: UpdateCheckCache, matchesConfig: Bool)? {
        guard let data = try? Data(contentsOf: updateCheckURL),
              let cached = try? JSONDecoder().decode(CachedCheck.self, from: data) else { return nil }
        return (cached.check, cached.configPath == configURL.path && cached.configFingerprint == updateConfigFingerprint())
    }

    public func saveUpdateCheck(_ check: UpdateCheckCache, configFingerprint: String) throws {
        let cached = CachedCheck(configPath: configURL.path, configFingerprint: configFingerprint, check: check)
        try NativeState(directory: stateDirectory).write(JSONEncoder().encode(cached), to: updateCheckURL)
    }

    public func checkForUpdates(_ items: [UpdateItem], progress: @escaping @Sendable (UpdateItem) async -> Void) async throws {
        try await UpdateCatalog(configURL: configURL, stateDirectory: stateDirectory).check(items, progress: progress)
    }

    public func installUpdate(_ item: UpdateItem) async throws -> UpdateItem {
        try await UpdateCatalog(configURL: configURL, stateDirectory: stateDirectory).install(item)
    }
}
