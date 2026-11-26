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
        #expect(catalog.newerRelease(bundleID: "com.example.app", appPath: "/Applications/Example.app", installed: "2.0")?.version == "3.0")
        #expect(catalog.newerRelease(bundleID: "com.example.app", appPath: "/Applications/Example.app", installed: "3.0") == nil)
        #expect(catalog.newerRelease(bundleID: "com.example.app", appPath: "/Applications/Example.app", installed: "4.0") == nil)
        #expect(catalog.newerRelease(bundleID: "com.other.app", appPath: "/Applications/Example.app", installed: "2.0") == nil)
        #expect(catalog.newerRelease(bundleID: "com.example.app", appPath: "/Applications/Vendor App.app", installed: "2.0") == nil)
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
            #expect(catalog.newerRelease(bundleID: "com.example.app", appPath: "/Applications/Example.app", installed: "1.0") == nil)
        }
    }

    @Test func publicReleaseOffersOnlyUnambiguousArchivesWithAChecksum() throws {
        let hash = String(repeating: "a", count: 64)
        let app: [[String: Any]] = [["app": ["Example.app"], "target": "/Applications/Example.app"],
                                   ["uninstall": [["quit": "com.example.app"]]]]
        let cask: [String: Any] = [
            "version": "3.0", "deprecated": false, "disabled": false,
            "url": "https://example.com/download.dmg", "sha256": hash, "artifacts": app,
        ]
        let variants: [([String: Any], Bool)] = [
            ([:], true),
            (["sha256": "no_check"], false),
            (["url": "https://example.com/download.zip"], true),
            (["url": "https://example.com/download.pkg"], false),
            (["variations": ["tahoe": ["sha256": String(repeating: "b", count: 64)]]], false),
            (["artifacts": app + [["postflight_steps": []]]], false),
        ]
        for (changes, installable) in variants {
            let row = cask.merging(changes) { _, replacement in replacement }
            let catalog = try HomebrewCatalog(data: JSONSerialization.data(withJSONObject: [row]))
            let release = try #require(catalog.newerRelease(bundleID: "com.example.app",
                                                           appPath: "/Applications/Example.app", installed: "2.0"))
            #expect(release.version == "3.0")
            #expect((release.artifact != nil) == installable)
        }
    }

    @Test func configuredGitHubReleaseRequiresASingleAssetFromTheSameRelease() throws {
        let repository = try #require(ReleaseRepository("owner/project"))
        let asset: [String: Any] = [
            "name": "Example.dmg", "state": "uploaded", "digest": "sha256:" + String(repeating: "a", count: 64),
            "browser_download_url": "https://github.com/owner/project/releases/download/v3.0/Example.dmg",
        ]
        let mismatched = asset.merging(
            ["browser_download_url": "https://github.com/other/project/releases/download/v3.0/Example.dmg"]
        ) { _, replacement in replacement }
        for (assets, installable) in [([asset], true), ([asset, asset], false), ([mismatched], false)] {
            let row: [String: Any] = ["tag_name": "v3.0", "draft": false, "prerelease": false, "assets": assets]
            let data = try JSONSerialization.data(withJSONObject: row)
            let release = try #require(try repository.publishedRelease(from: data))
            #expect(release.version == "v3.0")
            #expect((release.artifact != nil) == installable)
        }
    }

    @Test(arguments: ["arm64", "x64"])
    func homebrewReleaseSelectsThePinnedArchitectureVariant(architecture: String) throws {
        let row: [String: Any] = [
            "version": "3.0", "deprecated": false, "disabled": false,
            "url": "https://example.com/Example-arm64.dmg", "sha256": String(repeating: "a", count: 64),
            "artifacts": [
                ["app": ["Example.app"]], ["uninstall": [["quit": "com.example.app"]]],
                ["binary": ["$APPDIR/Example.app/Contents/MacOS/example"]],
            ],
            "variations": ["sonoma": ["url": "https://example.com/Example-x64.dmg", "sha256": String(repeating: "b", count: 64)]],
        ]
        let data = try JSONSerialization.data(withJSONObject: [row])
        let catalog = try HomebrewCatalog(data: data, architecture: architecture)
        let release = catalog.newerRelease(bundleID: "com.example.app", appPath: "/Applications/Example.app", installed: "2.0")
        #expect(release?.artifact?.url.lastPathComponent == "Example-\(architecture).dmg")
    }

    @Test func checksumRejectsChangedDownload() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let artifact = try #require(ReleaseArtifact(url: URL(string: "https://example.com/example.dmg"),
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        try Data("abc".utf8).write(to: file)
        try artifact.verify(file)
        try Data("abcd".utf8).write(to: file)
        #expect(throws: UpdateRequiresApp.self) { try artifact.verify(file) }
    }

    @Test(arguments: ["arm64", "x64"])
    func electronGitHubFeedMatchesChannelReleaseAndArchitecture(architecture: String) throws {
        let config = "owner: vendor\nrepo: desktop\nprovider: github\nreleaseType: release"
        let feed = try #require(ElectronUpdateFeed(config: config, architecture: architecture))
        #expect(feed.channel == "latest")
        #expect(ElectronUpdateFeed(config: config + "\nprivate: true", architecture: architecture) == nil)
        #expect(ElectronUpdateFeed(config: config + "\nhost: internal.example", architecture: architecture) == nil)
        let names = ["Desktop-4.2-arm64.zip", "Desktop-4.2-arm64.dmg", "Desktop-4.2-x64.zip", "Desktop-4.2-x64.dmg"]
        let assets = names.map { name in
            ReleaseRepository.Asset(name: name, state: "uploaded",
                                    browser_download_url: URL(string: "https://github.com/vendor/desktop/releases/download/v4.2/\(name)")!,
                                    digest: "sha256:" + String(repeating: "a", count: 64))
        }
        let stable = ReleaseRepository.Release(tag_name: "v4.2", draft: false, prerelease: false, assets: assets)
        let files = "files:\n" + names.map { "  - url: \($0)\n" }.joined()
        let manifest = "version: '4.2'\n" + files
        #expect(feed.offer(from: manifest, release: stable)?.artifact?.url.lastPathComponent == "Desktop-4.2-\(architecture).dmg")
        #expect(feed.offer(from: "version: '4.1'\n" + files, release: stable) == nil)
        #expect(feed.offer(from: manifest + "stagingPercentage: 25\n", release: stable) == nil)
        let zipManifest = "version: '4.2'\nfiles:\n  - url: Desktop-4.2-\(architecture).zip\n"
        #expect(feed.offer(from: zipManifest, release: stable)?.artifact?.format == .zip)
        let other = architecture == "arm64" ? "x64" : "arm64"
        #expect(feed.offer(from: zipManifest.replacingOccurrences(of: architecture, with: other), release: stable) == nil)
    }

    @Test func genericElectronFeedSelectsTheChannelAndUsesManifestChecksum() throws {
        let config = "provider: generic\nurl: https://updates.example.com/desktop\nchannel: beta"
        let feed = try #require(ElectronUpdateFeed(config: config, architecture: "arm64"))
        guard case .manifest(let base) = feed.source else { Issue.record("Expected HTTPS feed"); return }
        #expect(base.absoluteString == "https://updates.example.com/desktop/beta-mac.yml")
        let digest = Data(repeating: 0x12, count: 64)
        let manifest = """
        version: 3.2.1
        files:
          - url: Example 3.2.1-x64.zip
            sha512: \(digest.base64EncodedString())
          - url: Example 3.2.1-arm64.zip
            sha512: \(digest.base64EncodedString())
            size: 1000
        """
        let release = try #require(feed.customOffer(from: Data(manifest.utf8), base: base))
        #expect(release.artifact?.url.absoluteString == "https://updates.example.com/desktop/Example%203.2.1-arm64.zip")
        #expect(release.artifact?.checksum == .sha512(digest))
        #expect(release.artifact?.size == 1000)
        #expect(feed.customOffer(from: Data((manifest + "\nstagingPercentage: 50").utf8), base: base) == nil)
        #expect(feed.customOffer(from: Data((manifest + "\n<<: *defaults").utf8), base: base) == nil)
        #expect(ElectronUpdateFeed(config: config.replacingOccurrences(of: "https:", with: "http:"),
                                  architecture: "arm64") == nil)
    }

    @Test func customSquirrelManifestChecksTheExplicitVersionAndChecksum() throws {
        let base = try #require(URL(string: "https://updates.example.com/releases.json"))
        let feed = try #require(ElectronUpdateFeed(manifestURL: base, architecture: "arm64"))
        let digest = String(repeating: "a", count: 64)
        let json = """
        {"currentRelease":"3.2.1","releases":[
          {"version":"3.2.1","updateTo":{"version":"3.2.1","url":"download/desktop","sha256":"\(digest)","size":200}}
        ]}
        """
        let release = try #require(feed.customOffer(from: Data(json.utf8), base: base))
        #expect(release.artifact?.url.path == "/download/desktop")
        #expect(release.artifact?.format == .zip)
        #expect(release.artifact?.checksum == .sha256(digest))
        #expect(feed.customOffer(from: Data(json.replacingOccurrences(of: "\"version\":\"3.2.1\",\"url\"",
                                                                       with: "\"version\":\"3.0\",\"url\"").utf8), base: base) == nil)
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

    @Test func electronPrereleaseVersionsFollowSemanticPrecedence() {
        #expect(ReleaseRepository.compare("1.2.3-beta.10", installed: "1.2.3-beta.9") == .orderedDescending)
        #expect(ReleaseRepository.compare("1.2.3-beta.1", installed: "1.2.3") == .orderedAscending)
        #expect(ReleaseRepository.compare("1.2.3+build.2", installed: "1.2.3+build.1") == .orderedSame)
        #expect(ReleaseRepository.compare("1.2.3-beta.01", installed: "1.2.3-beta.1") == nil)
    }
}
