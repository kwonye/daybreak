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

        func isNewerMacVersion(bundleID: String, installed: String, macOS: String) -> Bool {
            guard kind == "mac-software", bundleId == bundleID,
                  ReleaseRepository.compare(version, installed: installed) == .orderedDescending,
                  let minimumOsVersion,
                  let compatibility = ReleaseRepository.compare(macOS, installed: minimumOsVersion)
            else { return false }
            return compatibility != .orderedAscending
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
}
