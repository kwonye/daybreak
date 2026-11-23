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

    func latestTag() async throws -> String? {
        let endpoint = URL(string: "https://api.github.com/repos/\(name)/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.host == "api.github.com" else {
            throw EngineFailure("GitHub returned an unexpected response.")
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else {
            throw EngineFailure("GitHub returned HTTP \(response.statusCode).")
        }
        struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.draft || release.prerelease ? nil : release.tag_name
    }

    static func compare(_ tag: String, installed: String) -> ComparisonResult? {
        func parts(_ version: String) -> [Int]? {
            let value = version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
            guard value.wholeMatch(of: /[0-9]+(\.[0-9]+){1,3}/) != nil else { return nil }
            let parts = value.split(separator: ".").compactMap { Int($0) }
            guard parts.count == value.split(separator: ".").count else { return nil }
            return parts + Array(repeating: 0, count: 4 - parts.count)
        }
        guard let published = parts(tag), let local = parts(installed) else { return nil }
        if published == local { return .orderedSame }
        return published.lexicographicallyPrecedes(local) ? .orderedAscending : .orderedDescending
    }
}
