import Foundation

/// Version and identity strings for the About panel and diagnostics.
public struct AppInfo: Sendable, Equatable {
    public static let repositoryURL = URL(string: "https://github.com/kwonye/daybreak")!
    public static let summary = "A conservative macOS update coordinator: checks supported updaters, gracefully quits and relaunches running apps, and verifies the result."

    public let shortVersion: String
    public let build: String

    /// Reads CFBundleShortVersionString / CFBundleVersion; a bare `swift run` binary has neither.
    public init(infoDictionary: [String: Any]?) {
        let short = (infoDictionary?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = (infoDictionary?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        shortVersion = short.isEmpty ? "dev" : short
        self.build = build
    }

    /// "0.1.0", or "0.1.0 (42)" when the build differs.
    public var displayVersion: String {
        build.isEmpty || build == shortVersion ? shortVersion : "\(shortVersion) (\(build))"
    }

    /// Parses `version = "x.y.z"` from the `[project]` table of a pyproject.toml — the single
    /// version source that scripts/build-app.sh also reads.
    public static func projectVersion(fromPyproject text: String) -> String? {
        var inProject = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inProject = line == "[project]"
                continue
            }
            guard inProject, line.hasPrefix("version") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "version" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return isValidBundleVersion(value) ? value : nil
        }
        return nil
    }

    /// CFBundleShortVersionString must be up to three period-separated non-negative integers.
    public static func isValidBundleVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && Int($0) != nil }
    }
}
