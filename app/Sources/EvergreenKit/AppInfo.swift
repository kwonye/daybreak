import Foundation

/// Version and identity strings for the About panel and diagnostics.
public struct AppInfo: Sendable, Equatable {
    public static let repositoryURL = URL(string: "https://github.com/kwonye/evergreen")!
    public static let summary = "A conservative macOS update coordinator: checks supported updaters, gracefully quits and relaunches running apps, and verifies the result."
    static let developmentBundleID = InventoryApp.ownBundleID + ".dev"

    public static let isDevelopmentBuild: Bool = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.bundleIdentifier == developmentBundleID
        }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return false }
        // SwiftPM can launch the GUI directly. The bundled CLI runs from Contents/Helpers.
        if executable.lastPathComponent == "EvergreenApp" { return true }
        let helpers = executable.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents" else { return false }
        return Bundle(url: contents.deletingLastPathComponent())?.bundleIdentifier == developmentBundleID
    }()

    public static var displayName: String { isDevelopmentBuild ? "Evergreen Dev" : "Evergreen" }
    public static var scheduleAgentPlist: String {
        let bundleID = isDevelopmentBuild ? developmentBundleID : InventoryApp.ownBundleID
        return bundleID + ".schedule.plist"
    }

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
