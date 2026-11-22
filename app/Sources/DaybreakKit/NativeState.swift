import Darwin
import Foundation

struct EngineFailure: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

struct NativeState: Sendable {
    let directory: URL

    func status() throws -> Data {
        let url = directory.appendingPathComponent("latest.json")
        do {
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            return try Self.json(object)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return try Self.json(["status": "never_run"])
        }
    }

    func withLock<T>(_ action: () throws -> T) throws -> T {
        let fd = try acquireLock()
        defer { close(fd) }
        return try action()
    }

    func withAsyncLock<T>(_ action: () async throws -> T) async throws -> T {
        let fd = try acquireLock()
        defer { close(fd) }
        return try await action()
    }

    private func acquireLock() throws -> Int32 {
        try createDirectory(directory)
        let fd = open(directory.appendingPathComponent("run.lock").path, O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.posixError() }
        do {
            guard fchmod(fd, 0o600) == 0 else { throw Self.posixError() }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw EngineFailure("Another Daybreak run is active") }
                throw Self.posixError()
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    func due(at now: Date, config: EngineConfiguration) throws -> (isDue: Bool, localDate: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = config.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        let date = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let previous: String?
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("schedule.json"))
            guard let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EngineFailure("Schedule state must be a JSON object")
            }
            previous = state["last_date"] as? String
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            previous = nil
        }
        return ((parts.hour ?? 0) >= config.hour && date != previous, date)
    }

    func consume(date: String, startedAt: String) throws {
        try write(Self.json(["last_date": date, "started_at": startedAt, "status": "started"]),
                  to: directory.appendingPathComponent("schedule.json"))
    }

    func save(_ report: Data, at date: Date = Date()) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let sequence = String(format: "%020llu", DispatchTime.now().uptimeNanoseconds)
        let name = "\(formatter.string(from: date))-\(sequence)-\(getpid()).json"
        let runs = directory.appendingPathComponent("runs")
        try write(report, to: runs.appendingPathComponent(name))
        try write(report, to: directory.appendingPathComponent("latest.json"))
        let files = try FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && isFile($0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in files.dropLast(30) { try FileManager.default.removeItem(at: old) }
    }

    static func json(_ value: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        data.append(0x0a)
        return data
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func write(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        // A private temporary file on the same volume keeps permissions and atomic replacement.
        var template = Array(url.deletingLastPathComponent().appendingPathComponent(".daybreak-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw Self.posixError() }
        let path = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        defer { unlink(path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(path, url.path) == 0 else { throw Self.posixError() }
    }

    static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
