import Foundation

/// The public catalog can report a newer published Mac version. Only the
/// App Store client can establish what is offered to the signed-in account.
struct AppStoreCatalog: Sendable {
    struct Listing: Decodable, Sendable {
        let trackId: Int
        let bundleId: String
        let version: String
        let minimumOsVersion: String?
        let kind: String

        func compareMacVersion(bundleID: String, installed: String, macOS: String) -> ComparisonResult? {
            guard kind == "mac-software", bundleId == bundleID,
                  let minimumOsVersion,
                  let compatibility = ReleaseRepository.compare(macOS, installed: minimumOsVersion),
                  compatibility != .orderedAscending else { return nil }
            return ReleaseRepository.compare(version, installed: installed)
        }
    }

    static func listings(for ids: [String]) async -> [String: Listing] {
        guard !ids.isEmpty, let region = Locale.current.region?.identifier,
              region.wholeMatch(of: /[A-Za-z]{2}/) != nil else { return [:] }
        var listings: [String: Listing] = [:]
        for offset in stride(from: 0, to: ids.count, by: 25) {
            if Task.isCancelled { return listings }
            var endpoint = URLComponents(string: "https://itunes.apple.com/lookup")!
            endpoint.queryItems = [
                URLQueryItem(name: "country", value: region.lowercased()),
                URLQueryItem(name: "entity", value: "macSoftware"),
                URLQueryItem(name: "id", value: ids[offset..<min(offset + 25, ids.count)].joined(separator: ",")),
            ]
            struct Response: Decodable { let results: [Listing] }
            let request = URLRequest(url: endpoint.url!, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 12)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.host == "itunes.apple.com",
                  let result = try? JSONDecoder().decode(Response.self, from: data) else { continue }
            for listing in result.results { listings[String(listing.trackId)] = listing }
        }
        return listings
    }

    /// Universal purchases can be tagged as mobile software in the lookup API.
    /// The explicitly Mac-scoped storefront provides a display-only version.
    static func macStorefrontVersion(id: String) async -> String? {
        guard id.wholeMatch(of: /[0-9]+/) != nil, let region = Locale.current.region?.identifier,
              region.wholeMatch(of: /[A-Za-z]{2}/) != nil,
              let url = URL(string: "https://apps.apple.com/\(region.lowercased())/app/id\(id)?platform=mac") else { return nil }
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 12)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == "apps.apple.com", http.url?.scheme == "https",
              let html = String(data: data, encoding: .utf8) else { return nil }
        return macStorefrontVersion(in: html, id: id)
    }

    static func macStorefrontVersion(in html: String, id: String) -> String? {
        guard let start = html.range(of: "<script type=\"application/json\" id=\"serialized-server-data\">"),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? [String: Any],
              let pages = json["data"] as? [[String: Any]] else { return nil }
        let matches = pages.filter {
            guard let intent = $0["intent"] as? [String: Any] else { return false }
            return intent["id"] as? String == id && intent["platform"] as? String == "mac"
        }
        guard matches.count == 1, let page = matches.first?["data"] as? [String: Any],
              let shelves = page["shelfMapping"] as? [String: Any],
              let shelf = shelves["mostRecentVersion"] as? [String: Any],
              let items = shelf["items"] as? [[String: Any]], items.count == 1,
              let label = items.first?["primarySubtitle"] as? String,
              let version = label.wholeMatch(of: /[^0-9]*([0-9]+(?:\.[0-9]+){1,3})/) else { return nil }
        return String(version.1)
    }
}
