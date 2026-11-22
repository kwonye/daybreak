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

}
