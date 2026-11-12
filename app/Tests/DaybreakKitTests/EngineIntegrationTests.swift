import Foundation
import Testing
@testable import DaybreakKit

/// Opt-in, read-only end-to-end checks against the real engine in this checkout:
/// `DAYBREAK_INTEGRATION=1 swift test`. Requires ../scripts/build.sh to have been run.
/// Only `inventory`, `status` and `run --dry-run` are invoked; never `--apply`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DAYBREAK_INTEGRATION"] == "1"))
struct EngineIntegrationTests {
    static var checkout: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func makeClient() async throws -> EngineClient {
        let python = try await PythonLocator.locate(override: nil).get()
        let engine = try EngineLocator.locate(bundleResources: nil, checkoutPath: Self.checkout.path, executable: nil).get()
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("daybreak-it-\(UUID().uuidString).json")
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("daybreak-it-state-\(UUID().uuidString)")
        return EngineClient(python: python, engine: engine, configURL: config, stateDirectory: state)
    }

    @Test func inventoryStatusAndDryRun() async throws {
        let client = try await makeClient()
        let apps = try await client.inventory()
        #expect(!apps.isEmpty)
        let status = try await client.status()
        #expect(status.isNeverRun)
        let outcome = try await client.run(apply: false)
        #expect(!outcome.report.apply)
        #expect(outcome.report.results.allSatisfy { [.planned, .excluded, .blocked].contains($0.status) })
    }

    @Test func invalidConfigSurfacesEngineDetail() async throws {
        let client = try await makeClient()
        try Data(#"{"hour": 99}"#.utf8).write(to: client.configURL)
        await #expect(throws: EngineError.failed(detail: "hour must be an integer from 0 through 23")) {
            _ = try await client.inventory()
        }
    }
}
