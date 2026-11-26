import EvergreenArchive
import Foundation
import Testing
@testable import EvergreenKit

struct ReleaseZipTests {
    // ZIPs containing an app directory with a relative framework-style symlink,
    // or a directory traversal, escaping symlink, or symlink used as a directory.
    static let valid = "UEsDBBQAAAAIADVwel3/NQeMBwAAAAUAAAAZAAAARXhhbXBsZS5hcHAvQ29udGVudHMvZGF0YStLzMlMAQBQSwMEFAAAAAAAAAAhAN251yENAAAADQAAABMAAABFeGFtcGxlLmFwcC9jdXJyZW50Q29udGVudHMvZGF0YVBLAQIUAxQAAAAIADVwel3/NQeMBwAAAAUAAAAZAAAAAAAAAAAAAACAAQAAAABFeGFtcGxlLmFwcC9Db250ZW50cy9kYXRhUEsBAhQDFAAAAAAAAAAhAN251yENAAAADQAAABMAAAAAAAAAAAAAAP+hPgAAAEV4YW1wbGUuYXBwL2N1cnJlbnRQSwUGAAAAAAIAAgCIAAAAfAAAAAAA"
    static let unsafe = [
        "UEsDBBQAAAAIADVwel37OSuCBQAAAAMAAAAKAAAALi4vZXNjYXBlZEtKTAEAUEsBAhQDFAAAAAgANXB6Xfs5K4IFAAAAAwAAAAoAAAAAAAAAAAAAAIABAAAAAC4uL2VzY2FwZWRQSwUGAAAAAAEAAQA4AAAALQAAAAAA",
        "UEsDBBQAAAAAAAAAIQCEIMubEAAAABAAAAASAAAARXhhbXBsZS5hcHAvZXNjYXBlLi4vLi4vLi4vb3V0c2lkZVBLAwQUAAAACAA1cHpd+zkrggUAAAADAAAAGgAAAEV4YW1wbGUuYXBwL2VzY2FwZS9wYXlsb2FkS0pMAQBQSwECFAMUAAAAAAAAACEAhCDLmxAAAAAQAAAAEgAAAAAAAAAAAAAA/6EAAAAARXhhbXBsZS5hcHAvZXNjYXBlUEsBAhQDFAAAAAgANXB6Xfs5K4IFAAAAAwAAABoAAAAAAAAAAAAAAIABQAAAAEV4YW1wbGUuYXBwL2VzY2FwZS9wYXlsb2FkUEsFBgAAAAACAAIAiAAAAH0AAAAAAA==",
        "UEsDBBQAAAAIADVwel2PKKQfBgAAAAQAAAAZAAAARXhhbXBsZS5hcHAvQ29udGVudHMvZGF0YStOTEsFAFBLAwQUAAAAAAAAACEAIXOMTQgAAAAIAAAAEwAAAEV4YW1wbGUuYXBwL2N1cnJlbnRDb250ZW50c1BLAwQUAAAACAA1cHpd+zkrggUAAAADAAAAGwAAAEV4YW1wbGUuYXBwL2N1cnJlbnQvcGF5bG9hZEtKTAEAUEsBAhQDFAAAAAgANXB6XY8opB8GAAAABAAAABkAAAAAAAAAAAAAAIABAAAAAEV4YW1wbGUuYXBwL0NvbnRlbnRzL2RhdGFQSwECFAMUAAAAAAAAACEAIXOMTQgAAAAIAAAAEwAAAAAAAAAAAAAA/6E9AAAARXhhbXBsZS5hcHAvY3VycmVudFBLAQIUAxQAAAAIADVwel37OSuCBQAAAAMAAAAbAAAAAAAAAAAAAACAAXYAAABFeGFtcGxlLmFwcC9jdXJyZW50L3BheWxvYWRQSwUGAAAAAAMAAwDRAAAAtAAAAAAA",
    ]

    @Test func extractsAnAppWithAnInternalRelativeSymlink() throws {
        try withZip(Self.valid) { input, output in
            #expect(evergreen_extract_zip(input.path, output.path))
            let path = output.appendingPathComponent("Example.app/current")
            let contents = try String(contentsOf: path, encoding: .utf8)
            #expect(contents == "valid")
        }
    }

    @Test(arguments: unsafe)
    func rejectsPathTraversalAndSymlinkWrites(base64: String) throws {
        try withZip(base64) { input, output in
            #expect(!evergreen_extract_zip(input.path, output.path))
            #expect(!FileManager.default.fileExists(atPath: output.deletingLastPathComponent().appendingPathComponent("escaped").path))
            #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Example.app/Contents/payload").path))
        }
    }

    private func withZip(_ base64: String, body: (URL, URL) throws -> Void) throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("unpacked")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: output, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("fixture.zip")
        try #require(Data(base64Encoded: base64)).write(to: input)
        let resolved = try #require(canonicalPath(output.path))
        try body(input, URL(fileURLWithPath: resolved, isDirectory: true))
    }
}
