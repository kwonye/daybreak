import EvergreenStoreBridge
import Foundation
import Testing
@testable import EvergreenKit

struct NativeStoreTests {
    @Test func directInstallsRequireOptIn() throws {
        let original = try ConfigDocument.parse(Data(#"{"exclude":["com.example.app"]}"#.utf8))
        var document = original
        let defaults = try original.settings()
        #expect(!defaults.directAppStoreUpdates)
        #expect(try !EngineConfiguration(url: nil).directAppStoreUpdates)
        var settings = defaults
        settings.directAppStoreUpdates = true
        try document.applySettings(settings, original: defaults)
        #expect(try document.settings().directAppStoreUpdates)
        #expect(document.root["exclude"] == original.root["exclude"])
        #expect(document.root["direct_app_store_updates"] == .bool(true))
    }

    @Test func installerRejectsTheSameVersionOrDowngrades() {
        #expect(StoreBundleInstaller.versionIncreases(oldVersion: "1.9", oldBuild: "20", newVersion: "1.10", newBuild: "1"))
        #expect(StoreBundleInstaller.versionIncreases(oldVersion: "2.0", oldBuild: "20", newVersion: "2.0.0", newBuild: "21"))
        #expect(!StoreBundleInstaller.versionIncreases(oldVersion: "2.0", oldBuild: "20", newVersion: "2.0.0", newBuild: "20"))
        #expect(!StoreBundleInstaller.versionIncreases(oldVersion: "2.0", oldBuild: "20", newVersion: "1.10", newBuild: "999"))
        #expect(!StoreBundleInstaller.versionIncreases(oldVersion: "2.0", oldBuild: "20", newVersion: "other", newBuild: "999"))
        #expect(!StoreBundleInstaller.supportedDestination("/tmp/App.app"))
    }

    @Test func receiptParsingRejectsTrailingAndTruncatedData() throws {
        // SET { SEQUENCE { field 2, field version 1, OCTET STRING { UTF8String "app" } } }
        let data = Data([0x31, 0x0f, 0x30, 0x0d, 0x02, 0x01, 0x02, 0x02,
                         0x01, 0x01, 0x04, 0x05, 0x0c, 0x03, 0x61, 0x70, 0x70])
        #expect(try StoreReceipt.fields(data) == [2: "app"])
        #expect(throws: EngineFailure.self) { try StoreReceipt.fields(data.dropLast()) }
        #expect(throws: EngineFailure.self) { try StoreReceipt.fields(data + Data([0])) }
        #expect(throws: EngineFailure.self) { try StoreReceipt(verified: data) }
    }

    @Test func nativeStorePreflightReadsAnInstalledApp() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["DAYBREAK_STORE_TEST_APP"] else { return }
        let metadata = try BundleMetadata.read(path, observed: [], fingerprintExecutable: false)
        let id = try #require(try BundleMetadata.info(path)["CFBundleIdentifier"] as? String)
        let receipt = try StoreReceipt(verified: Data(contentsOf: URL(fileURLWithPath: path + "/Contents/_MASReceipt/receipt")))
        #expect(receipt.bundleID == id)
        #expect(receipt.version == metadata.version)
        #expect(StoreBundleInstaller.isStoreSigned(path, bundleID: id))
        #expect(DBStoreIsAvailable())
    }
}
