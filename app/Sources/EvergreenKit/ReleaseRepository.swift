import Foundation

/// A user-confirmed association between a local bundle ID and its official repository.
public struct ReleaseRepository: Sendable, Equatable {
    public let name: String

    public init?(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let url = URLComponents(string: value), url.scheme != nil {
            guard url.scheme == "https", url.host?.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.port == nil else { return nil }
            let path = url.path.split(separator: "/")
            guard path.count == 2 || (path.count == 3 && path[2] == "releases")
                || (path.count == 4 && path[2] == "releases" && path[3] == "latest") else { return nil }
            name = path.prefix(2).joined(separator: "/")
        } else {
            name = value
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9-]{0,38}/) != nil,
              parts[1].wholeMatch(of: /[A-Za-z0-9_.-]{1,100}/) != nil,
              parts[1] != ".", parts[1] != ".." else { return nil }
        self.name = name
    }

    public var releasesURL: URL { URL(string: "https://github.com/\(name)/releases")! }

    struct Asset: Decodable, Sendable {
        let name: String
        let state: String
        let browser_download_url: URL
        let digest: String?
    }

    struct Release: Decodable, Sendable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    func latestStableRelease() async throws -> Release? {
        let endpoint = URL(string: "https://api.github.com/repos/\(name)/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https",
              response.url?.host == "api.github.com" else {
            throw EngineFailure("GitHub returned an unexpected response.")
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else {
            throw EngineFailure("GitHub returned HTTP \(response.statusCode).")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.draft || release.prerelease ? nil : release
    }

    func latestRelease() async throws -> PublishedRelease? {
        try await latestStableRelease().map(publishedRelease)
    }

    func publishedRelease(from data: Data) throws -> PublishedRelease? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        return publishedRelease(release)
    }

    private func publishedRelease(_ release: Release) -> PublishedRelease {
        let images = release.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let candidates = images.isEmpty ? release.assets.filter { $0.name.lowercased().hasSuffix(".zip") } : images
        let artifact = candidates.count == 1 ? candidates.first.flatMap { downloadArtifact($0, in: release) } : nil
        return PublishedRelease(version: release.tag_name, artifact: artifact)
    }

    func assetURL(_ asset: Asset, in release: Release) -> URL? {
        let url = asset.browser_download_url
        guard asset.state == "uploaded", url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.pathComponents.dropFirst().prefix(2).joined(separator: "/").lowercased() == name.lowercased(),
              url.pathComponents.dropFirst(3).elementsEqual(["releases", "download", release.tag_name, asset.name])
        else { return nil }
        return url
    }

    func downloadArtifact(_ asset: Asset, in release: Release, size: Int64? = nil) -> ReleaseArtifact? {
        guard let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
        return ReleaseArtifact(url: assetURL(asset, in: release), sha256: String(digest.dropFirst(7)), size: size)
    }

    static func compare(_ tag: String, installed: String) -> ComparisonResult? {
        guard let offer = ReleaseVersion(tag), let local = ReleaseVersion(installed) else { return nil }
        if offer.core != local.core {
            return offer.core.lexicographicallyPrecedes(local.core) ? .orderedAscending : .orderedDescending
        }
        if offer.prerelease == local.prerelease { return .orderedSame }
        if offer.prerelease.isEmpty { return .orderedDescending }
        if local.prerelease.isEmpty { return .orderedAscending }
        for (left, right) in zip(offer.prerelease, local.prerelease) where left != right {
            let leftNumeric = left.allSatisfy(\.isNumber)
            let rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric != rightNumeric { return leftNumeric ? .orderedAscending : .orderedDescending }
            if leftNumeric && left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
            return left < right ? .orderedAscending : .orderedDescending
        }
        return offer.prerelease.count < local.prerelease.count ? .orderedAscending : .orderedDescending
    }

    private struct ReleaseVersion {
        let core: [Int]
        let prerelease: [Substring]

        init?(_ version: String) {
            let value = version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
            let digits: Substring
            if value.wholeMatch(of: /[0-9]+(\.[0-9]+){1,3}/) != nil {
                digits = value[...]
                prerelease = []
            } else {
                guard let match = value.wholeMatch(of: /((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?/)
                else { return nil }
                digits = match.1
                prerelease = match.2?.split(separator: ".") ?? []
                guard !prerelease.contains(where: { $0.count > 1 && $0.first == "0" && $0.allSatisfy(\.isNumber) })
                else { return nil }
            }
            let components = digits.split(separator: ".")
            let numbers = components.compactMap { Int($0) }
            guard components.count == numbers.count else { return nil }
            core = numbers + Array(repeating: 0, count: 4 - numbers.count)
        }
    }
}
