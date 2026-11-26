import Foundation

/// Matches published releases to manually installed app bundles.
struct HomebrewCatalog: Sendable {
    private struct ArtifactKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct Identity: Hashable, Sendable {
        let bundleID: String
        let appName: String
    }

    private struct Artifact: Decodable {
        enum CodingKeys: String, CodingKey { case app, target, uninstall }

        struct Target: Decodable { let target: String? }

        struct Uninstall: Decodable {
            enum CodingKeys: String, CodingKey { case quit }
            let bundleIDs: [String]

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if let id = try? values.decode(String.self, forKey: .quit) {
                    bundleIDs = [id]
                } else {
                    bundleIDs = (try? values.decode([String].self, forKey: .quit)) ?? []
                }
            }
        }

        let isApp: Bool
        let appName: String?
        let isSimple: Bool
        let uninstall: [Uninstall]

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            isApp = values.contains(.app)
            uninstall = (try? values.decode([Uninstall].self, forKey: .uninstall)) ?? []
            var app = try? values.nestedUnkeyedContainer(forKey: .app)
            let source = try? app?.decode(String.self)
            let options = try? app?.decode(Target.self)
            let declaredTarget = try? values.decode(String.self, forKey: .target)
            appName = source.map { ((options?.target ?? declaredTarget ?? $0) as NSString).lastPathComponent }
            let keys = try decoder.container(keyedBy: ArtifactKey.self).allKeys
            // Command links and completion generation are Homebrew integration for a standalone app.
            let appAndCommandIntegration = ["app", "target", "uninstall", "zap", "binary",
                                            "command_wrapper", "generate_completions_from_executable"]
            isSimple = keys.allSatisfy { appAndCommandIntegration.contains($0.stringValue) }
                && (!isApp || (source?.contains("/") == false && app?.isAtEnd == true))
        }
    }

    private struct Cask: Decodable {
        struct Variation: Decodable {
            let version: String?
            let artifacts: [Artifact]?
            let disabled: Bool?
            let deprecated: Bool?
            let url: URL?
            let sha256: String?
        }

        let version: String
        let deprecated: Bool
        let disabled: Bool
        let artifacts: [Artifact]
        let variations: [String: Variation]?
        let url: URL?
        let sha256: String?

        // A cask may mention helpers in its uninstall stanza. Only trust the
        // association when it contains exactly one app and one quit identity.
        static func identity(in artifacts: [Artifact]) -> Identity? {
            let apps = artifacts.filter(\.isApp)
            let ids = Set(artifacts.flatMap(\.uninstall).flatMap(\.bundleIDs))
            guard apps.count == 1, let appName = apps.first?.appName,
                  appName.hasSuffix(".app"), ids.count == 1, let bundleID = ids.first else { return nil }
            return Identity(bundleID: bundleID, appName: appName)
        }

        var hasMatchingMacVariations: Bool {
            let base = Self.identity(in: artifacts)
            return (variations ?? [:]).allSatisfy { platform, variation in
                platform.hasSuffix("_linux") ||
                    (variation.version.map { $0 == version } != false &&
                     variation.artifacts.map { Self.identity(in: $0) == base } != false &&
                     variation.disabled != true && variation.deprecated != true)
            }
        }

        func releaseArtifact(architecture: String) -> ReleaseArtifact? {
            let macVariations = (variations ?? [:]).filter { !$0.key.hasSuffix("_linux") }.values
            guard artifacts.allSatisfy(\.isSimple),
                  macVariations.allSatisfy({ $0.artifacts?.allSatisfy(\.isSimple) ?? true }),
                  let base = ReleaseArtifact(url: url, sha256: sha256) else { return nil }
            let variants = macVariations.compactMap { variation -> ReleaseArtifact? in
                // A changed URL without its own checksum is not a pinned alternate download.
                let url = variation.url ?? url
                let hash = variation.sha256 ?? (url == self.url ? sha256 : nil)
                return ReleaseArtifact(url: url, sha256: hash)
            }
            guard variants.count == macVariations.count else { return nil }
            let artifacts = Set(variants + [base])
            if artifacts.count == 1 { return base }
            let matches = artifacts.filter { $0.matchesArchitecture(architecture) }
            return matches.count == 1 ? matches.first : nil
        }
    }

    private let releases: [Identity: PublishedRelease]

    init(data: Data, architecture: String = ReleaseArtifact.nativeArchitecture) throws {
        let casks = try JSONDecoder().decode([Cask].self, from: data)
        var matches: [Identity: [Cask]] = [:]
        for cask in casks where !cask.disabled && !cask.deprecated {
            if let identity = Cask.identity(in: cask.artifacts) {
                matches[identity, default: []].append(cask)
            }
        }
        releases = matches.compactMapValues { candidates in
            guard candidates.count == 1, let cask = candidates.first, cask.hasMatchingMacVariations else { return nil }
            return PublishedRelease(version: cask.version, artifact: cask.releaseArtifact(architecture: architecture))
        }
    }

    func newerRelease(bundleID: String, appPath: String, installed: String) -> PublishedRelease? {
        let key = Identity(bundleID: bundleID, appName: (appPath as NSString).lastPathComponent)
        guard let release = releases[key],
              ReleaseRepository.compare(release.version, installed: installed) == .orderedDescending else { return nil }
        return release
    }

    static func fetch() async -> HomebrewCatalog? {
        let endpoint = URL(string: "https://formulae.brew.sh/api/cask.json")!
        let request = URLRequest(url: endpoint, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == endpoint.host else { return nil }
        return try? HomebrewCatalog(data: data)
    }
}
