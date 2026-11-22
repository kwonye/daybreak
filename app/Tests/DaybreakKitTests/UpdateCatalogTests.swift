import Foundation
import Testing
@testable import DaybreakKit

struct UpdateCatalogTests {
    @Test func releasePageAcceptsOnlyGitHubRepositoryPaths() throws {
        let official = try #require(ReleaseRepository("https://github.com/owner/project/releases"))
        #expect(official == ReleaseRepository("owner/project"))
        #expect(official == ReleaseRepository("https://github.com/owner/project/releases/latest"))
        #expect(ReleaseRepository("https://github.com.evil.test/owner/project") == nil)
        #expect(ReleaseRepository("https://github.com/owner/project/issues") == nil)
        #expect(ReleaseRepository("https://someone@github.com/owner/project") == nil)
    }

    @Test func comparisonAvoidsGuessingOnCustomReleaseTags() {
        #expect(ReleaseRepository.compare("v2.10", installed: "2.9.7") == .orderedDescending)
        #expect(ReleaseRepository.compare("2.10", installed: "2.10.0") == .orderedSame)
        #expect(ReleaseRepository.compare("2.10", installed: "2.10.1") == .orderedAscending)
        #expect(ReleaseRepository.compare("mac-arm64-v2.9", installed: "2.9.0") == nil)
        #expect(ReleaseRepository.compare("v2.10-rc.1", installed: "2.10.0") == nil)
    }

    @Test func savingReleasePagePreservesOtherConfiguration() throws {
        let original = try ConfigDocument.parse(Data(#"{"whitelist":["com.example.*"],"apps":{"com.example.App":{"backend":"command"}}}"#.utf8))
        var document = original
        try document.setReleaseRepository(try #require(ReleaseRepository("owner/project")), for: "com.example.App")
        #expect(document.root["release_repositories"] == .object(["com.example.App": .string("owner/project")]))
        #expect(document.root["apps"] == original.root["apps"])
        try document.setReleaseRepository(nil, for: "com.example.App")
        #expect(document == original)
    }

    @Test func updaterOutputDoesNotTurnUnknownIntoCurrent() {
        #expect(UpdateCatalog.systemLabels("Finding available software") == [])
        #expect(UpdateCatalog.systemLabels("  * Label: macOS 27.1-26B101\n    Title: macOS 27.1, Version: 27.1") == ["macOS 27.1-26B101"])
        #expect(UpdateCatalog.microsoftVersions("Checking for updates...") == nil)
        #expect(UpdateCatalog.microsoftVersions("No updates available") == [:])
        #expect(UpdateCatalog.dockerStatus("Docker Desktop is not running") == nil)
        #expect(UpdateCatalog.dockerStatus("An update is available") == .available)
    }

    @Test func publicStoreListingHasToMatchBundlePlatformAndOS() {
        let mac = AppStoreCatalog.Listing(trackId: 10, bundleId: "example.app",
                                          version: "2.0", minimumOsVersion: "14.0", kind: "mac-software")
        let mobile = AppStoreCatalog.Listing(trackId: 10, bundleId: "example.app",
                                             version: "2.0", minimumOsVersion: "14.0", kind: "software")
        #expect(mac.compareMacVersion(bundleID: "example.app", installed: "1.0", macOS: "14.2") == .orderedDescending)
        #expect(mac.compareMacVersion(bundleID: "example.app", installed: "1.0", macOS: "13.2") == nil)
        #expect(mac.compareMacVersion(bundleID: "other.app", installed: "1.0", macOS: "14.2") == nil)
        #expect(mac.compareMacVersion(bundleID: "example.app", installed: "2.0", macOS: "14.2") == .orderedSame)
        #expect(mobile.compareMacVersion(bundleID: "example.app", installed: "1.0", macOS: "14.2") == nil)
    }
}
