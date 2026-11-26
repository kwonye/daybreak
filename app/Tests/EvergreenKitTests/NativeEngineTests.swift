import Foundation
import os
import Testing
@testable import EvergreenKit

@Suite struct NativeEngineTests {
    @Test func previewOnlyUsesInventoryAndPreservesState() async throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let platform = FakePlatform([sample(), sample(id: "com.docker.docker"),
                                     sample(id: "co.kwon.evergreen"), sample(id: "co.kwon.daybreak"),
                                     sample(id: "com.example.skip")])
        let runner = UpdaterProcess { _, _ in Issue.record("Preview invoked a program"); throw EngineFailure("unexpected") }
        let engine = NativeEngine(configURL: nil, stateDirectory: directory, process: runner, platform: platform)
        let output = try await engine.execute(.run, due: true, skip: ["com.example.skip"]) {
            date("2026-11-20T20:00:00Z")
        }
        let report = try JSONDecoder().decode(RunReport.self, from: output.data)
        #expect(platform.events == ["inventory"])
        #expect(output.exitCode == 2)
        #expect(report.results.map(\.status) == [.unsupported, .blocked, .excluded, .excluded, .excluded])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await #expect(throws: EngineFailure.self) { try await engine.execute(.run, skip: [""]) }
    }

    @Test func applyOnlyTargetsConfirmedRunningInstances() async throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = temporaryURL()
        defer { try? FileManager.default.removeItem(at: config) }
        try Data(#"{"restart_unmanaged":true}"#.utf8).write(to: config)
        let first = sample()
        let duplicate = sample(id: first.bundleID, path: "/Applications/Duplicate.app")
        let platform = FakePlatform([first, duplicate])
        let engine = NativeEngine(configURL: config, stateDirectory: directory, platform: platform)
        let preview = try JSONDecoder().decode(RunReport.self, from: await engine.execute(.run).data)
        let selected = try #require(preview.results.first)
        #expect(selected.path == first.path)
        let result = try await engine.execute(.run, apply: true, confirmed: [selected])
        let applied = try JSONDecoder().decode(RunReport.self, from: result.data)
        #expect(applied.results.map(\.path) == [first.path])
        #expect(applied.results.map(\.status) == [.restartOnlyUnverified])

        let changed = AppProcess(bundleID: first.bundleID, name: first.name, path: first.path,
                                 pid: first.pids[0], launched: 2, executable: first.metadata.executable)
        let replaced = ManagedApp(bundleID: first.bundleID, name: first.name, path: first.path,
                                  processes: [changed], metadata: first.metadata, stale: false)
        let changedPlatform = FakePlatform([replaced, duplicate])
        let changedEngine = NativeEngine(configURL: config, stateDirectory: directory, platform: changedPlatform)
        let skipped = try await changedEngine.execute(.run, apply: true, confirmed: [selected])
        let skippedReport = try JSONDecoder().decode(RunReport.self, from: skipped.data)
        #expect(skippedReport.results.map(\.status) == [.skipped])
        #expect(changedPlatform.events == ["inventory"])
    }

    @Test func dueRunConsumesDateBeforeInventoryFailure() async throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let platform = FakePlatform([])
        platform.inventoryError = EngineFailure("cannot access inventory")
        let engine = NativeEngine(configURL: nil, stateDirectory: directory, platform: platform)
        let now = { date("2026-11-20T20:00:00Z") }
        await #expect(throws: EngineFailure("cannot access inventory")) {
            try await engine.execute(.run, apply: true, due: true, now: now)
        }
        let result = try await engine.execute(.run, apply: true, due: true, now: now)
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

    @Test func automaticRunRequiresOptInAndSharesTheCLIGate() async throws {
        let config = temporaryURL()
        let directory = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: directory)
        }
        let now = { date("2026-11-23T20:00:00Z") }
        let platform = FakePlatform([])
        let engine = NativeEngine(configURL: config, stateDirectory: directory, platform: platform)
        let disabled = try await engine.execute(.run, apply: true, due: true, requireAutomaticRuns: true, now: now)
        #expect(try JSONDecoder().decode(RunReport.self, from: disabled.data).status == "not_due")
        #expect(platform.events.isEmpty)
        try Data(#"{"automatic_runs":true}"#.utf8).write(to: config)
        let scheduled = try await engine.execute(.run, apply: true, due: true, requireAutomaticRuns: true, now: now)
        #expect(try JSONDecoder().decode(RunReport.self, from: scheduled.data).apply)
        let cli = try await engine.execute(.run, apply: true, due: true, now: now)
        #expect(try JSONDecoder().decode(RunReport.self, from: cli.data).status == "not_due")
        #expect(platform.events == ["inventory"])
    }

    @Test(arguments: ScheduleScope.allCases)
    func missedMorningRunCatchesUpOnceWithTheSelectedScope(scope: ScheduleScope) async throws {
        let root = temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let brew = root.appendingPathComponent("brew")
        try Data().write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew.path)
        let config = root.appendingPathComponent("config.json")
        try Data(#"{"automatic_runs":true,"hour":8,"timezone":"UTC","schedule_scope":"\#(scope.rawValue)"}"#.utf8)
            .write(to: config)
        let state = root.appendingPathComponent("state")
        let version = OSAllocatedUnfairLock(initialState: "1.0")
        let upgrades = OSAllocatedUnfairLock(initialState: 0)
        let runner = UpdaterProcess(searchPath: root.path) { args, _ in
            let output: String
            switch args {
            case [brew.path, "--caskroom"]:
                output = root.appendingPathComponent("Caskroom").path
            case [brew.path, "info", "--json=v2", "--installed"]:
                let active = version.withLock { $0 }
                output = #"{"formulae":[{"name":"example","installed":[{"version":"\#(active)"}]}],"casks":[]}"#
            case [brew.path, "outdated", "--json=v2"]:
                output = #"{"formulae":[{"name":"example","current_version":"2.0"}],"casks":[]}"#
            case ["/usr/bin/env", "HOMEBREW_NO_ASK=1", "HOMEBREW_NO_AUTO_UPDATE=1", brew.path, "upgrade", "--formula", "example"]:
                upgrades.withLock { $0 += 1 }
                version.withLock { $0 = "2.0" }
                output = ""
            default: throw EngineFailure("Unexpected command.")
            }
            return ProcessOutput(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
        }
        let app = sample()
        let platform = FakePlatform([app])
        let engine = NativeEngine(configURL: config, stateDirectory: state, process: runner, platform: platform)
        let early = try await engine.execute(.run, apply: true, due: true, now: { date("2026-11-26T07:59:00Z") })
        #expect(try JSONDecoder().decode(RunReport.self, from: early.data).status == "not_due")
        let catchUp = try await engine.execute(.run, apply: true, due: true, requireAutomaticRuns: true,
                                         now: { date("2026-11-26T09:00:00Z") })
        let results = try JSONDecoder().decode(RunReport.self, from: catchUp.data).results
        #expect(results.contains { $0.bundleID == app.bundleID } == (scope != .brew))
        #expect(results.contains { $0.bundleID == "brew:formula:example" && $0.status == .updated } == (scope != .apps))
        let later = try await engine.execute(.run, apply: true, due: true, now: { date("2026-11-26T09:30:00Z") })
        #expect(try JSONDecoder().decode(RunReport.self, from: later.data).status == "not_due")
        #expect(upgrades.withLock { $0 } == (scope == .apps ? 0 : 1))
    }

    @Test func lockExcludesOtherRunsAndReportsArePrivate() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = NativeState(directory: directory)
        try state.withLock { () -> Void in
            #expect(throws: EngineFailure("Another Evergreen run is active")) { try state.withLock {} }
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

    @Test func cliReportsStatusAndRejectsRemovedDryRunFlag() async throws {
        let dir = temporaryURL()
        let output = await EvergreenCommandLine.run(["--state-dir", dir.path, "status"])
        #expect(output.exitCode == 0)
        #expect(try JSONDecoder().decode(RunReport.self, from: output.stdout).isNeverRun)
        #expect(await EvergreenCommandLine.run(["run", "--dry-run"]).exitCode == 2)
        let config = temporaryURL()
        defer { try? FileManager.default.removeItem(at: config) }
        try Data(#"{"hour":99}"#.utf8).write(to: config)
        let invalid = await EvergreenCommandLine.run(["inventory", "--config", config.path])
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
    FileManager.default.temporaryDirectory.appendingPathComponent("evergreen-tests-\(UUID().uuidString)")
}

func date(_ str: String) -> Date { ISO8601DateFormatter().date(from: str)! }
