import Foundation

// All engine payloads are decoded defensively: only identifiers are required, everything else
// falls back to an empty/default value so older or newer engines still render.

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// One running app as reported by `daybreak inventory`.
public struct InventoryApp: Decodable, Sendable, Hashable, Identifiable {
    public let bundleID: String
    public let name: String
    public let path: String
    public let version: String
    public let build: String
    public let pids: [Int]
    public let hints: [String]
    public let stale: Bool
    public let executable: String
    /// nil when the engine predates the whitelist feature.
    public let engineWhitelisted: Bool?
    public let engineProtected: Bool?

    public var id: String { bundleID + "|" + path }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id", name, path, version, build, pids, hints, stale, executable
        case whitelisted, protected
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = c.value(.name, default: bundleID)
        path = c.value(.path, default: "")
        version = c.value(.version, default: "")
        build = c.value(.build, default: "")
        pids = c.value(.pids, default: [])
        hints = c.value(.hints, default: [])
        stale = c.value(.stale, default: false)
        executable = c.value(.executable, default: "")
        engineWhitelisted = try? c.decodeIfPresent(Bool.self, forKey: .whitelisted)
        engineProtected = try? c.decodeIfPresent(Bool.self, forKey: .protected)
    }

    public init(bundleID: String, name: String, path: String, version: String = "", build: String = "",
                pids: [Int] = [], hints: [String] = [], stale: Bool = false, executable: String = "",
                engineWhitelisted: Bool? = nil, engineProtected: Bool? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.version = version
        self.build = build
        self.pids = pids
        self.hints = hints
        self.stale = stale
        self.executable = executable
        self.engineWhitelisted = engineWhitelisted
        self.engineProtected = engineProtected
    }

    /// This app's bundle ID. The GUI never lets an apply run quit itself.
    public static let ownBundleID = "co.kwon.daybreak"

    public var isSelf: Bool { bundleID == Self.ownBundleID }

    static let protectedPrefixes = ["com.openai.", "org.sparkle-project.Sparkle.", "com.google.GoogleUpdater", "io.tailscale."]

    /// Engine value when present, else the same rule as `daybreak.models.protected`.
    public var isProtected: Bool {
        if let engineProtected { return engineProtected }
        return Self.protectedPrefixes.contains { bundleID.hasPrefix($0) }
            || ["/System/", "/usr/", "/Library/Apple/"].contains { path.hasPrefix($0) }
            || path.contains("/Contents/")
    }

    /// Local whitelist evaluation OR'd with the engine's report (the engine may know about
    /// entries the UI does not, e.g. a config edited elsewhere).
    public func isWhitelisted(by patterns: [String]) -> Bool {
        engineWhitelisted == true || Whitelist.matches(patterns: patterns, bundleID: bundleID)
    }

    public var versionDescription: String {
        switch (version.isEmpty, build.isEmpty || build == version) {
        case (true, _): return build
        case (false, true): return version
        case (false, false): return "\(version) (\(build))"
        }
    }
}

public enum StatusTone: String, Sendable {
    case success, info, neutral, warning, danger
}

/// A per-app result status. Unknown values are kept verbatim and rendered generically.
public struct ResultStatus: RawRepresentable, Hashable, Sendable, Decodable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws {
        rawValue = (try? decoder.singleValueContainer().decode(String.self)) ?? "unknown"
    }

    public static let updatedAndRelaunched = ResultStatus(rawValue: "updated_and_relaunched")
    public static let checkedAndRelaunched = ResultStatus(rawValue: "checked_and_relaunched")
    public static let restartOnlyUnverified = ResultStatus(rawValue: "restart_only_unverified")
    public static let current = ResultStatus(rawValue: "current")
    public static let deferred = ResultStatus(rawValue: "deferred")
    public static let blocked = ResultStatus(rawValue: "blocked")
    public static let failed = ResultStatus(rawValue: "failed")
    public static let uncertain = ResultStatus(rawValue: "uncertain")
    public static let unsupported = ResultStatus(rawValue: "unsupported")
    public static let skipped = ResultStatus(rawValue: "skipped")
    public static let excluded = ResultStatus(rawValue: "excluded")
    public static let planned = ResultStatus(rawValue: "planned")

    public static let known: [ResultStatus] = [
        .updatedAndRelaunched, .checkedAndRelaunched, .restartOnlyUnverified, .current, .deferred,
        .blocked, .failed, .uncertain, .unsupported, .skipped, .excluded, .planned,
    ]

    public var isKnown: Bool { Self.known.contains(self) }

    public var title: String {
        switch self {
        case .updatedAndRelaunched: "Updated"
        case .checkedAndRelaunched: "Checked & Relaunched"
        case .restartOnlyUnverified: "Restarted (Unverified)"
        case .current: "Current"
        case .deferred: "Deferred"
        case .blocked: "Blocked"
        case .failed: "Failed"
        case .uncertain: "Uncertain"
        case .unsupported: "Unsupported"
        case .skipped: "Skipped"
        case .excluded: "Excluded"
        case .planned: "Planned"
        default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var tone: StatusTone {
        switch self {
        case .updatedAndRelaunched, .checkedAndRelaunched, .current: .success
        case .planned: .info
        case .restartOnlyUnverified, .deferred, .uncertain, .unsupported: .warning
        case .blocked, .failed: .danger
        default: .neutral
        }
    }

    public var symbolName: String {
        switch self {
        case .updatedAndRelaunched: "arrow.up.circle.fill"
        case .checkedAndRelaunched: "checkmark.circle.fill"
        case .restartOnlyUnverified: "arrow.clockwise.circle"
        case .current: "checkmark.seal.fill"
        case .deferred: "clock.badge.exclamationmark"
        case .blocked: "hand.raised.fill"
        case .failed: "xmark.octagon.fill"
        case .uncertain: "questionmark.circle.fill"
        case .unsupported: "minus.circle"
        case .skipped: "forward.fill"
        case .excluded: "shield.lefthalf.filled"
        case .planned: "list.bullet.clipboard"
        default: "circle.dashed"
        }
    }

    /// Statuses for which the engine exits 2.
    public var needsAttention: Bool {
        [.failed, .blocked, .deferred, .unsupported, .uncertain, .restartOnlyUnverified].contains(self)
    }
}

/// One per-app entry from `run` or `status`.
public struct RunResult: Decodable, Sendable, Hashable, Identifiable {
    public let bundleID: String
    public let name: String
    public let status: ResultStatus
    public let backend: String
    public let before: String
    public let after: String
    public let beforeBuild: String
    public let afterBuild: String
    public let updateOutcome: String
    public let detail: String
    public let oldPIDs: [Int]
    public let newPIDs: [Int]
    public let verification: String
    /// Position in the report, so duplicate bundle IDs still get distinct identities.
    public var index: Int = 0

    public var id: String { "\(index)|\(bundleID)" }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id", name, status, backend, before, after
        case beforeBuild = "before_build", afterBuild = "after_build", updateOutcome = "update_outcome"
        case detail, oldPIDs = "old_pids", newPIDs = "new_pids", verification
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = c.value(.bundleID, default: "")
        name = c.value(.name, default: bundleID)
        status = c.value(.status, default: ResultStatus(rawValue: "unknown"))
        backend = c.value(.backend, default: "")
        before = c.value(.before, default: "")
        after = c.value(.after, default: "")
        beforeBuild = c.value(.beforeBuild, default: "")
        afterBuild = c.value(.afterBuild, default: "")
        updateOutcome = c.value(.updateOutcome, default: "")
        detail = c.value(.detail, default: "")
        oldPIDs = c.value(.oldPIDs, default: [])
        newPIDs = c.value(.newPIDs, default: [])
        verification = c.value(.verification, default: "")
    }

    /// "1.0 → 1.1", "1.0", or "" depending on what the engine reported.
    public var versionChange: String {
        let from = Self.describe(before, beforeBuild)
        let to = Self.describe(after, afterBuild)
        if to.isEmpty || to == from { return from }
        if from.isEmpty { return to }
        return "\(from) → \(to)"
    }

    static func describe(_ version: String, _ build: String) -> String {
        if version.isEmpty { return build }
        if build.isEmpty || build == version { return version }
        return "\(version) (\(build))"
    }
}

/// A full `run` report, also the shape of `status` / `latest.json` / `runs/*.json`.
/// `status` is only set for non-report payloads such as `{"status": "never_run"}` or `not_due`.
public struct RunReport: Decodable, Sendable, Hashable {
    public let startedAt: String?
    public let apply: Bool
    public let timezone: String?
    public let results: [RunResult]
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at", apply, timezone, results, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = c.value(.startedAt, default: nil as String?)
        apply = c.value(.apply, default: false)
        timezone = c.value(.timezone, default: nil as String?)
        status = c.value(.status, default: nil as String?)
        // Decode each element independently so one malformed entry does not hide the rest.
        var decoded: [RunResult] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .results) {
            while !list.isAtEnd {
                if var result = try? list.decode(RunResult.self) {
                    result.index = decoded.count
                    decoded.append(result)
                } else {
                    _ = try? list.decode(JSONSkip.self)
                }
            }
        }
        results = decoded
    }

    public var isNeverRun: Bool { status == "never_run" }

    public var startedDate: Date? { startedAt.flatMap(ISODate.parse) }

    public var attentionCount: Int { results.filter(\.status.needsAttention).count }

    public func count(_ status: ResultStatus) -> Int { results.filter { $0.status == status }.count }
}

/// Consumes any JSON value; used to step past undecodable array elements.
struct JSONSkip: Decodable {
    init(from decoder: Decoder) throws {}
}

/// `{"status": "error", "detail": "..."}` printed on stderr when the engine exits 1.
public struct EngineErrorPayload: Decodable, Sendable {
    public let status: String?
    public let detail: String?
}

public enum ISODate {
    /// Parses Python `isoformat()` timestamps, which may carry microseconds.
    public static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let stripped = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        guard let base = plain.date(from: stripped) else { return nil }
        if let range = string.range(of: #"\.\d+"#, options: .regularExpression),
           let fraction = Double("0" + string[range]) {
            return base.addingTimeInterval(fraction)
        }
        return base
    }
}
