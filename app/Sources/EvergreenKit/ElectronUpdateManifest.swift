import Foundation

/// The flat configuration and mapping/sequence subset emitted by electron-builder.
struct ElectronUpdateManifest {
    struct File {
        let path: String
        let sha512: String?
        let size: Int64?

        init?(fields: [String: String], pathKey: String) {
            guard let path = fields[pathKey], !path.isEmpty else { return nil }
            let size = fields["size"].flatMap(Int64.init)
            guard fields["size"] == nil || (size ?? 0) > 0 else { return nil }
            self.path = path
            self.sha512 = fields["sha512"]
            self.size = size
        }
    }

    let version: String
    let files: [File]

    init?(_ yaml: String) {
        var fields: [String: String] = [:]
        var entries: [[String: String]] = []
        var inFiles = false
        var sawFiles = false
        for line in yaml.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") || text == "---" || text == "..." { continue }
            if inFiles, text.hasPrefix("- ") {
                guard let (key, value) = Self.field(text.dropFirst(2)), key == "url" else { return nil }
                entries.append([key: value])
            } else if line.first?.isWhitespace == false {
                guard let (key, value) = Self.field(Substring(text)), fields[key] == nil, key != "<<" else { return nil }
                fields[key] = value
                inFiles = key == "files"
                if inFiles {
                    guard value.isEmpty else { return nil }
                    sawFiles = true
                }
            } else if inFiles {
                guard let (key, value) = Self.field(Substring(text)), key != "<<",
                      let last = entries.indices.last, entries[last][key] == nil else { return nil }
                entries[last][key] = value
            }
        }
        guard let version = fields["version"], ReleaseRepository.compare(version, installed: version) == .orderedSame,
              fields["stagingPercentage"] == nil || fields["stagingPercentage"] == "100",
              Self.meetsMinimumSystemVersion(fields["minimumSystemVersion"]) else { return nil }
        self.version = version
        if sawFiles {
            let files = entries.compactMap { File(fields: $0, pathKey: "url") }
            guard !files.isEmpty, files.count == entries.count else { return nil }
            self.files = files
        } else {
            guard let file = File(fields: fields, pathKey: "path") else { return nil }
            files = [file]
        }
    }

    static func configuration(_ yaml: String) -> [String: String]? {
        var fields: [String: String] = [:]
        for line in yaml.split(whereSeparator: \.isNewline) where line.first?.isWhitespace == false {
            if line.hasPrefix("#") || line == "---" || line == "..." { continue }
            guard let (key, value) = field(line), fields[key] == nil, key != "<<" else { return nil }
            fields[key] = value
        }
        return fields
    }

    private static func field(_ line: Substring) -> (String, String)? {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let raw = parts[1].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !raw.hasPrefix("*"), !raw.hasPrefix("&"), !raw.hasPrefix("!") else { return nil }
        if raw.first == "'" {
            guard raw.count > 1, raw.last == "'" else { return nil }
            return (key, raw.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'"))
        }
        if raw.first == "\"" {
            guard let value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) else { return nil }
            return (key, value)
        }
        return (key, raw)
    }

    private static func meetsMinimumSystemVersion(_ minimum: String?) -> Bool {
        guard let minimum else { return true }
        // electron-updater compares the Darwin kernel version.
        var length = 0
        guard sysctlbyname("kern.osrelease", nil, &length, nil, 0) == 0, length > 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctlbyname("kern.osrelease", &bytes, &length, nil, 0) == 0,
              let comparison = ReleaseRepository.compare(minimum, installed: String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
        else { return false }
        return comparison != .orderedDescending
    }
}

struct SquirrelUpdateManifest: Decodable {
    struct Target: Decodable {
        let version: String?
        let url: String
        let sha256: String?
        let size: Int64?
    }

    struct Release: Decodable {
        let version: String
        let updateTo: Target
    }

    let currentRelease: String
    let releases: [Release]

    var current: Target? {
        let matches = releases.filter { $0.version == currentRelease }
        guard matches.count == 1, let target = matches.first?.updateTo,
              target.version == nil || target.version == currentRelease else { return nil }
        return target
    }
}
