import CryptoKit
import Foundation
import Security

/// Validates the App Store's signed receipt for the exact replacement bundle.
struct StoreReceipt {
    let bundleID: String
    let version: String

    init(verified data: Data) throws {
        var decoded: CMSDecoder?
        guard data.count <= 1_048_576, CMSDecoderCreate(&decoded) == errSecSuccess, let decoded,
              data.withUnsafeBytes({ bytes in
                  guard let pointer = bytes.baseAddress else { return errSecParam }
                  return CMSDecoderUpdateMessage(decoded, pointer, bytes.count)
              }) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoded) == errSecSuccess else { throw Self.invalid }
        var content: CFData?
        guard CMSDecoderCopyContent(decoded, &content) == errSecSuccess, let content else { throw Self.invalid }
        let fields = try Self.fields(content as Data)
        guard let bundleID = fields[2], let version = fields[3], let date = fields[12],
              let created = ISO8601DateFormatter().date(from: date) else { throw Self.invalid }

        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        guard CMSDecoderCopySignerStatus(decoded, 0, SecPolicyCreateBasicX509(), false, &status, &trust, nil) == errSecSuccess,
              status == .valid, let trust,
              SecTrustSetVerifyDate(trust, created as CFDate) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let signer = chain.first, let anchor = chain.last,
              Self.receiptSignerNames.contains(SecCertificateCopySubjectSummary(signer) as String? ?? ""),
              Self.appleRoots.contains(SHA256.hash(data: SecCertificateCopyData(anchor) as Data)
                .map { String(format: "%02x", $0) }.joined())
        else { throw Self.invalid }
        self.bundleID = bundleID
        self.version = version
    }

    private static let invalid = EngineFailure("The App Store receipt couldn’t be verified.")
    private static let receiptSignerNames: Set<String> = [
        "Mac App Store and iTunes Store Receipt Signing", "Apple iTunes Store Receipt Signing",
    ]
    // Apple Root CA, Apple Root CA - G2 and Apple Root CA - G3.
    private static let appleRoots: Set<String> = [
        "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
        "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
        "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
    ]

    static func fields(_ data: Data) throws -> [Int: String] {
        var outer = DER(bytes: ArraySlice(data))
        var set = DER(bytes: try outer.take(0x31))
        guard outer.bytes.isEmpty else { throw invalid }
        var fields: [Int: String] = [:]
        while !set.bytes.isEmpty {
            var entry = DER(bytes: try set.take(0x30))
            let key = try entry.take(0x02)
            _ = try entry.take(0x02)
            let value = try entry.take(0x04)
            guard entry.bytes.isEmpty else { throw invalid }
            guard key.count == 1, let first = key.first, [2, 3, 12].contains(first) else { continue }
            let type = Int(first)
            var encoded = DER(bytes: value)
            let text = try encoded.take(type == 12 ? 0x16 : 0x0c)
            guard encoded.bytes.isEmpty, fields[type] == nil, let string = String(bytes: text, encoding: .utf8)
            else { throw invalid }
            fields[type] = string
        }
        return fields
    }

    private struct DER {
        var bytes: ArraySlice<UInt8>

        mutating func take(_ tag: UInt8) throws -> ArraySlice<UInt8> {
            guard bytes.popFirst() == tag, let first = bytes.popFirst() else { throw StoreReceipt.invalid }
            var length = Int(first)
            if first >= 128 {
                let size = Int(first & 0x7f)
                guard (1...4).contains(size), size <= bytes.count else { throw StoreReceipt.invalid }
                length = 0
                for _ in 0..<size { length = (length << 8) | Int(bytes.removeFirst()) }
            }
            guard length <= bytes.count else { throw StoreReceipt.invalid }
            let result = bytes.prefix(length)
            bytes = bytes.dropFirst(length)
            return result
        }
    }
}
