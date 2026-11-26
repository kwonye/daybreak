import Foundation

/// Time zones grouped by IANA region for the Settings picker.
public struct TimeZoneCatalog: Sendable {
    public struct Zone: Sendable, Hashable, Identifiable {
        public let identifier: String
        /// "Los Angeles", "Argentina / Buenos Aires", or the identifier itself when it has no "/".
        public let city: String
        /// "GMT−08:00" style offset at the catalog's reference date.
        public let offset: String
        public let offsetSeconds: Int
        public var id: String { identifier }

        public var searchText: String { "\(identifier) \(city) \(offset)" }
    }

    public struct Region: Sendable, Hashable, Identifiable {
        public let name: String
        public let zones: [Zone]
        public var id: String { name }
    }

    public let regions: [Region]

    /// Region used for identifiers without a "/" (UTC, GMT, EST5EDT…) and for values that are
    /// valid but absent from the known list.
    public static let otherRegion = "Other"

    /// - Parameters:
    ///   - identifiers: usually `TimeZone.knownTimeZoneIdentifiers`.
    ///   - including: extra identifiers to keep (e.g. the value already in the config) if they are valid.
    public init(identifiers: [String] = TimeZone.knownTimeZoneIdentifiers, including extra: [String] = [], now: Date = Date()) {
        var all = Set(identifiers)
        for identifier in extra where !identifier.isEmpty && TimeZone(identifier: identifier) != nil {
            all.insert(identifier)
        }
        var grouped: [String: [Zone]] = [:]
        for identifier in all {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            let parts = identifier.split(separator: "/", maxSplits: 1).map(String.init)
            let region = parts.count == 2 ? parts[0] : Self.otherRegion
            let cityPart = parts.count == 2 ? parts[1] : identifier
            let city = cityPart
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "/", with: " / ")
            let seconds = zone.secondsFromGMT(for: now)
            grouped[region, default: []].append(
                Zone(identifier: identifier, city: city, offset: Self.formatOffset(seconds), offsetSeconds: seconds))
        }
        regions = grouped
            .map { Region(name: $0.key, zones: $0.value.sorted { $0.city.localizedStandardCompare($1.city) == .orderedAscending }) }
            .sorted { lhs, rhs in
                // "Other" last; everything else alphabetical.
                if (lhs.name == Self.otherRegion) != (rhs.name == Self.otherRegion) { return rhs.name == Self.otherRegion }
                return lhs.name < rhs.name
            }
    }

    public static func formatOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "\u{2212}" : "+"
        let total = abs(seconds) / 60
        return String(format: "GMT%@%02d:%02d", sign, total / 60, total % 60)
    }

    public func zone(_ identifier: String) -> Zone? {
        for region in regions {
            if let zone = region.zones.first(where: { $0.identifier == identifier }) { return zone }
        }
        return nil
    }

    /// Case-insensitive filter over identifier, city and offset; empty regions are dropped.
    public func filtered(_ query: String) -> [Region] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return regions }
        let terms = trimmed.split(separator: " ").map(String.init)
        return regions.compactMap { region in
            let zones = region.zones.filter { zone in
                terms.allSatisfy { zone.searchText.localizedCaseInsensitiveContains($0) || region.name.localizedCaseInsensitiveContains($0) }
            }
            return zones.isEmpty ? nil : Region(name: region.name, zones: zones)
        }
    }
}
