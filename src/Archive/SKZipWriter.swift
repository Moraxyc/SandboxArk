/// Writer for the public SandboxArk/1 ZIP64 subset: UTF-8 names, Stored and Deflate
/// only, explicit directory members, ZIP64 when required. Local headers are written as
/// placeholders and backfilled, keeping bit 3 clear and the file readable mid-transaction.
struct SKZipWriter {
    /// Regular files default to Deflate; directories are always Stored.
    enum Method {
        case deflate
        case stored
    }

    /// What one written member contributed, so the caller can index the payload without rereading.
    struct Member: Sendable {
        var path: String
        var isDirectory: Bool
        var uncompressedBytes: Int64
        var compressedBytes: Int64
        var crc32: UInt32
        var sha256: SKSHA256.Digest?
        var localHeaderOffset: Int64
    }

    /// Fixed buffer budget for one member, independent of the member's size.
    static let chunkBytes = SKResourceLimits.previewChunkBytes

    private let descriptor: Int32
    private var offset: Int64 = 0
    private var central: [SKZipCentralHeader] = []
    private var finished = false

    /// `descriptor` must be a freshly created, empty regular file: the writer appends and
    /// backfills in place.
    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        let size = try SKArchiveIO.size(of: descriptor)
        guard size == 0 else { throw SKZipWriter.stateError("archive output is not empty") }
    }

    var memberCount: Int { central.count }

    /// `path` carries the trailing slash the profile requires.
    mutating func addDirectory(path: String,
                               permissions: UInt16,
                               modifiedAt: SKFileTimestamp) throws -> Member {
        try writeMember(path: path,
                        isDirectory: true,
                        declaredBytes: 0,
                        permissions: permissions,
                        modifiedAt: modifiedAt,
                        method: .stored) { _ in 0 }
    }

    /// Streams one regular member from a source the caller already verified. The writer
    /// never resolves a path and refuses more than `declaredBytes`, keeping ZIP64 valid.
    mutating func addRegularFile(path: String,
                                 descriptor source: Int32,
                                 declaredBytes: Int64,
                                 permissions: UInt16,
                                 modifiedAt: SKFileTimestamp,
                                 method: Method = .deflate) throws -> Member {
        guard declaredBytes >= 0 else { throw SKZipWriter.limitError("member declares a negative size") }
        return try writeMember(path: path,
                               isDirectory: false,
                               declaredBytes: declaredBytes,
                               permissions: permissions,
                               modifiedAt: modifiedAt,
                               method: method) { buffer in
            try SKArchiveIO.readChunk(from: source, into: &buffer)
        }
    }

    mutating func addPayload(path: String,
                             bytes: [UInt8],
                             permissions: UInt16,
                             modifiedAt: SKFileTimestamp,
                             method: Method = .deflate) throws -> Member {
        var cursor = 0
        return try writeMember(path: path,
                               isDirectory: false,
                               declaredBytes: Int64(bytes.count),
                               permissions: permissions,
                               modifiedAt: modifiedAt,
                               method: method) { buffer in
            let count = min(buffer.count, bytes.count - cursor)
            guard count > 0 else { return 0 }
            buffer.replaceSubrange(0..<count, with: bytes[cursor..<(cursor + count)])
            cursor += count
            return count
        }
    }

    /// Writes the central directory and the end records, then makes them durable. A file
    /// that did not reach this call is a `.partial`, never an archive.
    mutating func finish() throws {
        guard !finished else { throw SKZipWriter.stateError("archive was already finished") }
        finished = true

        let centralDirectoryOffset = offset
        var centralBytes = SKByteWriter()
        for record in central { centralBytes.append(record.encoded()) }
        try SKArchiveIO.write(centralBytes.bytes, at: offset, to: descriptor)
        offset += Int64(centralBytes.count)

        let centralDirectoryBytes = Int64(centralBytes.count)
        let memberCount = central.count
        let needsZip64 = memberCount > SKZip.maxClassicMemberCount
            || centralDirectoryBytes > SKZip.maxClassicOffset
            || centralDirectoryOffset > SKZip.maxClassicOffset

        if needsZip64 {
            let record = SKZip64EndOfCentralDirectory(memberCount: UInt64(memberCount),
                                                      centralDirectoryBytes: UInt64(centralDirectoryBytes),
                                                      centralDirectoryOffset: UInt64(centralDirectoryOffset))
            let recordOffset = offset
            try SKArchiveIO.write(record.encoded(), at: offset, to: descriptor)
            offset += Int64(SKZip.zip64EndOfCentralDirectoryBytes)
            try SKArchiveIO.write(SKZip64Locator(zip64EndOfCentralDirectoryOffset: UInt64(recordOffset)).encoded(),
                                  at: offset,
                                  to: descriptor)
            offset += Int64(SKZip.zip64LocatorBytes)
        }

        let classic = SKZipEndOfCentralDirectory(
            memberCount: nonSentinel16(memberCount),
            centralDirectoryBytes: nonSentinel32(centralDirectoryBytes),
            centralDirectoryOffset: nonSentinel32(centralDirectoryOffset))
        try SKArchiveIO.write(classic.encoded(), at: offset, to: descriptor)
        offset += Int64(SKZip.endOfCentralDirectoryBytes)
        try SKArchiveIO.sync(descriptor)
    }

    // MARK: - Member writing

    private mutating func writeMember(path: String,
                                      isDirectory: Bool,
                                      declaredBytes: Int64,
                                      permissions: UInt16,
                                      modifiedAt: SKFileTimestamp,
                                      method: Method,
                                      produce: (inout [UInt8]) throws -> Int) throws -> Member {
        guard !finished else { throw SKZipWriter.stateError("archive was already finished") }
        guard central.count < SKResourceLimits.maxArchiveMembers else {
            throw SKZipWriter.limitError("archive reached the member limit")
        }
        try SKArchivePath.validate(path, isDirectory: isDirectory)
        let name = Array(path.utf8)
        let timestamp = SKZipTimestamp(modifiedAt) ?? SKZipTimestamp.dosFloor
        let zip64 = !isDirectory && declaredBytes >= SKZip.zip64LocalHeaderThreshold
        let localHeaderOffset = offset
        let memberMethod = isDirectory ? SKZip.storedMethod
            : (method == .deflate ? SKZip.deflateMethod : SKZip.storedMethod)

        let placeholder = SKZipLocalHeader(versionNeeded: SKZip.versionNeededStoredOrDeflate,
                                           flags: SKZip.utf8NameFlag,
                                           method: memberMethod,
                                           dosTime: timestamp.dosTime,
                                           dosDate: timestamp.dosDate,
                                           crc32: 0,
                                           compressedBytes: zip64 ? UInt64(declaredBytes) : 0,
                                           uncompressedBytes: zip64 ? UInt64(declaredBytes) : 0,
                                           name: name,
                                           zip64: zip64)
        let placeholderBytes = placeholder.encoded()
        var cursor = offset
        try SKArchiveIO.write(placeholderBytes, at: cursor, to: descriptor)
        cursor += Int64(placeholderBytes.count)

        var hasher = SKSHA256.Hasher()
        var checksum: UInt32 = 0
        var uncompressed: Int64 = 0
        var compressed: Int64 = 0
        let deflater = (isDirectory || method == .stored) ? nil : try SKZipDeflater()

        if !isDirectory {
            var scratch = [UInt8](repeating: 0, count: SKZipWriter.chunkBytes)
            while true {
                let count = try produce(&scratch)
                guard count >= 0, count <= scratch.count else {
                    throw SKZipWriter.limitError("source returned an impossible byte count")
                }
                if count == 0 { break }
                let slice = scratch[0..<count]
                uncompressed += Int64(count)
                guard uncompressed <= declaredBytes else { throw SKZipWriter.sourceChanged(path) }
                checksum = slice.withUnsafeBufferPointer {
                    SKZipCompression.crc32(checksum, UnsafeRawBufferPointer($0))
                }
                hasher.update(slice)
                if let deflater {
                    try slice.withUnsafeBufferPointer { buffer in
                        _ = try deflater.process(buffer, finish: false) { output in
                            compressed += Int64(output.count)
                            try SKArchiveIO.write(output, at: cursor, to: descriptor)
                            cursor += Int64(output.count)
                        }
                    }
                } else {
                    compressed += Int64(count)
                    try SKArchiveIO.write(slice, at: cursor, to: descriptor)
                    cursor += Int64(count)
                }
            }
            if let deflater {
                let empty = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
                _ = try deflater.process(empty, finish: true) { output in
                    compressed += Int64(output.count)
                    try SKArchiveIO.write(output, at: cursor, to: descriptor)
                    cursor += Int64(output.count)
                }
            }
        }
        if !zip64 {
            guard compressed <= Int64(SKZip.maxUInt32), uncompressed <= Int64(SKZip.maxUInt32) else {
                throw SKZipWriter.limitError("member outgrew its 32-bit header fields")
            }
        }
        offset = cursor

        let header = SKZipLocalHeader(versionNeeded: SKZip.versionNeededStoredOrDeflate,
                                      flags: SKZip.utf8NameFlag,
                                      method: memberMethod,
                                      dosTime: timestamp.dosTime,
                                      dosDate: timestamp.dosDate,
                                      crc32: checksum,
                                      compressedBytes: UInt64(compressed),
                                      uncompressedBytes: UInt64(uncompressed),
                                      name: name,
                                      zip64: zip64)
        let headerBytes = header.encoded()
        guard headerBytes.count == placeholderBytes.count else { throw SKZipLayoutError.inconsistent }
        try SKArchiveIO.write(headerBytes, at: localHeaderOffset, to: descriptor)

        let centralZip64 = zip64 || Int64(compressed) > SKZip.maxClassicOffset
            || Int64(uncompressed) > SKZip.maxClassicOffset || localHeaderOffset > SKZip.maxClassicOffset
        let record = SKZipCentralHeader(versionMadeBy: SKZip.versionMadeByUnix,
                                        versionNeeded: SKZip.versionNeededStoredOrDeflate,
                                        flags: SKZip.utf8NameFlag,
                                        method: memberMethod,
                                        dosTime: timestamp.dosTime,
                                        dosDate: timestamp.dosDate,
                                        crc32: checksum,
                                        compressedBytes: UInt64(compressed),
                                        uncompressedBytes: UInt64(uncompressed),
                                        name: name,
                                        externalAttributes: SKZip.externalAttributes(isDirectory: isDirectory,
                                                                                     permissions: permissions),
                                        localHeaderOffset: UInt64(localHeaderOffset),
                                        zip64: centralZip64)
        central.append(record)

        return Member(path: path,
                      isDirectory: isDirectory,
                      uncompressedBytes: uncompressed,
                      compressedBytes: compressed,
                      crc32: checksum,
                      sha256: isDirectory ? nil : hasher.finalize(),
                      localHeaderOffset: localHeaderOffset)
    }

    // MARK: - Field helpers

    private func nonSentinel16(_ value: Int) -> UInt16 {
        value > SKZip.maxClassicMemberCount ? SKZip.sentinel16 : UInt16(truncatingIfNeeded: value)
    }

    private func nonSentinel32(_ value: Int64) -> UInt32 {
        value > SKZip.maxClassicOffset ? SKZip.sentinel32 : UInt32(truncatingIfNeeded: value)
    }

    static func stateError(_ reason: String) -> SKError {
        SKError(code: .archiveCorrupt, stage: "zipWriter", reason: reason)
    }

    static func limitError(_ reason: String) -> SKError {
        SKError(code: .archiveLimitExceeded, stage: "zipWriter", reason: reason)
    }

    static func sourceChanged(_ path: String) -> SKError {
        SKError(code: .filesystemChangedDuringRead,
                stage: "zipWriter",
                relativePath: path,
                reason: "source grew past its declared size")
    }
}
