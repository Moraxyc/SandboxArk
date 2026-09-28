#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bounded-buffer file reads for hashing and archiving. Files are never loaded whole, and
/// the fixed buffer budget keeps peak memory flat regardless of file size.
enum SKStreamingIO {
    struct BoundedRead: Sendable {
        let bytes: [UInt8]
        /// True when the file is longer than the requested limit; the extra bytes are never
        /// retained.
        let truncated: Bool
    }

    /// Reads at most `limit` bytes from an already-verified descriptor; this layer never
    /// opens, resolves or closes a path.
    static func read(from descriptor: Int32,
                     upTo limit: Int,
                     chunkBytes: Int = SKResourceLimits.previewChunkBytes) throws -> BoundedRead {
        guard limit > 0 else { return BoundedRead(bytes: [], truncated: false) }
        let chunk = max(1, min(chunkBytes, limit))
        var buffer = [UInt8](repeating: 0, count: chunk)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chunk)

        while bytes.count < limit {
            let wanted = min(chunk, limit - bytes.count)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                posixRead(descriptor, raw.baseAddress, wanted)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw SKPathResolver.error(forErrno: errno, relativePath: nil)
            }
            if count == 0 { return BoundedRead(bytes: bytes, truncated: false) }
            bytes.append(contentsOf: buffer[0..<count])
        }

        var probe: UInt8 = 0
        let extra = withUnsafeMutableBytes(of: &probe) { raw -> Int in
            posixRead(descriptor, raw.baseAddress, 1)
        }
        return BoundedRead(bytes: bytes, truncated: extra > 0)
    }

    /// Qualified so the call cannot resolve to this type's own `read`.
    private static func posixRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(descriptor, buffer, count)
        #else
        Glibc.read(descriptor, buffer, count)
        #endif
    }
}
