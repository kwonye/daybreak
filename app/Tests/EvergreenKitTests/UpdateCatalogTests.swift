import Foundation
import Testing
@testable import EvergreenKit

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

    @Test func updaterOutputDoesNotTurnUnknownIntoCurrent() {
        #expect(UpdateCatalog.systemLabels("Finding available software") == [])
        #expect(UpdateCatalog.systemLabels("  * Label: macOS 27.1-26B101\n    Title: macOS 27.1, Version: 27.1") == ["macOS 27.1-26B101"])
        #expect(UpdateCatalog.microsoftVersions("Checking for updates...") == nil)
        #expect(UpdateCatalog.microsoftVersions("No updates available") == [:])
        #expect(UpdateCatalog.dockerStatus("Docker Desktop is not running") == nil)
        #expect(UpdateCatalog.dockerStatus("An update is available") == .available)
    }

    @Test func chatGPTUsesTheFeedForTheInstalledArchitecture() {
        let arm = NSNumber(value: NSBundleExecutableArchitectureARM64)
        let intel = NSNumber(value: NSBundleExecutableArchitectureX86_64)
        #expect(BackendRegistry.chatGPTFeed(architectures: [arm])?.lastPathComponent == "appcast.xml")
        #expect(BackendRegistry.chatGPTFeed(architectures: [intel])?.lastPathComponent == "appcast-x64.xml")
        #expect(BackendRegistry.chatGPTFeed(architectures: []) == nil)
    }

    @Test(arguments: [Int32(0), Int32(4)])
    func catalogFeedOverridesAreCheckOnly(exitCode: Int32) throws {
        let app = sample(id: "com.openai.codex", path: "/Applications/ChatGPT.app", hints: ["sparkle"])
        let feed = try #require(BackendRegistry.chatGPTFeed(architectures: [NSNumber(value: NSBundleExecutableArchitectureARM64)]))
        let process = UpdaterProcess { arguments, _ in
            #expect(arguments == ["/sparkle", app.path, "--probe", "--user-agent-name", "Evergreen",
                                 "--feed-url", feed.absoluteString])
            return ProcessOutput(exitCode: exitCode, stdout: Data(), stderr: Data())
        }
        let backend = UpdateBackend(kind: .sparkle, process: process, executable: "/sparkle", sparkleProbeFeed: feed)
        let result = try backend.check(app, interactiveCatalog: true)
        #expect(result.state == (exitCode == 0 ? .available : .current))
        #expect(result.requiresUserAction == (exitCode == 0))
        #expect(throws: EngineFailure.self) { try backend.apply(app) }
    }

    @Test func publicCaskRequiresOneMatchingAppAndBundleID() throws {
        let data = Data("""
        [{
          "version": "3.0", "deprecated": false, "disabled": false,
          "artifacts": [
            {"app": ["Nested/Vendor App.app", {"target": "Example.app"}]},
            {"uninstall": [{"quit": ["com.example.app"]}]}
          ],
          "variations": {"arm64_linux": {"version": "4.0"}}
        }]
        """.utf8)
        let catalog = try HomebrewCatalog(data: data)
        #expect(catalog.newerVersion(bundleID: "com.example.app", appPath: "/Applications/Example.app", installed: "2.0") == "3.0")
        #expect(catalog.newerVersion(bundleID: "com.example.app", appPath: "/Applications/Example.app", installed: "3.0") == nil)
        #expect(catalog.newerVersion(bundleID: "com.example.app", appPath: "/Applications/Example.app", installed: "4.0") == nil)
        #expect(catalog.newerVersion(bundleID: "com.other.app", appPath: "/Applications/Example.app", installed: "2.0") == nil)
        #expect(catalog.newerVersion(bundleID: "com.example.app", appPath: "/Applications/Vendor App.app", installed: "2.0") == nil)
    }

    @Test func publicCaskSkipsAmbiguousIdentitiesAndInconsistentVersions() throws {
        let cask: [String: Any] = [
            "version": "3.0", "deprecated": false, "disabled": false,
            "artifacts": [["app": ["Example.app"]], ["uninstall": [["quit": "com.example.app"]]]],
        ]
        let alternatives: [[String: Any]] = [
            ["version": "latest"],
            ["disabled": true],
            ["variations": ["sonoma": ["version": "2.0"]]],
            ["artifacts": [["app": ["Example.app"]],
                           ["uninstall": [["quit": ["com.example.app", "com.example.helper"]]]]]],
        ]
        let candidates = [[cask, cask]] + alternatives.map { change in [cask.merging(change) { _, replacement in replacement }] }
        for entries in candidates {
            let catalog = try HomebrewCatalog(data: JSONSerialization.data(withJSONObject: entries))
            #expect(catalog.newerVersion(bundleID: "com.example.app", appPath: "/Applications/Example.app", installed: "1.0") == nil)
        }
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
