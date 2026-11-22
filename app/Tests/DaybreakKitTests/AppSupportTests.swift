import Foundation
import Testing
@testable import DaybreakKit

@Suite struct TimeZoneCatalogTests {
    static let reference = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!

    @Test func groupsByRegionWithOtherLast() {
        let catalog = TimeZoneCatalog(
            identifiers: ["America/Los_Angeles", "Europe/Berlin", "UTC", "America/Argentina/Buenos_Aires", "Asia/Kolkata"],
            now: Self.reference)
        #expect(catalog.regions.map(\.name) == ["America", "Asia", "Europe", "Other"])
        let america = catalog.regions[0].zones
        #expect(america.map(\.city) == ["Argentina / Buenos Aires", "Los Angeles"])
        #expect(catalog.zone("America/Los_Angeles")?.offset == "GMT\u{2212}08:00")
        #expect(catalog.zone("Asia/Kolkata")?.offset == "GMT+05:30")
        #expect(catalog.zone("UTC")?.city == "UTC")
    }

    @Test func keepsValidExtraIdentifiersAndDropsInvalid() {
        let catalog = TimeZoneCatalog(identifiers: ["Europe/Berlin"], including: ["US/Pacific", "Mars/Olympus", ""], now: Self.reference)
        #expect(catalog.zone("US/Pacific") != nil)
        #expect(catalog.zone("Mars/Olympus") == nil)
        #expect(Set(catalog.regions.map(\.name)) == ["Europe", "US"])
    }

    @Test func defaultListIsLargeAndContainsDefault() {
        let catalog = TimeZoneCatalog()
        #expect(catalog.regions.flatMap(\.zones).count > 300)
        #expect(catalog.zone(EngineSettings.defaultTimezone) != nil)
    }

    @Test func filtering() {
        let catalog = TimeZoneCatalog(identifiers: ["America/Los_Angeles", "America/New_York", "Europe/London"], now: Self.reference)
        #expect(catalog.filtered("").count == 2)
        #expect(catalog.filtered("los").flatMap(\.zones).map(\.identifier) == ["America/Los_Angeles"])
        #expect(catalog.filtered("new york").flatMap(\.zones).map(\.identifier) == ["America/New_York"])
        #expect(catalog.filtered("europe").flatMap(\.zones).map(\.identifier) == ["Europe/London"])
        #expect(catalog.filtered("GMT+00").flatMap(\.zones).map(\.identifier) == ["Europe/London"])
        #expect(catalog.filtered("zzz").isEmpty)
    }

    @Test func offsetFormatting() {
        #expect(TimeZoneCatalog.formatOffset(0) == "GMT+00:00")
        #expect(TimeZoneCatalog.formatOffset(-9 * 3600 - 30 * 60) == "GMT\u{2212}09:30")
        #expect(TimeZoneCatalog.formatOffset(13 * 3600 + 45 * 60) == "GMT+13:45")
    }
}

@Suite struct AppInfoTests {
    @Test func bundleVersions() {
        #expect(AppInfo(infoDictionary: nil).displayVersion == "dev")
        #expect(AppInfo(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "0.1.0"]).displayVersion == "0.1.0")
        #expect(AppInfo(infoDictionary: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "42"]).displayVersion == "1.2 (42)")
    }

}

@Suite struct LaunchOptionsTests {
    @Test func parsesKnownArguments() {
        let options = LaunchOptions(arguments: ["/path/Daybreak", "--pane", "whitelist", "--appearance", "dark", "--preview",
                                                "-NSDocumentRevisionsDebugMode", "YES", "--settings", "engine"])
        #expect(options.pane == "whitelist")
        #expect(options.appearance == "dark")
        #expect(options.autoPreview)
        #expect(options.openSettings)
        #expect(options.settingsTab == "engine")
    }

    @Test func missingValuesAreIgnored() {
        let options = LaunchOptions(arguments: ["app", "--pane", "--settings"])
        #expect(options.pane == nil)
        #expect(options.openSettings)
        #expect(options.settingsTab == nil)
        #expect(LaunchOptions(arguments: ["app"]) == LaunchOptions())
        #expect(LaunchOptions(arguments: ["app", "--snapshot", "/tmp/shots"]).snapshotDirectory == "/tmp/shots")
    }
}
