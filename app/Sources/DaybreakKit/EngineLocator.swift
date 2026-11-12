import Foundation

/// Where the Python `daybreak` package and the compiled `appbridge` helper live.
public struct EngineLocation: Sendable, Equatable {
    public enum Source: String, Sendable {
        case bundle = "App bundle"
        case checkout = "Checkout (Settings)"
        case autodetected = "Checkout (auto-detected)"
    }

    /// The directory that contains the `daybreak/` package. Used as cwd and PYTHONPATH.
    public let root: URL
    public let bridge: URL
    public let source: Source

    public init(root: URL, bridge: URL, source: Source) {
        self.root = root
        self.bridge = bridge
        self.source = source
    }
}

public struct PythonInterpreter: Sendable, Equatable {
    public let url: URL
    public let version: String
}

public enum EngineSetupError: Error, LocalizedError, Equatable {
    case engineNotFound(tried: [String])
    case pythonNotFound(tried: [String])
    case pythonOverrideInvalid(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .engineNotFound(let tried):
            return "The Daybreak engine could not be found. Looked in:\n" + tried.map { "• \($0)" }.joined(separator: "\n")
                + "\n\nBuild the app with scripts/build-app.sh, or set the engine checkout path in Settings."
        case .pythonNotFound(let tried):
            return "No Python 3.11 or newer was found. Checked:\n" + tried.map { "• \($0)" }.joined(separator: "\n")
                + "\n\nInstall Python 3.11+ (for example with Homebrew), or choose an interpreter in Settings."
        case .pythonOverrideInvalid(let path, let reason):
            return "The Python interpreter set in Settings (\(path)) cannot be used: \(reason)"
        }
    }
}

public enum EngineLocator {
    static func hasPackage(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("daybreak/__main__.py").path)
    }

    /// Bundle Resources first, then the checkout path from Settings, then (for `swift run`
    /// during development) a checkout found by walking up from the executable.
    public static func locate(
        bundleResources: URL?,
        checkoutPath: String?,
        executable: URL?
    ) -> Result<EngineLocation, EngineSetupError> {
        var tried: [String] = []
        if let resources = bundleResources {
            tried.append(resources.path)
            if hasPackage(resources) {
                return .success(EngineLocation(root: resources, bridge: resources.appendingPathComponent("appbridge"), source: .bundle))
            }
        }
        if let checkoutPath, !checkoutPath.trimmingCharacters(in: .whitespaces).isEmpty {
            let root = URL(fileURLWithPath: (checkoutPath as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            tried.append(root.path)
            if hasPackage(root) {
                return .success(EngineLocation(root: root, bridge: root.appendingPathComponent(".build/appbridge"), source: .checkout))
            }
        }
        if let executable {
            var directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<8 {
                if hasPackage(directory) {
                    return .success(EngineLocation(root: directory, bridge: directory.appendingPathComponent(".build/appbridge"), source: .autodetected))
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return .failure(.engineNotFound(tried: tried))
    }
}

public enum PythonLocator {
    public static let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    public static let minimum = (major: 3, minor: 11)

    /// Parses "3.12" style output and checks it against the minimum.
    public static func isSupported(_ version: String) -> Bool {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return (parts[0], parts[1]) >= minimum
    }

    struct ProbeFailure: Error, ExpressibleByStringLiteral {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        init(stringLiteral value: String) { reason = value }
    }

    static func probe(_ path: String) async -> Result<PythonInterpreter, ProbeFailure> {
        guard FileManager.default.isExecutableFile(atPath: path) else { return .failure("not found or not executable") }
        do {
            let output = try await ProcessRunner.run(
                URL(fileURLWithPath: path),
                arguments: ["-I", "-c", "import sys; print('%d.%d.%d' % sys.version_info[:3])"])
            let version = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard output.exitCode == 0, !version.isEmpty else { return .failure("did not report a version") }
            guard isSupported(version) else { return .failure(ProbeFailure("version \(version) is older than 3.11")) }
            return .success(PythonInterpreter(url: URL(fileURLWithPath: path), version: version))
        } catch {
            return .failure(ProbeFailure(error.localizedDescription))
        }
    }

    /// An explicit override is used exclusively (no silent fallback); otherwise the well-known
    /// locations are probed in order.
    public static func locate(override: String?) async -> Result<PythonInterpreter, EngineSetupError> {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (override as NSString).expandingTildeInPath
            switch await probe(path) {
            case .success(let interpreter): return .success(interpreter)
            case .failure(let failure): return .failure(.pythonOverrideInvalid(path: path, reason: failure.reason))
            }
        }
        var tried: [String] = []
        for path in candidates {
            switch await probe(path) {
            case .success(let interpreter): return .success(interpreter)
            case .failure(let failure): tried.append("\(path) — \(failure.reason)")
            }
        }
        return .failure(.pythonNotFound(tried: tried))
    }
}
