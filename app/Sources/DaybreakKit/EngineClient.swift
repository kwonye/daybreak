import Foundation

public enum EngineError: Error, LocalizedError, Equatable {
    /// Exit 1: setup/configuration/inventory failure with the engine's `detail`.
    case failed(detail: String)
    case unexpectedExit(code: Int32, stderr: String)
    case undecodable(command: String, reason: String)
    case launch(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let detail): return detail
        case .unexpectedExit(let code, let stderr):
            return "The engine exited with status \(code)." + (stderr.isEmpty ? "" : "\n\(stderr)")
        case .undecodable(let command, let reason): return "Could not read the engine's \(command) output: \(reason)"
        case .launch(let reason): return "Could not start the engine: \(reason)"
        }
    }
}

public struct RunOutcome: Sendable {
    public let report: RunReport
    /// 0 = nothing needs attention, 2 = at least one app needs attention.
    public let exitCode: Int32
    public var needsAttention: Bool { exitCode == 2 }
}

/// Executes the Python engine and decodes its JSON. All update/quit/relaunch logic stays in the engine.
public actor EngineClient {
    public nonisolated let python: PythonInterpreter
    public nonisolated let engine: EngineLocation
    public nonisolated let configURL: URL
    /// Passed as `--state-dir` on every call (reports, schedule gate and lock live here).
    public nonisolated let stateDirectory: URL

    public init(python: PythonInterpreter, engine: EngineLocation, configURL: URL,
                stateDirectory: URL = HistoryStore.defaultStateDirectory) {
        self.python = python
        self.engine = engine
        self.configURL = configURL
        self.stateDirectory = stateDirectory
    }

    /// Full argument vector for a command (exposed for testing and for display).
    public nonisolated func arguments(for command: String, extra: [String] = []) -> [String] {
        // -B: never write __pycache__ into the (signed) app bundle.
        var args = ["-B", "-m", "daybreak", command, "--bridge", engine.bridge.path]
        if command != "status" { args += ["--config", configURL.path] }
        args += ["--state-dir", stateDirectory.path]
        return args + extra
    }

    nonisolated func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = engine.root.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env.removeValue(forKey: "PYTHONHOME")
        // GUI apps inherit a minimal PATH; add the usual Homebrew locations so the engine's
        // backends (brew, mas, docker) are found the same way as from a login shell.
        var path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"] where !path.contains(extra) {
            path.append(extra)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    func invoke(_ command: String, extra: [String] = []) async throws -> ProcessOutput {
        do {
            return try await ProcessRunner.run(
                python.url, arguments: arguments(for: command, extra: extra),
                currentDirectory: engine.root, environment: environment())
        } catch {
            throw EngineError.launch(error.localizedDescription)
        }
    }

    /// Maps exit codes: 0/2 → stdout JSON, 1 → stderr `detail`.
    static func checked(_ output: ProcessOutput, allowAttention: Bool) throws -> Data {
        switch output.exitCode {
        case 0: return output.stdout
        case 2 where allowAttention: return output.stdout
        case 1:
            if let payload = try? JSONDecoder().decode(EngineErrorPayload.self, from: output.stderr),
               let detail = payload.detail, !detail.isEmpty {
                throw EngineError.failed(detail: detail)
            }
            throw EngineError.failed(detail: output.stderrText.isEmpty ? "The engine reported an error." : output.stderrText)
        default:
            throw EngineError.unexpectedExit(code: output.exitCode, stderr: output.stderrText)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, command: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw EngineError.undecodable(command: command, reason: String(describing: error))
        }
    }

    public func inventory() async throws -> [InventoryApp] {
        let output = try await invoke("inventory")
        let data = try Self.checked(output, allowAttention: false)
        return try Self.decode([InventoryApp].self, from: data, command: "inventory")
    }

    /// Dry run (`--dry-run`) unless `apply` is true. Callers must obtain explicit user
    /// confirmation before passing `apply: true`.
    public func run(apply: Bool, only: [String] = []) async throws -> RunOutcome {
        let extra = [apply ? "--apply" : "--dry-run"] + only.flatMap { ["--only", $0] }
        let output = try await invoke("run", extra: extra)
        let data = try Self.checked(output, allowAttention: true)
        let report = try Self.decode(RunReport.self, from: data, command: "run")
        return RunOutcome(report: report, exitCode: output.exitCode)
    }

    /// `latest.json` via the engine (`{"status": "never_run"}` when there is none).
    public func status() async throws -> RunReport {
        let output = try await invoke("status")
        let data = try Self.checked(output, allowAttention: false)
        return try Self.decode(RunReport.self, from: data, command: "status")
    }
}
