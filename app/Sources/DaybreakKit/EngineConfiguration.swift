import Foundation

struct EngineConfiguration: Sendable {
    let timeZone: TimeZone
    let timeZoneID: String
    let hour: Int
    let quitTimeout: TimeInterval
    let restartCurrent: Bool
    let restartUnmanaged: Bool
    let patterns: [String]
    let sparkleCLI: String?
    let apps: [String: [String: JSONValue]]

    init(url: URL?, skip: [String] = []) throws {
        let root: JSONValue
        if let url {
            do {
                root = try JSONValue(foundation: JSONSerialization.jsonObject(with: Data(contentsOf: url), options: .fragmentsAllowed))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                root = .object([:])
            }
        } else {
            root = .object([:])
        }
        guard case .object(let object) = root else { throw EngineFailure("Configuration must be a JSON object") }
        guard case .object(let specs) = object["apps"] ?? .object([:]) else { throw EngineFailure("apps must be an object") }
        let exclude = try Self.patterns(object["exclude"], nonempty: false, error: "exclude must be a list of bundle IDs")
        let whitelist = try Self.patterns(object["whitelist"], nonempty: true, error: "whitelist must be a list of bundle IDs or patterns")
        guard !skip.contains("") else { throw EngineFailure("whitelist must be a list of bundle IDs or patterns") }
        patterns = whitelist + skip + exclude

        restartUnmanaged = try Self.boolean("restart_unmanaged", in: object, default: EngineSettings.defaultRestartUnmanaged)
        restartCurrent = try Self.boolean("restart_current", in: object, default: true)
        guard let hour = (object["hour"] ?? .int(8)).intValue, (0...23).contains(hour) else {
            throw EngineFailure("hour must be an integer from 0 through 23")
        }
        self.hour = hour
        guard let timeout = (object["quit_timeout_seconds"] ?? .int(60)).numberValue, (1...600).contains(timeout) else {
            throw EngineFailure("quit_timeout_seconds must be between 1 and 600")
        }
        quitTimeout = timeout
        guard let zone = (object["timezone"] ?? .string(EngineSettings.defaultTimezone)).stringValue,
              let timeZone = TimeZone(identifier: zone), timeZone.identifier == zone || zone.contains("/") || zone == "UTC" else {
            throw EngineFailure("timezone must be a valid IANA timezone")
        }
        self.timeZone = timeZone
        timeZoneID = zone
        if let value = object["sparkle_cli"], value.stringValue == nil {
            throw EngineFailure("sparkle_cli must be a path string")
        }
        sparkleCLI = object["sparkle_cli"]?.stringValue
        apps = try Dictionary(uniqueKeysWithValues: specs.map { id, entry in
            guard case .object(let spec) = entry else {
                throw EngineFailure("Every apps entry must be a bundle ID mapped to an object")
            }
            if let value = spec["allow_workload_interruption"], value.boolValue == nil {
                throw EngineFailure("\(id).allow_workload_interruption must be a boolean")
            }
            for key in ["backend", "executable", "cask"] where spec[key] != nil && spec[key]?.stringValue == nil {
                throw EngineFailure("\(id).\(key) must be a string")
            }
            return (id, spec)
        })
    }

    func whitelisted(_ bundleID: String) -> Bool {
        Whitelist.matches(patterns: patterns, bundleID: bundleID)
    }

    private static func boolean(_ key: String, in object: [String: JSONValue], default fallback: Bool) throws -> Bool {
        guard let value = (object[key] ?? .bool(fallback)).boolValue else { throw EngineFailure("\(key) must be a boolean") }
        return value
    }

    private static func patterns(_ value: JSONValue?, nonempty: Bool, error: String) throws -> [String] {
        guard let items = (value ?? .array([])).arrayValue else { throw EngineFailure(error) }
        return try items.map {
            guard let pattern = $0.stringValue, !nonempty || !pattern.isEmpty else { throw EngineFailure(error) }
            return pattern
        }
    }
}
