import Foundation

/// Published cask versions can point users to a newer release for a manually
/// installed app. This catalog never establishes eligibility for installation.
struct HomebrewCatalog: Sendable {
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
        }
    }

    private struct Cask: Decodable {
        struct Variation: Decodable {
            let version: String?
            let artifacts: [Artifact]?
            let disabled: Bool?
            let deprecated: Bool?
        }

        let version: String
        let deprecated: Bool
        let disabled: Bool
        let artifacts: [Artifact]
        let variations: [String: Variation]?

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
    }

    private let versions: [Identity: String]

    init(data: Data) throws {
        let casks = try JSONDecoder().decode([Cask].self, from: data)
        var matches: [Identity: [Cask]] = [:]
        for cask in casks where !cask.disabled && !cask.deprecated {
            if let identity = Cask.identity(in: cask.artifacts) {
                matches[identity, default: []].append(cask)
            }
        }
        versions = matches.compactMapValues { candidates in
            guard candidates.count == 1, let cask = candidates.first, cask.hasMatchingMacVariations else { return nil }
            return cask.version
        }
    }

    func newerVersion(bundleID: String, appPath: String, installed: String) -> String? {
        let key = Identity(bundleID: bundleID, appName: (appPath as NSString).lastPathComponent)
        guard let version = versions[key],
              ReleaseRepository.compare(version, installed: installed) == .orderedDescending else { return nil }
        return version
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
