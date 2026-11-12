import Foundation
import Testing
@testable import DaybreakKit

@Suite struct EngineDecodingTests {
    @Test func inventoryFromOlderEngineDefaultsFlags() throws {
        let json = """
        [{"bundle_id": "com.example.A", "name": "A", "path": "/Applications/A.app", "version": "1.0",
          "build": "100", "pids": [42], "launches": [1.5], "executable": "/Applications/A.app/Contents/MacOS/A",
          "fingerprint": "abc", "hints": ["sparkle"], "stale": false, "executable_source": "plist"}]
        """
        let apps = try JSONDecoder().decode([InventoryApp].self, from: Data(json.utf8))
        let app = try #require(apps.first)
        #expect(app.engineWhitelisted == nil)
        #expect(app.engineProtected == nil)
        #expect(app.isProtected == false)
        #expect(app.isWhitelisted(by: []) == false)
        #expect(app.isWhitelisted(by: ["com.example.*"]))
        #expect(app.versionDescription == "1.0 (100)")
        #expect(app.pids == [42])
    }

    @Test func inventoryWithWhitelistFields() throws {
        let json = """
        [{"bundle_id": "com.openai.chat", "whitelisted": false, "protected": true},
         {"bundle_id": "com.example.B", "name": "B", "whitelisted": true, "protected": false, "extra": {"x": 1}}]
        """
        let apps = try JSONDecoder().decode([InventoryApp].self, from: Data(json.utf8))
        #expect(apps[0].isProtected)
        #expect(apps[0].name == "com.openai.chat")
        #expect(apps[1].isWhitelisted(by: []))
    }

    @Test func localProtectedRuleMatchesEngine() {
        #expect(InventoryApp(bundleID: "com.example.Helper", name: "H", path: "/Applications/X.app/Contents/Helpers/H.app").isProtected)
        #expect(InventoryApp(bundleID: "com.apple.Safari", name: "S", path: "/System/Applications/Safari.app").isProtected)
        #expect(InventoryApp(bundleID: "io.tailscale.ipn.macsys", name: "T", path: "/Applications/Tailscale.app").isProtected)
        #expect(!InventoryApp(bundleID: "com.example.A", name: "A", path: "/Applications/A.app").isProtected)
    }

    @Test func runReportDecodesAllStatusesAndUnknowns() throws {
        let statuses = ResultStatus.known.map(\.rawValue) + ["brand_new_status"]
        let results = statuses.map { #"{"bundle_id": "com.example.\#($0)", "name": "\#($0)", "status": "\#($0)"}"# }
        let json = #"{"started_at": "2026-11-11T16:00:00.123456+00:00", "apply": true, "timezone": "America/Los_Angeles", "results": ["#
            + results.joined(separator: ",") + #", 42, {"bundle_id": "com.example.full", "status": "updated_and_relaunched", "before": "1.0", "after": "1.1", "before_build": "10", "after_build": "11", "old_pids": [1], "new_pids": [2], "detail": "ok"}]}"#
        let report = try JSONDecoder().decode(RunReport.self, from: Data(json.utf8))
        #expect(report.apply)
        #expect(report.results.count == statuses.count + 1)  // the bare `42` is skipped
        #expect(Set(report.results.map(\.id)).count == report.results.count)
        let unknown = try #require(report.results.first { $0.status.rawValue == "brand_new_status" })
        #expect(!unknown.status.isKnown)
        #expect(unknown.status.tone == .neutral)
        #expect(unknown.status.title == "Brand New Status")
        let full = try #require(report.results.last)
        #expect(full.versionChange == "1.0 (10) → 1.1 (11)")
        #expect(full.newPIDs == [2])
        let date = try #require(report.startedDate)
        #expect(abs(date.timeIntervalSince1970 - 1_794_412_800.123456) < 0.001)
        #expect(report.attentionCount == 6)
    }

    @Test func neverRunStatus() throws {
        let report = try JSONDecoder().decode(RunReport.self, from: Data(#"{"status": "never_run"}"#.utf8))
        #expect(report.isNeverRun)
        #expect(report.results.isEmpty)
    }

    @Test func exitCodeMapping() throws {
        let ok = ProcessOutput(exitCode: 2, stdout: Data("[]".utf8), stderr: Data())
        #expect(try EngineClient.checked(ok, allowAttention: true) == Data("[]".utf8))
        #expect(throws: EngineError.self) { try EngineClient.checked(ok, allowAttention: false) }

        let failure = ProcessOutput(exitCode: 1, stdout: Data(), stderr: Data(#"{"status": "error", "detail": "hour must be an integer from 0 through 23"}"#.utf8))
        #expect(throws: EngineError.failed(detail: "hour must be an integer from 0 through 23")) {
            try EngineClient.checked(failure, allowAttention: true)
        }
        let traceback = ProcessOutput(exitCode: 1, stdout: Data(), stderr: Data("Traceback...\n".utf8))
        #expect(throws: EngineError.failed(detail: "Traceback...")) { try EngineClient.checked(traceback, allowAttention: true) }
    }

    @Test func pythonVersionCheck() {
        #expect(PythonLocator.isSupported("3.11.0"))
        #expect(PythonLocator.isSupported("3.15.2\n"))
        #expect(PythonLocator.isSupported("4.0.0"))
        #expect(!PythonLocator.isSupported("3.9.6"))
        #expect(!PythonLocator.isSupported("garbage"))
    }

    @Test func engineLocatorPrefersBundle() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("daybreak-locate-\(UUID().uuidString)")
        let bundle = base.appendingPathComponent("Resources")
        let checkout = base.appendingPathComponent("checkout")
        for root in [bundle, checkout] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("daybreak"), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("daybreak/__main__.py"))
        }
        let fromBundle = try EngineLocator.locate(bundleResources: bundle, checkoutPath: checkout.path, executable: nil).get()
        #expect(fromBundle.source == .bundle)
        #expect(fromBundle.bridge.lastPathComponent == "appbridge")
        let fromCheckout = try EngineLocator.locate(bundleResources: base, checkoutPath: checkout.path, executable: nil).get()
        #expect(fromCheckout.source == .checkout)
        #expect(fromCheckout.bridge.path.hasSuffix(".build/appbridge"))
        if case .success = EngineLocator.locate(bundleResources: base, checkoutPath: nil, executable: nil) {
            Issue.record("expected failure")
        }
    }

    @Test func argumentsUseFlagsNotShellAndAlwaysPassStateDir() {
        let client = EngineClient(
            python: PythonInterpreter(url: URL(fileURLWithPath: "/usr/bin/python3"), version: "3.12.0"),
            engine: EngineLocation(root: URL(fileURLWithPath: "/tmp/engine"), bridge: URL(fileURLWithPath: "/tmp/engine/appbridge"), source: .bundle),
            configURL: URL(fileURLWithPath: "/tmp/my config.json"),
            stateDirectory: URL(fileURLWithPath: "/tmp/state dir"))
        let args = client.arguments(for: "run", extra: ["--dry-run"])
        #expect(args == ["-B", "-m", "daybreak", "run", "--bridge", "/tmp/engine/appbridge",
                         "--config", "/tmp/my config.json", "--state-dir", "/tmp/state dir", "--dry-run"])
        for command in ["inventory", "run", "status"] {
            let arguments = client.arguments(for: command)
            let index = arguments.firstIndex(of: "--state-dir")
            #expect(index.map { arguments[$0 + 1] } == "/tmp/state dir")
        }
        #expect(!client.arguments(for: "status").contains("--config"))
    }

    @Test func defaultStateDirectoryMatchesEngineDefault() {
        let client = EngineClient(
            python: PythonInterpreter(url: URL(fileURLWithPath: "/usr/bin/python3"), version: "3.12.0"),
            engine: EngineLocation(root: URL(fileURLWithPath: "/e"), bridge: URL(fileURLWithPath: "/e/appbridge"), source: .bundle),
            configURL: URL(fileURLWithPath: "/c.json"))
        #expect(client.stateDirectory.path.hasSuffix("Library/Application Support/Daybreak"))
        #expect(HistoryStore.resolveStateDirectory(preference: "  ") == HistoryStore.defaultStateDirectory)
        #expect(HistoryStore.resolveStateDirectory(preference: nil) == HistoryStore.defaultStateDirectory)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(HistoryStore.resolveStateDirectory(preference: "~/Reports/../State").path == home + "/State")
    }

    @Test func historyReadsRunsFromGivenDirectoryNewestFirst() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("daybreak-history-\(UUID().uuidString)")
        let runs = state.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        try Data(#"{"apply": true, "results": []}"#.utf8).write(to: runs.appendingPathComponent("20261110T080000-1.json"))
        try Data(#"{"apply": true, "started_at": "2026-11-11T16:00:00+00:00", "results": []}"#.utf8)
            .write(to: runs.appendingPathComponent("20261111T080000-2.json"))
        try Data("not json".utf8).write(to: runs.appendingPathComponent("20261109T080000-3.json"))
        try Data().write(to: runs.appendingPathComponent("notes.txt"))
        let stored = HistoryStore.runs(in: state)
        #expect(stored.map(\.url.lastPathComponent) == ["20261111T080000-2.json", "20261110T080000-1.json", "20261109T080000-3.json"])
        #expect(stored[2].report == nil && stored[2].error != nil)
        #expect(stored[1].date != nil)  // from the file name
        #expect(HistoryStore.runs(in: state.appendingPathComponent("missing")).isEmpty)
    }
}
