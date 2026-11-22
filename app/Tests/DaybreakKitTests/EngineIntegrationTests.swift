import Foundation
import Testing
@testable import DaybreakKit

/// Opt-in read-only checks against the native inventory and engine.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DAYBREAK_INTEGRATION"] == "1"))
struct EngineIntegrationTests {
    func makeClient() -> EngineClient {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("daybreak-it-\(UUID().uuidString).json")
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("daybreak-it-state-\(UUID().uuidString)")
        return EngineClient(configURL: config, stateDirectory: state)
    }

    @Test func inventoryStatusAndDryRun() async throws {
        let client = makeClient()
        let apps = try await client.inventory()
        #expect(!apps.isEmpty)
        let status = try await client.status()
        #expect(status.isNeverRun)
        let outcome = try await client.run(apply: false)
        #expect(!outcome.report.apply)
        #expect(outcome.report.results.allSatisfy { [.planned, .excluded, .blocked, .unsupported].contains($0.status) })
    }

    @Test func invalidConfigSurfacesEngineDetail() async throws {
        let client = makeClient()
        defer { try? FileManager.default.removeItem(at: client.configURL) }
        try Data(#"{"hour": 99}"#.utf8).write(to: client.configURL)
        await #expect(throws: EngineError.failed(detail: "hour must be an integer from 0 through 23")) {
            _ = try await client.inventory()
        }
    }
}
