import Foundation
import Testing
@testable import EvergreenKit

@Suite struct ScheduleMonitorTests {
    @Test func missedRunOnlyNotifiesWhenUpdatesCanRun() async throws {
        let root = temporaryURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.json")
        try Data(#"{"automatic_runs":true,"hour":8,"minute":0,"timezone":"UTC","schedule_scope":"apps"}"#.utf8)
            .write(to: configURL)
        try FileManager.default.setAttributes([.modificationDate: date("2026-11-25T08:00:00Z")], ofItemAtPath: configURL.path)
        let stateURL = root.appendingPathComponent("state")
        let client = EngineClient(configURL: configURL, stateDirectory: stateURL)
        let empty = try await client.serviceSchedule(clock: { date("2026-11-26T09:00:00Z") }) { scope in
            #expect(scope == .apps)
            return 0
        }
        #expect(empty.reminder == nil)
        #expect(!empty.shouldNotify)

        let found = try await client.serviceSchedule(clock: { date("2026-11-26T09:16:00Z") }) { _ in 2 }
        let slot = date("2026-11-26T08:00:00Z")
        #expect(found.reminder?.scheduledAt == slot)
        #expect(found.reminder?.updateCount == 2)
        #expect(found.shouldNotify)
        #expect(found.outcome == nil)

        let nextCheck = try await client.serviceSchedule(clock: { date("2026-11-26T09:17:00Z") }) { _ in
            Issue.record("A recent reminder should reuse its pending-update check")
            return 0
        }
        #expect(nextCheck.reminder == found.reminder)
        #expect(!nextCheck.shouldNotify)
        let stillPending = try await client.serviceSchedule(clock: { date("2026-11-26T09:32:00Z") }) { _ in 1 }
        #expect(stillPending.reminder?.updateCount == 1)
        #expect(!stillPending.shouldNotify)

        let state = NativeState(directory: stateURL)
        let config = try EngineConfiguration(url: configURL)
        #expect(try state.latestScheduleSlot(at: date("2026-11-27T01:00:00Z"), config: config) == slot)
        try state.consume(date: "2026-11-26", startedAt: "2026-11-26T09:40:00Z")
        let handled = try await client.serviceSchedule(clock: { date("2026-11-27T01:00:00Z") }) { _ in
            Issue.record("A consumed schedule should not check for pending updates")
            return 1
        }
        #expect(handled.reminder == nil)
        #expect(!handled.shouldNotify)
    }
}

@Test func macStorefrontUsesOnlyMatchingMacProduct() {
    let html = """
        <script type="application/json" id="serialized-server-data">{"data":[
          {"intent":{"id":"1358823008","platform":"iphone"},"data":{"shelfMapping":{"mostRecentVersion":{"items":[{"primarySubtitle":"Version 5.0"}]}}}},
          {"intent":{"id":"1358823008","platform":"mac"},"data":{"shelfMapping":{"mostRecentVersion":{"items":[{"primarySubtitle":"Version 4.12.2"}]}}}}
        ]}</script>
        """
    #expect(AppStoreCatalog.macStorefrontVersion(in: html, id: "1358823008") == "4.12.2")
    #expect(AppStoreCatalog.macStorefrontVersion(in: html, id: "1") == nil)
}
