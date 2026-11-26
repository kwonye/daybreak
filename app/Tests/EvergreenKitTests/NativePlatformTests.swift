import Darwin
import Foundation
import os
import Testing
@testable import EvergreenKit

@Suite struct NativePlatformTests {
    @Test func appIdentityResolvesAliasesAndKeepsSeparateCopies() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Original.app")
        let copy = directory.appendingPathComponent("Copy.app")
        let alias = directory.appendingPathComponent("Alias.app")
        let files = FileManager.default
        try files.createDirectory(at: original, withIntermediateDirectories: true)
        try files.createDirectory(at: copy, withIntermediateDirectories: false)
        try files.createSymbolicLink(at: alias, withDestinationURL: original)
        let id = "com.example.app"
        #expect(ApplicationIdentity(bundleID: id, path: alias.path) == ApplicationIdentity(bundleID: id, path: original.path))
        #expect(ApplicationIdentity(bundleID: id, path: copy.path) != ApplicationIdentity(bundleID: id, path: original.path))
        #expect(ApplicationIdentity(bundleID: "com.example.setup", path: original.path) != ApplicationIdentity(bundleID: id, path: original.path))
    }

    @Test func signedClosedAppCanResolveMainExecutableWithoutPlistKey() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Fixture.app")
        let macOS = root.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let main = macOS.appendingPathComponent("Fixture")
        let helper = macOS.appendingPathComponent("Helper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: main)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/false"), to: helper)
        let properties = ["CFBundleIdentifier": "co.kwon.evergreen.signedfixture",
                          "CFBundlePackageType": "APPL", "CFBundleVersion": "10"]
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        _ = try UpdaterProcess().checked(["/usr/bin/codesign", "--force", "--sign", "-", root.path], 20)

        let metadata = try BundleMetadata.read(root.path, observed: [])
        #expect(metadata.executable == canonicalPath(main.path))
        #expect(metadata.executableSource == "code-signature")
        #expect(metadata.fingerprint.count == 64)
    }

    @Test func finderFolderPositionsDoNotMaskInvalidSignatures() throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("FinderFixture.app")
        let executable = root.appendingPathComponent("Contents/MacOS/FinderFixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
        let app = sample(path: root.path)
        let plist = root.appendingPathComponent("Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": app.bundleID, "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "FinderFixture", "CFBundleVersion": "1",
        ], format: .xml, options: 0).write(to: plist)

        let system = UpdaterProcess()
        _ = try system.checked(["/usr/bin/codesign", "--force", "--sign", "-", root.path], 20)
        let finderInfo = "com.apple.FinderInfo"
        var metadata = [UInt8](repeating: 0, count: 32)
        metadata.replaceSubrange(10..<14, with: [0xFF, 0xFF, 0xFF, 0xFF])
        let nested = executable.deletingLastPathComponent()
        for path in [root.path, nested.path] {
            let written = metadata.withUnsafeBytes { bytes in
                setxattr(path, finderInfo, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
            }
            try #require(written == 0)
        }
        let runner = UpdaterProcess { arguments, timeout in
            // The fixture is ad-hoc signed. Check its real signature, then
            // simulate a vendor Team ID without depending on a local certificate.
            if arguments.contains("-dv") { return processOutput(stderr: "TeamIdentifier=TESTTEAM") }
            return try system.run(arguments, timeout)
        }
        let platform = MacApplications(process: runner, quitTimeout: 1)
        #expect(try platform.signer(app) == "TESTTEAM")
        #expect(getxattr(root.path, finderInfo, nil, 0, 0, XATTR_NOFOLLOW) == 32)
        #expect(getxattr(nested.path, finderInfo, nil, 0, 0, XATTR_NOFOLLOW) == 32)
        #expect(throws: EngineFailure.self) { try platform.checkSignature(app, expectedTeam: "DIFFERENT") }

        try Data("tampered".utf8).write(to: plist)
        #expect(throws: EngineFailure.self) { try platform.signer(app) }
    }

    @Test func sparkleRequestsAuthorizationOnlyForInteractiveInstalls() throws {
        let app = sample()
        let commands = OSAllocatedUnfairLock(initialState: [[String]]())
        let runner = UpdaterProcess { args, _ in
            commands.withLock { $0.append(args) }
            return processOutput(code: args.contains("--interactive") ? 0 : 3)
        }
        var backend = UpdateBackend(kind: .sparkle, process: runner, executable: "/sparkle")
        #expect(throws: EngineFailure.self) { try backend.apply(app) }
        backend.interactiveInstallation = true
        #expect(try backend.apply(app)?.outcome == "completed")
        #expect(commands.withLock { $0.map { $0.contains("--interactive") } } == [false, true])

        backend = UpdateBackend(kind: .sparkle, process: UpdaterProcess { _, _ in processOutput(code: 5) },
                                executable: "/sparkle", interactiveInstallation: true)
        #expect(throws: CancellationError.self) { try backend.apply(app) }
        backend = UpdateBackend(kind: .sparkle, process: UpdaterProcess { _, _ in processOutput(code: 8) },
                                executable: "/sparkle", interactiveInstallation: true)
        #expect(throws: UpdateRequiresApp.self) { try backend.apply(app) }
    }

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
        let commands = OSAllocatedUnfairLock(initialState: [[String]]())
        let runner = UpdaterProcess { args, _ in
            commands.withLock { $0.append(args) }
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
        #expect(commands.withLock { $0 } == [
            ["/brew", "outdated", "--cask", "--json=v2", "sample"],
            ["/brew", "upgrade", "--cask", "sample"],
            ["/mas", "outdated"], ["/mas", "update", "123"],
            ["/docker", "desktop", "update", "--quiet"],
        ])
    }

    @Test func commandAdapterExpandsLiteralArgumentsAndRequiresTarget() throws {
        let app = sample(path: "/Applications/A space; no shell.app")
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let runner = UpdaterProcess { args, _ in
            seen.withLock { $0 = args }
            return processOutput(stdout: #"{"state":"available"}"#)
        }
        let backend = UpdateBackend(kind: .command, process: runner,
                                    checkArguments: ["/adapter", "{app_path}", "ID:{bundle_id}"])
        #expect(throws: EngineFailure("Available adapter update must include target_version")) { try backend.check(app) }
        #expect(seen.withLock { $0 } == ["/adapter", app.path, "ID:\(app.bundleID)"])
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
    @Test func onlyRestartsDisposableFixture() async throws {
        let directory = temporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let path = try #require(canonicalPath(directory.path))
        let workspace = URL(fileURLWithPath: path, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bundle = workspace.appendingPathComponent("EvergreenSmoke.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/EvergreenSmoke")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = workspace.appendingPathComponent("Fixture.swift")
        let bundleID = "dev.evergreen.Smoke.\(UUID().uuidString)"
        let info = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "EvergreenSmoke", "CFBundleName": "Evergreen Smoke",
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
            try await Task.sleep(for: .milliseconds(200))
        }
        let originalPIDs = try mac.current(candidate).map(\.pid)
        try #require(!originalPIDs.isEmpty)
        let state = workspace.appendingPathComponent("state")
        let config = workspace.appendingPathComponent("config.json")
        try Data(#"{"apps":{},"restart_unmanaged":true}"#.utf8).write(to: config)
        let result = try await runFixture(bundleID: bundleID, state: state, config: config, runner: runner)
        #expect(result.status == .restartOnlyUnverified)
        #expect(result.before == "1.2.3" && result.after == "1.2.3")
        #expect(result.oldPIDs == originalPIDs)
        #expect(!result.newPIDs.isEmpty && Set(result.oldPIDs).isDisjoint(with: result.newPIDs))
        #expect(try mac.quit(candidate))
    }

    private func runFixture(bundleID: String, state: URL, config: URL, runner: UpdaterProcess) async throws -> RunResult {
        let arguments = ["run", "--apply", "--only", bundleID, "--config", config.path, "--state-dir", state.path]
        let data: Data
        if let cli = ProcessInfo.processInfo.environment["DAYBREAK_SMOKE_CLI"] {
            let output = try runner.run([cli] + arguments, 90)
            #expect(output.exitCode == 2)
            data = output.stdout
        } else {
            let output = await EvergreenCommandLine.run(arguments)
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
