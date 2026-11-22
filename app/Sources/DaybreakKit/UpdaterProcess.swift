import Darwin
import Foundation

struct ProcessOutput: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data

    var stderrText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct UpdaterTimeout: LocalizedError {
    let command: String
    var errorDescription: String? { "\(command): timeout; completion is uncertain" }
}

struct UpdaterProcess: Sendable {
    private static let inherited = ProcessInfo.processInfo.environment
    private static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    var searchPath = Self.inherited["PATH"] ?? Self.defaultPath
    var run: @Sendable ([String], TimeInterval) throws -> ProcessOutput = { try Self.execute($0, $1, environment: Self.inherited) }

    static func forGUI() -> UpdaterProcess {
        var environment = inherited
        let path = ([environment["PATH"] ?? defaultPath] + ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"])
            .joined(separator: ":")
        environment["PATH"] = path
        let configuredEnvironment = environment
        return UpdaterProcess(searchPath: path) { try Self.execute($0, $1, environment: configuredEnvironment) }
    }

    func checked(_ argv: [String], _ timeout: TimeInterval) throws -> String {
        let result = try run(argv, timeout)
        guard result.exitCode == 0 else {
            throw EngineFailure("\(URL(fileURLWithPath: argv[0]).lastPathComponent) exited \(result.exitCode)")
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    func executable(named name: String) -> String? {
        searchPath.components(separatedBy: ":").lazy
            .map { URL(fileURLWithPath: $0.isEmpty ? "." : $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) && isFile($0) }
    }

    private static func execute(_ argv: [String], _ timeout: TimeInterval, environment: [String: String]) throws -> ProcessOutput {
        let executable = URL(fileURLWithPath: argv[0])
        let name = executable.lastPathComponent
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("daybreak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: storage) }
        let stdout = storage.appendingPathComponent("out")
        let stderr = storage.appendingPathComponent("err")
        for url in [stdout, stderr] { try Data().write(to: url) }
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        let child = Process()
        child.executableURL = executable
        child.arguments = Array(argv.dropFirst())
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = out
        child.standardError = err
        let finished = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in finished.signal() }
        do { try child.run() }
        catch { throw EngineFailure("\(name): could not start command") }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            // Only interrupt the launched command. Lifecycle operations on apps use AppKit.
            if child.isRunning { child.terminate() }
            throw UpdaterTimeout(command: name)
        }
        return ProcessOutput(exitCode: child.terminationStatus,
                             stdout: try Data(contentsOf: stdout), stderr: try Data(contentsOf: stderr))
    }
}

func isFile(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
}
