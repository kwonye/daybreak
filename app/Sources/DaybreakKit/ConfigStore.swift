import Foundation

public enum ConfigError: Error, LocalizedError, Equatable {
    case invalidJSON(String)
    case notAnObject
    case unexpectedType(key: String, expected: String)
    case invalidSettings([String])

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail):
            return "The configuration file is not valid JSON (\(detail)). Fix it by hand; Daybreak will not overwrite it."
        case .notAnObject:
            return "The configuration file must contain a JSON object. Daybreak will not overwrite it."
        case .unexpectedType(let key, let expected):
            return "Configuration key “\(key)” must be \(expected). Fix it by hand; Daybreak will not overwrite it."
        case .invalidSettings(let problems):
            return problems.joined(separator: "\n")
        }
    }
}

/// Where a whitelist entry lives in the configuration file.
public enum WhitelistSource: String, Sendable, Hashable {
    case whitelist
    /// Legacy `exclude` key, still honoured by the engine.
    case exclude
}

public struct WhitelistEntry: Sendable, Hashable, Identifiable {
    public let pattern: String
    public let source: WhitelistSource
    public var id: String { pattern }

    public init(pattern: String, source: WhitelistSource) {
        self.pattern = pattern
        self.source = source
    }
}

/// The subset of engine settings the Settings window edits.
public struct EngineSettings: Sendable, Equatable {
    public static let defaultTimezone = "America/Los_Angeles"

    public var hour: Int = 8
    public var timezone: String = EngineSettings.defaultTimezone
    public var quitTimeoutSeconds: Double = 60
    public var restartCurrent: Bool = true
    public var restartUnmanaged: Bool = true

    public init() {}

    /// Human readable problems; empty when valid. Mirrors `daybreak/config.py`.
    public func validationErrors() -> [String] {
        var problems: [String] = []
        if !(0...23).contains(hour) { problems.append("Hour must be an integer from 0 through 23.") }
        if !(1...600).contains(quitTimeoutSeconds) { problems.append("Quit timeout must be between 1 and 600 seconds.") }
        if TimeZone(identifier: timezone) == nil { problems.append("“\(timezone)” is not a valid IANA time zone.") }
        return problems
    }
}

/// A parsed configuration document. Every key is preserved; only the keys the UI owns are
/// ever modified (`whitelist`, `exclude` on removal, and the scalar settings).
public struct ConfigDocument: Sendable, Equatable {
    public var root: [String: JSONValue]

    public init(root: [String: JSONValue] = [:]) {
        self.root = root
    }

    public static func parse(_ data: Data) throws -> ConfigDocument {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return ConfigDocument()  // An empty file is treated like a missing one.
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ConfigError.invalidJSON((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)
        }
        guard case .object(let root) = try JSONValue(foundation: object) else { throw ConfigError.notAnObject }
        return ConfigDocument(root: root)
    }

    /// Pretty-printed, sorted keys, trailing newline (matches the engine's `write_json`).
    public func serialized() throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: JSONValue.object(root).foundationValue,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    // MARK: Whitelist

    func stringList(_ key: String) throws -> [String] {
        guard let value = root[key] else { return [] }
        guard case .array(let items) = value else {
            throw ConfigError.unexpectedType(key: key, expected: "an array of strings")
        }
        return try items.map {
            guard let string = $0.stringValue else {
                throw ConfigError.unexpectedType(key: key, expected: "an array of strings")
            }
            return string
        }
    }

    /// `whitelist` entries followed by legacy `exclude` entries, de-duplicated.
    public func whitelistEntries() throws -> [WhitelistEntry] {
        var seen = Set<String>()
        var entries: [WhitelistEntry] = []
        for pattern in try stringList("whitelist") where seen.insert(pattern).inserted {
            entries.append(WhitelistEntry(pattern: pattern, source: .whitelist))
        }
        for pattern in try stringList("exclude") where seen.insert(pattern).inserted {
            entries.append(WhitelistEntry(pattern: pattern, source: .exclude))
        }
        return entries
    }

    /// Adds to `whitelist`. Returns false if the pattern is already present under either key.
    @discardableResult
    public mutating func addWhitelistPattern(_ pattern: String) throws -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Whitelist.validationError(for: trimmed) { throw ConfigError.invalidSettings([problem]) }
        var whitelist = try stringList("whitelist")
        let exclude = try stringList("exclude")
        guard !whitelist.contains(trimmed), !exclude.contains(trimmed) else { return false }
        whitelist.append(trimmed)
        root["whitelist"] = .array(whitelist.map(JSONValue.string))
        return true
    }

    /// Re-inserts an entry under the key it came from (used to undo a removal).
    public mutating func restoreWhitelistEntry(_ entry: WhitelistEntry) throws {
        let key = entry.source.rawValue
        var list = try stringList(key)
        let all = try whitelistEntries().map(\.pattern)
        guard !all.contains(entry.pattern) else { return }
        list.append(entry.pattern)
        root[key] = .array(list.map(JSONValue.string))
    }

    /// Removes the pattern from `whitelist` and from legacy `exclude`.
    public mutating func removeWhitelistPattern(_ pattern: String) throws {
        for key in ["whitelist", "exclude"] where root[key] != nil {
            let remaining = try stringList(key).filter { $0 != pattern }
            root[key] = .array(remaining.map(JSONValue.string))
        }
    }

    // MARK: Settings

    public func settings() throws -> EngineSettings {
        var settings = EngineSettings()
        if let value = root["hour"] {
            guard let hour = value.intValue else { throw ConfigError.unexpectedType(key: "hour", expected: "an integer") }
            settings.hour = hour
        }
        if let value = root["timezone"] {
            guard let zone = value.stringValue else { throw ConfigError.unexpectedType(key: "timezone", expected: "a string") }
            settings.timezone = zone
        }
        if let value = root["quit_timeout_seconds"] {
            guard let timeout = value.numberValue else { throw ConfigError.unexpectedType(key: "quit_timeout_seconds", expected: "a number") }
            settings.quitTimeoutSeconds = timeout
        }
        for (key, path) in [("restart_current", \EngineSettings.restartCurrent), ("restart_unmanaged", \EngineSettings.restartUnmanaged)] {
            if let value = root[key] {
                guard let flag = value.boolValue else { throw ConfigError.unexpectedType(key: key, expected: "true or false") }
                settings[keyPath: path] = flag
            }
        }
        return settings
    }

    /// Writes only the settings whose value differs from `original`, so untouched defaults are not
    /// materialised into the file.
    public mutating func applySettings(_ settings: EngineSettings, original: EngineSettings) throws {
        let problems = settings.validationErrors()
        guard problems.isEmpty else { throw ConfigError.invalidSettings(problems) }
        if settings.hour != original.hour { root["hour"] = .int(settings.hour) }
        if settings.timezone != original.timezone { root["timezone"] = .string(settings.timezone) }
        if settings.quitTimeoutSeconds != original.quitTimeoutSeconds {
            let value = settings.quitTimeoutSeconds
            root["quit_timeout_seconds"] = value.rounded() == value ? .int(Int(value)) : .double(value)
        }
        if settings.restartCurrent != original.restartCurrent { root["restart_current"] = .bool(settings.restartCurrent) }
        if settings.restartUnmanaged != original.restartUnmanaged { root["restart_unmanaged"] = .bool(settings.restartUnmanaged) }
    }
}

/// Preserving read/modify/write access to the engine configuration file.
public struct ConfigStore: Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/daybreak/config.json")
    }

    public let url: URL

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Missing file → empty document. Unparseable file → throws (and is never overwritten).
    public func load() throws -> ConfigDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return ConfigDocument()
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return ConfigDocument()
        }
        return try ConfigDocument.parse(data)
    }

    /// Atomic write. Symlinks (e.g. dotfile managers) are resolved so the link target is updated.
    public func save(_ document: ConfigDocument) throws {
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try document.serialized().write(to: target, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// Re-reads the file from disk, applies `change`, and writes it back. If the file fails to
    /// parse, nothing is written and the parse error is thrown.
    @discardableResult
    public func update(_ change: (inout ConfigDocument) throws -> Void) throws -> ConfigDocument {
        var document = try load()
        let before = document
        try change(&document)
        if document != before {
            try save(document)
        }
        return document
    }
}
