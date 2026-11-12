import Foundation

public struct StoredRun: Sendable, Identifiable, Hashable {
    public let url: URL
    public let report: RunReport?
    public let error: String?
    public var id: URL { url }

    /// Prefer the report timestamp; fall back to the `YYYYmmddTHHMMSS-pid.json` file name.
    public var date: Date? {
        if let date = report?.startedDate { return date }
        let stamp = String(url.deletingPathExtension().lastPathComponent.prefix(15))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: stamp)
    }
}

/// Read-only access to the engine's private run reports.
public enum HistoryStore {
    public static var defaultStateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Daybreak", isDirectory: true)
    }

    /// Empty preference → the engine's default; `~` is expanded.
    public static func resolveStateDirectory(preference: String?) -> URL {
        let trimmed = preference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return defaultStateDirectory }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    public static func runs(in stateDirectory: URL) -> [StoredRun] {
        let directory = stateDirectory.appendingPathComponent("runs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { url in
                do {
                    let report = try JSONDecoder().decode(RunReport.self, from: Data(contentsOf: url))
                    return StoredRun(url: url, report: report, error: nil)
                } catch {
                    return StoredRun(url: url, report: nil, error: error.localizedDescription)
                }
            }
    }
}
