import AppKit
import Darwin
import Foundation
import Security

/// Entry point for the single-operation helper started by macOS authorization.
/// It accepts no commands and never executes code from an update package.
public enum StoreBundleInstaller {
    public static func run(arguments: [String]) {
        if arguments == ["--version"] {
            print("Daybreak Store Installer")
            return
        }
        do {
            guard geteuid() == 0, arguments.count == 6 else { throw EngineFailure("Administrator approval is required.") }
            try replace(source: arguments[0], receiptPath: arguments[1], destination: arguments[2],
                        id: arguments[3], oldVersion: arguments[4], oldBuild: arguments[5])
            print("installed")
        } catch {
            print(error.localizedDescription)
            exit(1)
        }
    }

    static func supportedDestination(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().path == "/Applications"
            && url.pathExtension == "app" && canonicalPath(path) == path
    }

    static func isStoreSigned(_ path: String, bundleID: String) -> Bool {
        storeTeam(path, bundleID: bundleID) != nil
    }

    private static func storeTeam(_ path: String, bundleID: String) -> String? {
        guard bundleID.wholeMatch(of: /[A-Za-z0-9.-]+/) != nil else { return nil }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists and identifier \"\(bundleID)\""
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode
                    | kSecCSCheckAllArchitectures | kSecCSRestrictSymlinks), requirement) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
    }

    private static func replace(source: String, receiptPath: String, destination: String,
                                id: String, oldVersion: String, oldBuild: String) throws {
        let fm = FileManager.default
        guard supportedDestination(destination), canonicalPath(source) == source, source != destination,
              try BundleMetadata.info(destination)["CFBundleIdentifier"] as? String == id,
              isFile(destination + "/Contents/_MASReceipt/receipt"), let team = storeTeam(destination, bundleID: id),
              storeTeam(source, bundleID: id) == team else {
            throw EngineFailure("Daybreak couldn’t verify both App Store copies.")
        }

        var template = Array("/Applications/.daybreak-store-XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw NativeState.posixError() }
        let storage = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        defer { try? fm.removeItem(at: storage) }
        let candidate = storage.appendingPathComponent(URL(fileURLWithPath: destination).lastPathComponent)
        try fm.copyItem(at: URL(fileURLWithPath: source), to: candidate)
        guard storeTeam(candidate.path, bundleID: id) == team else { throw EngineFailure("The staged app signature is invalid.") }
        let new = try BundleMetadata.read(candidate.path, observed: [], fingerprintExecutable: false)
        guard versionIncreases(oldVersion: oldVersion, oldBuild: oldBuild, newVersion: new.version, newBuild: new.build) else {
            throw EngineFailure("The replacement isn’t newer than the installed app.")
        }

        let receiptData = try readReceipt(receiptPath)
        let receipt = try StoreReceipt(verified: receiptData)
        guard receipt.bundleID == id, receipt.version == new.version else {
            throw EngineFailure("The App Store receipt doesn’t match the downloaded app.")
        }
        let receiptFolder = candidate.appendingPathComponent("Contents/_MASReceipt")
        if canonicalPath(receiptFolder.path) != nil {
            guard canonicalPath(receiptFolder.path) == receiptFolder.path else {
                throw EngineFailure("The downloaded app has an unexpected receipt location.")
            }
        } else {
            try fm.createDirectory(at: receiptFolder, withIntermediateDirectories: false)
        }
        let receiptFile = receiptFolder.appendingPathComponent("receipt")
        try receiptData.write(to: receiptFile, options: .atomic)
        try normalizeOwnership(candidate)
        guard storeTeam(candidate.path, bundleID: id) == team else { throw EngineFailure("The prepared app signature is invalid.") }

        let existing = try BundleMetadata.read(destination, observed: [], fingerprintExecutable: false)
        guard existing.version == oldVersion, existing.build == oldBuild, supportedDestination(destination),
              storeTeam(destination, bundleID: id) == team, NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .allSatisfy({ $0.isTerminated || $0.bundleURL?.path != destination })
        else { throw EngineFailure("The installed copy changed or is open. Try again after closing it.") }
        guard renameatx_np(AT_FDCWD, candidate.path, AT_FDCWD, destination, UInt32(RENAME_SWAP)) == 0 else {
            throw NativeState.posixError()
        }
    }

    static func versionIncreases(oldVersion: String, oldBuild: String, newVersion: String, newBuild: String) -> Bool {
        func numeric(_ first: String, _ second: String) -> ComparisonResult? {
            guard first.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) != nil,
                  second.wholeMatch(of: /[0-9]+(\.[0-9]+)*/) != nil else { return nil }
            let lhs = first.split(separator: ".")
            let rhs = second.split(separator: ".")
            for index in 0..<max(lhs.count, rhs.count) {
                let l = index < lhs.count ? String(lhs[index]) : "0"
                let r = index < rhs.count ? String(rhs[index]) : "0"
                let order = l.compare(r, options: .numeric)
                if order != .orderedSame { return order }
            }
            return .orderedSame
        }
        switch numeric(newVersion, oldVersion) {
        case .orderedDescending: return true
        case .orderedSame: return numeric(newBuild, oldBuild) == .orderedDescending
        default: return false
        }
    }

    static func readReceipt(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeState.posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              (1...1_048_576).contains(attributes.st_size),
              let data = try handle.read(upToCount: 1_048_577), data.count == attributes.st_size else {
            throw EngineFailure("The App Store receipt couldn’t be read.")
        }
        return data
    }

    private static func normalizeOwnership(_ root: URL) throws {
        let fm = FileManager.default
        // Drop copied ACLs, then change ownership without following symlinks.
        _ = try UpdaterProcess().checked(["/bin/chmod", "-RN", root.path], 60)
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw EngineFailure("Couldn’t prepare the downloaded app.")
        }
        func normalize(_ url: URL) throws {
            var attributes = stat()
            guard lstat(url.path, &attributes) == 0, lchown(url.path, 0, 0) == 0 else { throw NativeState.posixError() }
            let type = attributes.st_mode & S_IFMT
            if type != S_IFLNK {
                guard type == S_IFDIR || type == S_IFREG,
                      chmod(url.path, attributes.st_mode & 0o0755) == 0 else { throw NativeState.posixError() }
            }
        }
        try normalize(root)
        for case let file as URL in files { try normalize(file) }
    }
}
