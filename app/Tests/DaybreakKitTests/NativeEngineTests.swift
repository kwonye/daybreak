import Foundation
import os
import Testing
@testable import DaybreakKit

@Suite struct NativeEngineTests {
    @Test func previewOnlyUsesInventoryAndPreservesState() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let platform = FakePlatform([sample(), sample(id: "com.docker.docker"),
                                     sample(id: "co.kwon.daybreak"), sample(id: "com.example.skip")])
        let runner = UpdaterProcess { _, _ in Issue.record("Preview invoked a program"); throw EngineFailure("unexpected") }
        let engine = NativeEngine(configURL: nil, stateDirectory: directory, process: runner, platform: platform)
        let output = try engine.execute(.run, due: true, skip: ["com.example.skip"]) {
            date("2026-11-20T20:00:00Z")
        }
        let report = try JSONDecoder().decode(RunReport.self, from: output.data)
        #expect(platform.events == ["inventory"])
        #expect(output.exitCode == 2)
        #expect(report.results.map(\.status) == [.unsupported, .blocked, .excluded, .excluded])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: EngineFailure.self) { try engine.execute(.run, skip: [""]) }
    }

    @Test func applyOnlyTargetsConfirmedRunningInstances() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = temporaryURL()
        defer { try? FileManager.default.removeItem(at: config) }
        try Data(#"{"restart_unmanaged":true}"#.utf8).write(to: config)
        let first = sample()
        let duplicate = sample(id: first.bundleID, path: "/Applications/Duplicate.app")
        let platform = FakePlatform([first, duplicate])
        let engine = NativeEngine(configURL: config, stateDirectory: directory, platform: platform)
        let preview = try JSONDecoder().decode(RunReport.self, from: engine.execute(.run).data)
        let selected = try #require(preview.results.first)
        #expect(selected.path == first.path)
        let result = try engine.execute(.run, apply: true, confirmed: [selected])
        let applied = try JSONDecoder().decode(RunReport.self, from: result.data)
        #expect(applied.results.map(\.path) == [first.path])
        #expect(applied.results.map(\.status) == [.restartOnlyUnverified])

        let changed = AppProcess(bundleID: first.bundleID, name: first.name, path: first.path,
                                 pid: first.pids[0], launched: 2, executable: first.metadata.executable)
        let replaced = ManagedApp(bundleID: first.bundleID, name: first.name, path: first.path,
                                  processes: [changed], metadata: first.metadata, stale: false)
        let changedPlatform = FakePlatform([replaced, duplicate])
        let changedEngine = NativeEngine(configURL: config, stateDirectory: directory, platform: changedPlatform)
        let skipped = try changedEngine.execute(.run, apply: true, confirmed: [selected])
        let skippedReport = try JSONDecoder().decode(RunReport.self, from: skipped.data)
        #expect(skippedReport.results.map(\.status) == [.skipped])
        #expect(changedPlatform.events == ["inventory"])
    }

    @Test func dueRunConsumesDateBeforeInventoryFailure() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let platform = FakePlatform([])
        platform.inventoryError = EngineFailure("cannot access inventory")
        let engine = NativeEngine(configURL: nil, stateDirectory: directory, platform: platform)
        let now = { date("2026-11-20T20:00:00Z") }
        #expect(throws: EngineFailure("cannot access inventory")) {
            try engine.execute(.run, apply: true, due: true, now: now)
        }
        let result = try engine.execute(.run, apply: true, due: true, now: now)
        let report = try JSONDecoder().decode(RunReport.self, from: result.data)
        #expect(report.status == "not_due")
        #expect(platform.events == ["inventory"])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("latest.json").path))
    }

    @Test(arguments: [
        ("2026-03-08T14:59:00Z", false), ("2026-03-08T15:00:00Z", true),
        ("2026-11-01T15:59:00Z", false), ("2026-11-01T16:00:00Z", true),
    ])
    func scheduleUsesPacificWallTime(timestamp: String, expected: Bool) throws {
        let state = NativeState(directory: temporaryURL())
        let config = try EngineConfiguration(url: nil)
        #expect(try state.due(at: date(timestamp), config: config).isDue == expected)
    }

    @Test func scheduleHonorsCadenceDayAndMinute() throws {
        let config = temporaryURL()
        let directory = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: directory)
        }
        let state = NativeState(directory: directory)
        try Data(#"{"timezone":"UTC","hour":8,"minute":35,"schedule_cadence":"weekdays"}"#.utf8).write(to: config)
        let weekdays = try EngineConfiguration(url: config)
        #expect(try !state.due(at: date("2026-11-22T09:00:00Z"), config: weekdays).isDue)
        #expect(try !state.due(at: date("2026-11-23T08:34:00Z"), config: weekdays).isDue)
        #expect(try state.due(at: date("2026-11-23T08:35:00Z"), config: weekdays).isDue)
        try Data(#"{"timezone":"UTC","hour":8,"minute":35,"schedule_cadence":"weekly","schedule_weekday":3}"#.utf8).write(to: config)
        let weekly = try EngineConfiguration(url: config)
        #expect(try !state.due(at: date("2026-11-23T09:00:00Z"), config: weekly).isDue)
        #expect(try state.due(at: date("2026-11-24T09:00:00Z"), config: weekly).isDue)
        try state.consume(date: "2026-11-24", startedAt: "2026-11-24T09:00:00Z")
        #expect(try !state.due(at: date("2026-11-24T09:01:00Z"), config: weekly).isDue)
        #expect(try state.due(at: date("2026-12-01T09:00:00Z"), config: weekly).isDue)
    }

    @Test func automaticRunRequiresOptInAndSharesTheCLIGate() throws {
        let config = temporaryURL()
        let directory = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: directory)
        }
        let now = { date("2026-11-23T20:00:00Z") }
        let platform = FakePlatform([])
        let engine = NativeEngine(configURL: config, stateDirectory: directory, platform: platform)
        let disabled = try engine.execute(.run, apply: true, due: true, requireAutomaticRuns: true, now: now)
        #expect(try JSONDecoder().decode(RunReport.self, from: disabled.data).status == "not_due")
        #expect(platform.events.isEmpty)
        try Data(#"{"automatic_runs":true}"#.utf8).write(to: config)
        let scheduled = try engine.execute(.run, apply: true, due: true, requireAutomaticRuns: true, now: now)
        #expect(try JSONDecoder().decode(RunReport.self, from: scheduled.data).apply)
        let cli = try engine.execute(.run, apply: true, due: true, now: now)
        #expect(try JSONDecoder().decode(RunReport.self, from: cli.data).status == "not_due")
        #expect(platform.events == ["inventory"])
    }

    @Test func lockExcludesOtherRunsAndReportsArePrivate() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = NativeState(directory: directory)
        try state.withLock { () -> Void in
            #expect(throws: EngineFailure("Another Daybreak run is active")) { try state.withLock {} }
        }
        let report = try NativeState.json(["apply": true, "results": []] as [String: Any])
        try state.withLock {
            try state.save(report)
            try state.save(report)
        }
        let latest = directory.appendingPathComponent("latest.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: latest.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try state.status() == report)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("runs").path).count == 2)
    }

    @Test func cliReportsStatusAndRejectsRemovedDryRunFlag() throws {
        let dir = temporaryURL()
        let output = DaybreakCommandLine.run(["--state-dir", dir.path, "status"])
        #expect(output.exitCode == 0)
        #expect(try JSONDecoder().decode(RunReport.self, from: output.stdout).isNeverRun)
        #expect(DaybreakCommandLine.run(["run", "--dry-run"]).exitCode == 2)
        let config = temporaryURL()
        defer { try? FileManager.default.removeItem(at: config) }
        try Data(#"{"hour":99}"#.utf8).write(to: config)
        let invalid = DaybreakCommandLine.run(["inventory", "--config", config.path])
        #expect(invalid.exitCode == 1)
        #expect(try JSONDecoder().decode(EngineErrorPayload.self, from: invalid.stderr).status == "error")
    }

    @Test func readsExistingConfigAndRejectsUnsafeTypes() throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"exclude":["com.old.*"],"whitelist":["com.new.*"],"timezone":"US/Pacific","quit_timeout_seconds":1.5,"apps":{"com.docker.docker":{"allow_workload_interruption":false}}}"#.utf8).write(to: file)
        let config = try EngineConfiguration(url: file)
        #expect(config.whitelisted("com.old.Editor"))
        #expect(config.whitelisted("com.new.Editor"))
        #expect(!config.whitelisted("com.New.Editor"))
        #expect(config.timeZoneID == "US/Pacific")
        #expect(config.quitTimeout == 1.5)
        try Data(#"{"apps":{"com.docker.docker":{"allow_workload_interruption":"false"}}}"#.utf8).write(to: file)
        #expect(throws: EngineFailure("com.docker.docker.allow_workload_interruption must be a boolean")) {
            try EngineConfiguration(url: file)
        }
    }
}

@Suite struct CoordinatorTests {
    @Test func skipsAppsWithoutUpdatersUnlessRestartsAreEnabled() throws {
        let app = sample()
        let platform = FakePlatform([app])
        let coordinator = try makeCoordinator(platform) { _ in UpdateBackend(kind: .restart, process: UpdaterProcess()) }
        let preview = coordinator.handle(app, apply: false)
        let applied = coordinator.handle(app, apply: true)
        #expect(preview.status == .unsupported)
        #expect(applied.status == preview.status)
        #expect(applied.detail == preview.detail)
        #expect(platform.events.isEmpty)
    }

    @Test func defersRefusedQuitBeforeInstallation() throws {
        let app = sample()
        let platform = FakePlatform([app])
        platform.allowsQuit = false
        let commands = OSAllocatedUnfairLock(initialState: [[String]]())
        let runner = UpdaterProcess { argv, _ in
            commands.withLock { $0.append(argv) }
            return processOutput()
        }
        let coordinator = try makeCoordinator(platform) { _ in UpdateBackend(kind: .sparkle, process: runner, executable: "/sparkle") }
        #expect(coordinator.handle(app, apply: true).status == .deferred)
        #expect(platform.events == ["current", "signer", "quit"])
        #expect(commands.withLock { $0.map { $0[2] } } == ["--probe"])
    }

    @Test func sparkleNoUpdateStillVerifies() throws {
        let app = sample()
        let platform = FakePlatform([app])
        let runner = UpdaterProcess { argv, _ in processOutput(code: argv[2] == "--probe" ? 0 : 4) }
        let coordinator = try makeCoordinator(platform) { _ in UpdateBackend(kind: .sparkle, process: runner, executable: "/sparkle") }
        let result = coordinator.handle(app, apply: true)
        #expect(result.status == .checkedAndRelaunched)
        #expect(result.updateOutcome == "no_update")
        #expect(result.newPIDs == [20])
        #expect(platform.events.contains("signature"))
        #expect(platform.events.contains("verify"))
    }

    @Test func uncertainInstallerNeverReopensOrRetries() throws {
        let app = sample()
        let platform = FakePlatform([app])
        let runner = UpdaterProcess { argv, _ in
            if argv[2] == "--probe" { return processOutput() }
            throw UpdaterTimeout(command: "sparkle")
        }
        let coordinator = try makeCoordinator(platform) { _ in UpdateBackend(kind: .sparkle, process: runner, executable: "/sparkle") }
        let result = coordinator.handle(app, apply: true)
        #expect(result.status == .uncertain)
        #expect(!platform.events.contains("relaunch"))
    }

    @Test(arguments: [true, false]) func failedInstallerOnlyReopensWhenSignatureStillMatches(valid: Bool) throws {
        let app = sample()
        let platform = FakePlatform([app])
        platform.signatureValid = valid
        let runner = UpdaterProcess { argv, _ in processOutput(code: argv[2] == "--probe" ? 0 : 1) }
        let coordinator = try makeCoordinator(platform) { _ in UpdateBackend(kind: .sparkle, process: runner, executable: "/sparkle") }
        #expect(coordinator.handle(app, apply: true).status == .failed)
        #expect(platform.events.contains("signature"))
        #expect(platform.events.contains("relaunch") == valid)
    }

    @Test func originalProcessMustStillBeRunning() throws {
        let app = sample()
        let platform = FakePlatform([app])
        platform.running = []
        let coordinator = try makeCoordinator(platform) { _ in UpdateBackend(kind: .sparkle, process: UpdaterProcess()) }
        #expect(coordinator.handle(app, apply: true).status == .skipped)
        #expect(platform.events == ["current"])
    }

    private func makeCoordinator(_ platform: FakePlatform, backend: @escaping (ManagedApp) throws -> UpdateBackend) throws
    -> UpdateCoordinator {
        UpdateCoordinator(platform: platform, config: try EngineConfiguration(url: nil), backend: backend)
    }
}

final class FakePlatform: ApplicationPlatform {
    let apps: [ManagedApp]
    var events: [String] = []
    var running: [AppProcess]
    var inventoryError: EngineFailure?
    var allowsQuit = true
    var signatureValid = true

    init(_ apps: [ManagedApp]) {
        self.apps = apps
        running = apps.flatMap(\.processes)
    }

    func inventory() throws -> [ManagedApp] {
        events.append("inventory")
        if let inventoryError { throw inventoryError }
        return apps
    }

    func current(_ app: ManagedApp) throws -> [AppProcess] {
        events.append("current")
        return running.filter { $0.bundleID == app.bundleID && $0.path == app.path }
    }

    func quit(_ app: ManagedApp) throws -> Bool {
        events.append("quit")
        if allowsQuit { running.removeAll { $0.path == app.path } }
        return allowsQuit
    }

    func relaunch(_ app: ManagedApp) throws { events.append("relaunch") }

    func verify(_ app: ManagedApp, since: Date, target: String) throws -> (BundleMetadata, [Int]) {
        events.append("verify")
        return (app.metadata, [20])
    }

    func signer(_ app: ManagedApp) throws -> String {
        events.append("signer")
        return "TEAM"
    }

    func checkSignature(_ app: ManagedApp, expectedTeam: String) throws {
        events.append("signature")
        if !signatureValid { throw EngineFailure("signature mismatch") }
    }
}

func sample(id: String = "com.example.App", path: String = "/Applications/Sample.app", hints: [String] = []) -> ManagedApp {
    let executable = path + "/Contents/MacOS/Sample"
    return ManagedApp(bundleID: id, name: "Sample", path: path,
                      processes: [AppProcess(bundleID: id, name: "Sample", path: path, pid: 10, launched: 1, executable: executable)],
                      metadata: BundleMetadata(version: "1.0", build: "10", executable: executable, fingerprint: "fixture",
                                               hints: hints, executableSource: "plist"), stale: false)
}

func processOutput(code: Int32 = 0, stdout: String = "", stderr: String = "") -> ProcessOutput {
    ProcessOutput(exitCode: code, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
}

func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("daybreak-tests-\(UUID().uuidString)")
}

func date(_ str: String) -> Date { ISO8601DateFormatter().date(from: str)! }
