import DaybreakStoreBridge
import Foundation
import Security

struct NativeStoreUpdate {
    private struct Download: Sendable {
        let installed: Bool
        let package: URL?
        let receipt: URL?
    }

    private static var installer: String? {
        let contents = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
        let path = contents?.appendingPathComponent("Helpers/daybreak-store-installer").path
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    static var isAvailable: Bool { installer != nil && DBStoreIsAvailable() }

    static func install(id: UInt64, app: ManagedApp, process: UpdaterProcess) async throws {
        guard let installer, isAvailable else {
            throw EngineFailure("Direct App Store updates are unavailable in this build.")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("daybreak-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let result: Download = try await withCheckedThrowingContinuation { continuation in
            DBStoreUpdate(id, staging) { installed, package, receipt, message in
                if let message {
                    continuation.resume(throwing: EngineFailure(message))
                } else {
                    continuation.resume(returning: Download(installed: installed, package: package, receipt: receipt))
                }
            }
        }
        if result.installed { return }
        guard let package = result.package, let receipt = result.receipt else {
            throw EngineFailure("The App Store didn’t return the update files.")
        }
        let payload = staging.appendingPathComponent("payload")
        _ = try process.checked(["/usr/sbin/pkgutil", "--expand-full", package.path, payload.path], 300)
        let candidate = try extractApp(payload, bundleID: app.bundleID)
        let updated = try BundleMetadata.read(candidate, observed: [], fingerprintExecutable: false)
        let receiptData = try StoreBundleInstaller.readReceipt(receipt.path)
        let verifiedReceipt = try StoreReceipt(verified: receiptData)
        guard verifiedReceipt.bundleID == app.bundleID, verifiedReceipt.version == updated.version,
              StoreBundleInstaller.versionIncreases(oldVersion: app.metadata.version, oldBuild: app.metadata.build,
                                                   newVersion: updated.version, newBuild: updated.build)
        else { throw EngineFailure("The downloaded update couldn’t be matched to a newer App Store version.") }
        try validateInstallTool(installer)

        var message: NSString?
        let status = DBRunStoreInstaller(installer, [candidate, receipt.path, app.path, app.bundleID,
                                                     app.metadata.version, app.metadata.build], &message)
        if status == errAuthorizationCanceled { throw CancellationError() }
        guard status == errAuthorizationSuccess else {
            throw EngineFailure("macOS didn’t authorize the update. You can finish it in the App Store.")
        }
        let resultText = (message as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resultText == "installed" else {
            throw EngineFailure(resultText ?? "The installer didn’t confirm completion. Check the installed version before retrying.")
        }
        _ = try? process.checked(["/usr/bin/mdimport", app.path], 15)
    }

    private static func validateInstallTool(_ path: String) throws {
        // The application's signature seals the nested tool that is about to receive authorization.
        let bundle = Bundle.main.bundleURL
        let expected = bundle.appendingPathComponent("Contents/Helpers/daybreak-store-installer").path
        var appCode: SecStaticCode?
        guard path == expected, canonicalPath(path) == path,
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &appCode) == errSecSuccess, let appCode,
              SecStaticCodeCheckValidity(appCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil)
                == errSecSuccess else {
            throw EngineFailure("macOS couldn’t verify Daybreak’s installer. Open the App Store to update.")
        }
    }

    private static func extractApp(_ payload: URL, bundleID: String) throws -> String {
        let fm = FileManager.default
        guard let root = canonicalPath(payload.path),
              let files = fm.enumerator(at: payload, includingPropertiesForKeys: [.isDirectoryKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw EngineFailure("The App Store update couldn’t be unpacked.")
        }
        var matches: [String] = []
        for case let url as URL in files where url.pathExtension == "app" {
            files.skipDescendants()
            if let path = canonicalPath(url.path), path.hasPrefix(root + "/"),
               (try? BundleMetadata.info(path)["CFBundleIdentifier"] as? String) == bundleID {
                matches.append(path)
            }
        }
        guard matches.count == 1, let app = matches.first, StoreBundleInstaller.isStoreSigned(app, bundleID: bundleID) else {
            throw EngineFailure("The App Store package doesn’t contain a single verifiable copy of this app.")
        }
        return app
    }
}
