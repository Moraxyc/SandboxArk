import zlib

/// Thin Swift surface over the part of zlib the container needs: CRC-32 for member
/// headers and raw deflate streams for ZIP method 8. `zlib` comes from the iPhoneOS SDK's
/// own system module; the matching dylib is named in `OTHER_LDFLAGS`.
enum SKZipCompression {
    static func crc32(_ checksum: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = bytes.baseAddress else { return checksum }
        return UInt32(truncatingIfNeeded: zlib.crc32(uLong(checksum), base.assumingMemoryBound(to: Bytef.self), uInt(bytes.count)))
    }

    static func failure(_ status: Int32, _ operation: String) -> SKError {
        SKError(code: .archiveCorrupt, stage: "compression", reason: "\(operation) failed with zlib status \(status)")
    }
}

/// Raw deflate stream: `windowBits = -15` is ZIP method 8's headerless form.
final class SKZipDeflater {
    private var stream = z_stream()
    private var isOpen = false
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

    init(level: Int32 = Int32(Z_DEFAULT_COMPRESSION)) throws {
        let status = deflateInit2_(&stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw SKZipCompression.failure(status, "deflateInit2") }
        isOpen = true
    }

    deinit {
        if isOpen { deflateEnd(&stream) }
    }

    /// `finish` writes the final block; the return value reports whether zlib ended the stream.
    func process(_ input: UnsafeBufferPointer<UInt8>,
                 finish: Bool,
                 sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws -> Bool {
        stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
        stream.avail_in = uInt(input.count)

        if finish {
            while true {
                let result = try pump(Int32(Z_FINISH), sink: sink)
                if result.status == Z_STREAM_END { return true }
                // No progress with Z_FINISH means zlib cannot emit anything further.
                if result.bytes == 0 { return false }
            }
        }
        while stream.avail_in > 0 {
            if try pump(Int32(Z_NO_FLUSH), sink: sink).status == Z_STREAM_END { return true }
        }
        return false
    }

    private func pump(_ flush: Int32,
                      sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws -> (bytes: Int, status: Int32) {
        var produced = 0
        let status = scratch.withUnsafeMutableBufferPointer { output -> Int32 in
            stream.next_out = output.baseAddress
            stream.avail_out = uInt(output.count)
            let result = deflate(&stream, flush)
            produced = output.count - Int(stream.avail_out)
            return result
        }
        if produced > 0 {
            try scratch.withUnsafeBufferPointer { buffer in
                try sink(UnsafeBufferPointer(rebasing: buffer[0..<produced]))
            }
        }
        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
            throw SKZipCompression.failure(status, "deflate")
        }
        return (produced, status)
    }
}

/// Raw inflate stream, the reading direction of the same method.
final class SKZipInflater {
    private var stream = z_stream()
    private var isOpen = false
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    private var finished = false

    init() throws {
        let status = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw SKZipCompression.failure(status, "inflateInit2") }
        isOpen = true
    }

    deinit {
        if isOpen { inflateEnd(&stream) }
    }

    /// `finish` must be set once the input is exhausted, so a truncated member cannot pass.
    func process(_ input: UnsafeBufferPointer<UInt8>,
                 finish: Bool,
                 sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws -> Bool {
        if finished { return true }
        stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
        stream.avail_in = uInt(input.count)

        if finish {
            while true {
                let result = try pump(Int32(Z_FINISH), sink: sink)
                if result.status == Z_STREAM_END { finished = true; return true }
                if result.bytes == 0 { return false }
            }
        }
        while stream.avail_in > 0 {
            // Output can still be pending after the last input byte, so keep pumping.
            if try pump(Int32(Z_NO_FLUSH), sink: sink).status == Z_STREAM_END {
                finished = true
                return true
            }
        }
        return false
    }

    private func pump(_ flush: Int32,
                      sink: (UnsafeBufferPointer<UInt8>) throws -> Void) throws -> (bytes: Int, status: Int32) {
        var produced = 0
        let status = scratch.withUnsafeMutableBufferPointer { output -> Int32 in
            stream.next_out = output.baseAddress
            stream.avail_out = uInt(output.count)
            let result = inflate(&stream, flush)
            produced = output.count - Int(stream.avail_out)
            return result
        }
        if produced > 0 {
            try scratch.withUnsafeBufferPointer { buffer in
                try sink(UnsafeBufferPointer(rebasing: buffer[0..<produced]))
            }
        }
        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
            throw SKZipCompression.failure(status, "inflate")
        }
        return (produced, status)
    }
}
