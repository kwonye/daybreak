import Foundation
import Testing
@testable import DaybreakKit

@Suite struct NativePlatformTests {
    @Test func observedExecutableMustBeUniqueAndWithinBundle() throws {
        let root = temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let first = macOS.appendingPathComponent("Main")
        let second = macOS.appendingPathComponent("Helper")
        for executable in [first, second] {
            try Data("fixture".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let info = root.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "10"], format: .xml, options: 0).write(to: info)
        #expect(try BundleMetadata.read(root.path, observed: []).executable.isEmpty)
        #expect(try BundleMetadata.read(root.path, observed: [first.path, second.path]).executable.isEmpty)
        let fallback = try BundleMetadata.read(root.path, observed: [first.path, first.path])
        #expect(fallback.executable == canonicalPath(first.path))
        #expect(fallback.executableSource == "running-process")
        #expect(fallback.fingerprint.count == 64)
        let link = macOS.appendingPathComponent("Escaped")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/true")
        #expect(try BundleMetadata.read(root.path, observed: [link.path]).executable.isEmpty)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Escaped"], format: .xml, options: 0)
            .write(to: info)
        #expect(try BundleMetadata.read(root.path, observed: [first.path]).executable.isEmpty)
    }

    @Test func installerCommandsStayScoped() throws {
        let app = sample()
        var commands: [[String]] = []
        let runner = UpdaterProcess { args, _ in
            commands.append(args)
            if args[1] == "outdated", args[0] == "/brew" {
                return processOutput(stdout: #"{"casks":[{"name":"sample"}]}"#)
            }
            if args[1] == "outdated" { return processOutput(stdout: "1234 Other (2)\n123 Sample (2)") }
            return processOutput()
        }
        let brew = UpdateBackend(kind: .homebrew, process: runner, executable: "/brew", identifier: "sample")
        let mas = UpdateBackend(kind: .appStore, process: runner, executable: "/mas", identifier: "123")
        let docker = UpdateBackend(kind: .docker, process: runner, executable: "/docker")
        #expect(try brew.check(app).state == .available)
        _ = try brew.apply(app)
        #expect(try mas.check(app).state == .available)
        _ = try mas.apply(app)
        _ = try docker.apply(app)
        #expect(commands == [
            ["/brew", "outdated", "--cask", "--json=v2", "sample"],
            ["/brew", "upgrade", "--cask", "sample"],
            ["/mas", "outdated"], ["/mas", "update", "123"],
            ["/docker", "desktop", "update", "--quiet"],
        ])
    }

    @Test func commandAdapterExpandsLiteralArgumentsAndRequiresTarget() throws {
        let app = sample(path: "/Applications/A space; no shell.app")
        var seen: [String] = []
        let runner = UpdaterProcess { args, _ in
            seen = args
            return processOutput(stdout: #"{"state":"available"}"#)
        }
        let backend = UpdateBackend(kind: .command, process: runner,
                                    checkArguments: ["/adapter", "{app_path}", "ID:{bundle_id}"])
        #expect(throws: EngineFailure("Available adapter update must include target_version")) { try backend.check(app) }
        #expect(seen == ["/adapter", app.path, "ID:\(app.bundleID)"])
    }

    @Test func verificationRequiresFreshPrimaryAndNoOriginalPIDs() throws {
        let root = temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Contents/MacOS/Sample")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleExecutable": "Sample", "CFBundleVersion": "16",
        ], format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
        let app = sample(path: root.path)
        let started = Date(timeIntervalSince1970: 100)
        let metadata = try BundleMetadata.read(root.path, observed: [])
        let auxiliary = AppProcess(bundleID: app.bundleID, name: "helper", path: app.path,
                                   pid: 15, launched: 0, executable: "/usr/bin/true")
        let primary = AppProcess(bundleID: app.bundleID, name: app.name, path: app.path,
                                 pid: 20, launched: 100, executable: executable.path)
        let original = AppProcess(bundleID: app.bundleID, name: "original", path: app.path,
                                  pid: 10, launched: 1, executable: executable.path)
        func verify(_ rows: [AppProcess], target: String = "16") -> [Int]? {
            MacApplications.verifiedPIDs(rows, metadata: metadata, original: [10], since: started, target: target)
        }
        #expect(verify([auxiliary, primary]) == [20])
        #expect(verify([auxiliary]) == nil)
        #expect(verify([original, primary]) == nil)
        #expect(verify([primary], target: "17") == nil)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["DAYBREAK_NATIVE_SMOKE"] == "1"))
struct NativeLifecycleSmoke {
    @Test func onlyRestartsDisposableFixture() throws {
        let directory = temporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let path = try #require(canonicalPath(directory.path))
        let workspace = URL(fileURLWithPath: path, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundle = workspace.appendingPathComponent("DaybreakSmoke.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/DaybreakSmoke")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = workspace.appendingPathComponent("Fixture.swift")
        let bundleID = "dev.daybreak.Smoke.\(UUID().uuidString)"
        let info = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "DaybreakSmoke", "CFBundleName": "Daybreak Smoke",
                    "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "123", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try """
            import AppKit
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.run()
            """.write(to: source, atomically: true, encoding: .utf8)
        let runner = UpdaterProcess()
        _ = try runner.checked(["/usr/bin/xcrun", "swiftc", source.path, "-o", executable.path], 180)
        let mac = MacApplications(process: runner, quitTimeout: 15, launchTimeout: 15)
        let candidate = sample(id: bundleID, path: bundle.path)
        // Every operation is scoped to the unique temporary bundle and bundle ID.
        defer { _ = try? mac.quit(candidate) }
        try mac.relaunch(candidate)
        let deadline = DispatchTime.now() + 15
        while try mac.current(candidate).isEmpty, DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let originalPIDs = try mac.current(candidate).map(\.pid)
        try #require(!originalPIDs.isEmpty)
        let state = workspace.appendingPathComponent("state")
        let config = workspace.appendingPathComponent("config.json")
        try Data(#"{"apps":{},"restart_unmanaged":true}"#.utf8).write(to: config)
        let result = try runFixture(bundleID: bundleID, state: state, config: config, runner: runner)
        #expect(result.status == .restartOnlyUnverified)
        #expect(result.before == "1.2.3" && result.after == "1.2.3")
        #expect(result.oldPIDs == originalPIDs)
        #expect(!result.newPIDs.isEmpty && Set(result.oldPIDs).isDisjoint(with: result.newPIDs))
        #expect(try mac.quit(candidate))
    }

    private func runFixture(bundleID: String, state: URL, config: URL, runner: UpdaterProcess) throws -> RunResult {
        let arguments = ["run", "--apply", "--only", bundleID, "--config", config.path, "--state-dir", state.path]
        let data: Data
        if let cli = ProcessInfo.processInfo.environment["DAYBREAK_SMOKE_CLI"] {
            let output = try runner.run([cli] + arguments, 90)
            #expect(output.exitCode == 2)
            data = output.stdout
        } else {
            let output = DaybreakCommandLine.run(arguments)
            #expect(output.exitCode == 2)
            data = output.stdout
        }
        let report = try JSONDecoder().decode(RunReport.self, from: data)
        #expect(report.apply)
        #expect(report.results.count == 1)
        let result = try #require(report.results.first)
        #expect(result.bundleID == bundleID)
        return result
    }
}
