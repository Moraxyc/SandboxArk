#if canImport(CryptoKit)
import CryptoKit
private typealias SKHashProvider = CryptoKit.SHA256
#elseif canImport(Crypto)
import Crypto
private typealias SKHashProvider = Crypto.SHA256
#else
#error("A SHA-256 provider is required: CryptoKit on Apple platforms, swift-crypto's Crypto module elsewhere.")
#endif

/// Incremental SHA-256 over uncompressed file bytes. CryptoKit is the provider on Apple
/// platforms, so no third-party hash library becomes a load-time dependency.
enum SKSHA256 {
    static let digestBytes = 32

    /// The hex form is the lowercase 64-character rendering the hash index uses.
    struct Digest: Equatable, Sendable {
        let bytes: [UInt8]

        init?(bytes: [UInt8]) {
            guard bytes.count == SKSHA256.digestBytes else { return nil }
            self.bytes = bytes
        }

        init?(hex: String) {
            guard hex.utf8.count == SKSHA256.digestBytes * 2 else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(SKSHA256.digestBytes)
            var iterator = hex.utf8.makeIterator()
            while let high = iterator.next(), let low = iterator.next() {
                guard let highValue = SKHex.value(of: high), let lowValue = SKHex.value(of: low) else { return nil }
                bytes.append(highValue << 4 | lowValue)
            }
            self.init(bytes: bytes)
        }

        var hex: String {
            var text = ""
            text.reserveCapacity(SKSHA256.digestBytes * 2)
            for byte in bytes {
                text.append(SKHex.digits[Int(byte >> 4)])
                text.append(SKHex.digits[Int(byte & 0x0F)])
            }
            return text
        }
    }

    /// Streaming hasher. Feed every byte exactly once, then read the digest.
    struct Hasher {
        private var provider = SKHashProvider()
        private var byteCount: Int64 = 0

        /// Bytes fed so far; the archive pipeline compares it against the source size.
        var count: Int64 { byteCount }

        mutating func update(_ bytes: ArraySlice<UInt8>) {
            guard !bytes.isEmpty else { return }
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                provider.update(bufferPointer: UnsafeRawBufferPointer(start: base, count: buffer.count))
            }
            byteCount += Int64(bytes.count)
        }

        mutating func update(_ bytes: [UInt8]) {
            update(bytes[...])
        }

        mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
            guard !bytes.isEmpty, let base = bytes.baseAddress else { return }
            provider.update(bufferPointer: UnsafeRawBufferPointer(start: base, count: bytes.count))
            byteCount += Int64(bytes.count)
        }

        func finalize() -> Digest {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(SKSHA256.digestBytes)
            for byte in provider.finalize() { bytes.append(byte) }
            // The provider always yields `digestBytes`; a short digest is a programming
            // error, not a runtime condition.
            guard let digest = Digest(bytes: bytes) else {
                preconditionFailure("SHA-256 provider returned \(bytes.count) bytes")
            }
            return digest
        }
    }

    /// One-shot digest of a bounded payload such as a manifest or hash index.
    static func digest(of bytes: [UInt8]) -> Digest {
        var hasher = Hasher()
        hasher.update(bytes)
        return hasher.finalize()
    }
}

/// Hex conversions shared by the digest type and the archive layer.
enum SKHex {
    static let digits = Array("0123456789abcdef")

    static func value(of byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
