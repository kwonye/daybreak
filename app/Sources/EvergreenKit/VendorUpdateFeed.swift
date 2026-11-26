import AppKit
import Foundation

/// Built-in associations for vendors whose macOS apps don't ship a discoverable update manifest.
enum VendorUpdateFeed: Sendable {
    case firefox
    case githubDesktop
    case visualStudioCode

    init?(bundleID: String) {
        switch bundleID {
        case "org.mozilla.firefox": self = .firefox
        case "com.github.GitHubClient": self = .githubDesktop
        case "com.microsoft.VSCode": self = .visualStudioCode
        default: return nil
        }
    }

    func release(for app: ManagedApp) async throws -> PublishedRelease? {
        switch self {
        case .firefox:
            let ini = URL(fileURLWithPath: app.path).appendingPathComponent("Contents/Resources/application.ini")
            guard let metadata = try? String(contentsOf: ini, encoding: .utf8),
                  metadata.split(whereSeparator: \.isNewline).contains("SourceRepository=https://hg.mozilla.org/releases/mozilla-release")
                    || metadata.split(whereSeparator: \.isNewline).contains("SourceRepository=https://github.com/mozilla-firefox/firefox")
            else { return nil }
            // Development and ESR builds should follow Mozilla's own channel.
            guard let channel = Bundle(path: app.path)?.bundleURL
                .appendingPathComponent("Contents/Frameworks/ChannelPrefs.framework/ChannelPrefs"),
                let bytes = try? Data(contentsOf: channel),
                bytes.range(of: Data("release\0".utf8)) != nil,
                app.metadata.version.wholeMatch(of: /[0-9]+(\.[0-9]+){1,2}/) != nil else { return nil }
            let endpoint = URL(string: "https://product-details.mozilla.org/1.0/firefox_versions.json")!
            guard let json = try await Self.json(endpoint), let version = json["LATEST_FIREFOX_VERSION"] as? String else { return nil }
            return PublishedRelease(version: version, artifact: nil)
        case .githubDesktop:
            let repository = ReleaseRepository("desktop/desktop")!
            guard let release = try await repository.latestStableRelease(), release.tag_name.hasPrefix("release-") else { return nil }
            let version = String(release.tag_name.dropFirst("release-".count))
            let arch = Self.macArchitecture(app)
            let matches = release.assets.filter {
                $0.name == "GitHub.Desktop-\(arch).zip" || $0.name == "GitHubDesktop-\(arch).zip"
            }
            let archive = matches.count == 1 ? matches.first.flatMap { repository.downloadArtifact($0, in: release) } : nil
            return PublishedRelease(version: version, artifact: archive)
        case .visualStudioCode:
            let file = URL(fileURLWithPath: app.path).appendingPathComponent("Contents/Resources/app/product.json")
            guard let data = try? Data(contentsOf: file),
                  let product = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  product["quality"] as? String == "stable",
                  let commit = product["commit"] as? String, commit.wholeMatch(of: /[0-9a-f]{40}/) != nil else { return nil }
            let platform = Self.macArchitecture(app) == "arm64" ? "darwin-arm64" : "darwin"
            let endpoint = URL(string: "https://update.code.visualstudio.com/api/update/\(platform)/stable/\(commit)")!
            guard let json = try await Self.json(endpoint) else { return PublishedRelease(version: app.metadata.version, artifact: nil) }
            guard let version = json["productVersion"] as? String, let urlString = json["url"] as? String else { return nil }
            let artifact = ReleaseArtifact(url: URL(string: urlString), sha256: json["sha256hash"] as? String)
            return PublishedRelease(version: version, artifact: artifact)
        }
    }

    private static func json(_ endpoint: URL) async throws -> [String: Any]? {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https",
              response.url?.host == endpoint.host else { throw EngineFailure("The update check returned an unexpected response.") }
        if response.statusCode == 204 { return nil }
        guard response.statusCode == 200 else { throw EngineFailure("The update check couldn’t finish.") }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func macArchitecture(_ app: ManagedApp) -> String {
        let supported = Bundle(path: app.path)?.executableArchitectures ?? []
        return supported.contains(NSNumber(value: NSBundleExecutableArchitectureARM64)) &&
            ReleaseArtifact.nativeArchitecture == "arm64" ? "arm64" : "x64"
    }
}
