import Darwin
import Foundation

/// Whitelist matching that mirrors the engine contract: each entry is an exact bundle ID or a
/// shell-style glob (`*`, `?`, `[...]`) matched case-sensitively against the whole bundle ID,
/// like Python's `fnmatch.fnmatchcase`.
public enum Whitelist {
    public static func matches(pattern: String, bundleID: String) -> Bool {
        if pattern == bundleID { return true }
        guard isGlob(pattern) else { return false }
        // FNM_NOESCAPE: Python's fnmatch has no backslash escaping. No FNM_PATHNAME/FNM_PERIOD, so
        // `*` matches any characters including dots, as in fnmatchcase.
        return fnmatch(pattern, bundleID, FNM_NOESCAPE) == 0
    }

    public static func matches(patterns: [String], bundleID: String) -> Bool {
        patterns.contains { matches(pattern: $0, bundleID: bundleID) }
    }

    /// The first pattern that matches, if any (useful for explaining why an app is whitelisted).
    public static func firstMatch(in patterns: [String], bundleID: String) -> String? {
        patterns.first { matches(pattern: $0, bundleID: bundleID) }
    }

    public static func isGlob(_ pattern: String) -> Bool {
        pattern.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    /// nil when the entry is acceptable.
    public static func validationError(for entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a bundle ID or pattern." }
        if trimmed.contains(where: \.isWhitespace) { return "Bundle IDs and patterns cannot contain spaces." }
        if trimmed.allSatisfy({ $0 == "*" || $0 == "?" || $0 == "." }) {
            return "That pattern would match every app. Use something more specific, such as com.example.*"
        }
        return nil
    }
}
