import Foundation
import Testing
@testable import DaybreakKit

struct UpdateCheckCacheTests {
    @Test func automaticCooldownSurvivesReloadAndEndsAtOneHour() async throws {
        let directory = temporaryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        let initial = EngineClient(configURL: config, stateDirectory: directory)
        let time = Date(timeIntervalSince1970: 1_000)
        let snapshot = UpdateCheckCache(attemptedAt: time, checkedAt: time, items: [])
        try await initial.saveUpdateCheck(snapshot, configFingerprint: initial.updateConfigFingerprint())

        let reopened = EngineClient(configURL: config, stateDirectory: directory)
        let saved = try #require(await reopened.cachedUpdateCheck())
        #expect(saved.matchesConfig)
        #expect(!saved.check.allowsAutomaticCheck(at: time.addingTimeInterval(3_599)))
        #expect(saved.check.allowsAutomaticCheck(at: time.addingTimeInterval(3_600)))
        try Data("{}".utf8).write(to: config)
        #expect(await reopened.cachedUpdateCheck()?.matchesConfig == false)
    }

    @Test func restoreKeepsLiveIdentityAndExclusions() {
        func item(_ version: String, running: Bool, status: UpdateItem.Status, action: UpdateItem.Action?) -> UpdateItem {
            UpdateItem(name: "Example", bundleID: "example.app", path: "/Applications/Example.app",
                       installedVersion: version, isRunning: running, isMacAppStoreApp: false,
                       repository: nil, status: status, action: action)
        }
        let cached = item("1.0", running: false, status: .available, action: .install)
        let snapshot = UpdateCheckCache(attemptedAt: Date(), checkedAt: Date(), items: [cached])
        let inventory = item("1.0", running: true, status: .readyToCheck, action: nil)
        let restored = snapshot.restore(into: [inventory])[0]
        #expect(restored.isRunning)
        #expect(restored.action == .install)
        let changed = item("2.0", running: true, status: .readyToCheck, action: nil)
        let excluded = item("1.0", running: true, status: .excluded, action: nil)
        #expect(snapshot.restore(into: [changed, excluded]) == [changed, excluded])
    }
}
