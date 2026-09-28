/// Reopening verifier for the public SandboxArk/1 ZIP64 subset. It re-reads the archive
/// through the same layout definitions and checks what a general-purpose unzip does not:
/// header agreement, member boundaries, the whitelist, and every CRC32 and SHA-256.
enum SKZipReader {
    /// One verified member, in central-directory order.
    struct Member: Sendable {
        var path: String
        var isDirectory: Bool
        var size: Int64
        var compressedBytes: Int64
        var crc32: UInt32
        var permissions: UInt16
        var localHeaderOffset: Int64
    }

    struct Contents: Sendable {
        var members: [Member]
        var manifest: SKManifestDocument
        var hashIndex: SKHashIndexDocument
    }

    /// Allowed general-purpose flags: the compression hints (which do not change the
    /// stored bytes) and the UTF-8 name bit, which the profile requires.
    private static let supportedFlags: UInt16 = 0x0002 | 0x0004 | 0x0800

    // MARK: - Verification

    static func verify(descriptor: Int32) throws -> Contents {
        let fileBytes = try SKArchiveIO.size(of: descriptor)
        let trailer = try readTrailer(descriptor: descriptor, fileBytes: fileBytes)
        let members = try readMembers(descriptor: descriptor, trailer: trailer)
        try checkMemberSet(members, centralDirectoryOffset: Int64(trailer.centralDirectoryOffset))

        guard let manifestIndex = members.firstIndex(where: { $0.path == SKManifest.manifestPath }),
              let hashIndexIndex = members.firstIndex(where: { $0.path == SKManifest.hashIndexPath }) else {
            throw SKZipLayoutError.inconsistent
        }
        let manifestBytes = try stream(members[manifestIndex],
                                       descriptor: descriptor,
                                       retaining: SKResourceLimits.maxManifestBytes)
        let hashBytes = try stream(members[hashIndexIndex],
                                   descriptor: descriptor,
                                   retaining: SKResourceLimits.maxHashIndexBytes)
        let manifest = try SKManifestDocument.decode(try SKJSONParser.parse(manifestBytes.payload))
        let hashIndex = try SKHashIndexDocument.decode(try SKJSONParser.parse(hashBytes.payload,
                                                                             limits: hashLimits))

        try checkCorrespondence(members, hashIndex: hashIndex)
        try checkDigest(members[manifestIndex], hashIndex: hashIndex, streamed: manifestBytes)
        for index in members.indices where index != manifestIndex && index != hashIndexIndex {
            let streamed = try stream(members[index], descriptor: descriptor)
            try checkDigest(members[index], hashIndex: hashIndex, streamed: streamed)
        }

        return Contents(members: members.map {
            Member(path: $0.path,
                   isDirectory: $0.isDirectory,
                   size: $0.size,
                   compressedBytes: $0.compressedBytes,
                   crc32: $0.crc32,
                   permissions: $0.permissions,
                   localHeaderOffset: $0.localHeaderOffset)
        }, manifest: manifest, hashIndex: hashIndex)
    }

    // MARK: - Structure

    private static func readTrailer(descriptor: Int32, fileBytes: Int64) throws -> SKZipTrailer {
        let window = Int64(SKZip.endOfCentralDirectoryBytes + SKZip.zip64LocatorBytes
            + SKZip.zip64EndOfCentralDirectoryBytes)
        let count = Int(min(window, max(0, fileBytes)))
        let tail = count > 0 ? try SKArchiveIO.readExactly(at: fileBytes - Int64(count),
                                                           count: count,
                                                           from: descriptor) : []
        return try SKZipTrailer.parse(tail: tail, fileBytes: fileBytes)
    }

    private static func readMembers(descriptor: Int32, trailer: SKZipTrailer) throws -> [RawMember] {
        guard trailer.memberCount <= UInt64(SKResourceLimits.maxArchiveMembers) else {
            throw limitError("archive exceeds the member limit")
        }
        guard trailer.centralDirectoryBytes <= UInt64(SKResourceLimits.maxCentralDirectoryBytes) else {
            throw limitError("central directory exceeds the read limit")
        }
        let offset = Int64(trailer.centralDirectoryOffset)
        let count = Int(trailer.centralDirectoryBytes)
        guard offset >= 0, offset + Int64(count) == trailer.centralDirectoryEnd else {
            throw SKZipLayoutError.inconsistent
        }

        let bytes = try SKArchiveIO.readExactly(at: offset, count: count, from: descriptor)
        var reader = SKByteReader(bytes: bytes)
        var members: [RawMember] = []
        members.reserveCapacity(Int(trailer.memberCount))
        while reader.remaining > 0 {
            let header = try SKZipCentralHeader.parse(&reader)
            members.append(try resolve(header, descriptor: descriptor))
        }
        guard members.count == Int(trailer.memberCount) else { throw SKZipLayoutError.inconsistent }
        return members
    }

    /// Resolves the payload range of one central entry checked against its local header.
    private static func resolve(_ header: SKZipCentralHeader, descriptor: Int32) throws -> RawMember {
        guard header.flags & ~supportedFlags == 0, header.flags & SKZip.utf8NameFlag != 0 else {
            throw unsupported("member flags are outside the profile")
        }
        guard header.versionNeeded <= SKZip.versionNeededZip64 else {
            throw unsupported("member needs a newer ZIP version")
        }
        guard header.method == SKZip.storedMethod || header.method == SKZip.deflateMethod else {
            throw unsupported("member uses an unsupported compression method")
        }
        let path = String(decoding: header.name, as: UTF8.self)
        guard Array(path.utf8).elementsEqual(header.name) else {
            throw unsupported("member name is not UTF-8")
        }
        let isDirectory = path.hasSuffix("/")
        try SKArchivePath.validate(path, isDirectory: isDirectory)
        try SKArchivePath.authorized(path, isDirectory: isDirectory)
        try SKArchivePath.checkNotReserved(path)

        let offset = Int64(header.localHeaderOffset)
        let fixed = try SKArchiveIO.readExactly(at: offset, count: SKZip.localHeaderBytes, from: descriptor)
        let nameBytes = Int(fixed[26]) | Int(fixed[27]) << 8
        let extraBytes = Int(fixed[28]) | Int(fixed[29]) << 8
        guard nameBytes > 0, nameBytes <= SKResourceLimits.maxArchivePathBytes else {
            throw SKZipLayoutError.inconsistent
        }
        let variable = try SKArchiveIO.readExactly(at: offset + Int64(SKZip.localHeaderBytes),
                                                   count: nameBytes + extraBytes,
                                                   from: descriptor)
        var localReader = SKByteReader(bytes: fixed + variable)
        let local = try SKZipLocalHeader.parse(&localReader)
        guard localReader.remaining == 0,
              local.name == header.name,
              local.flags == header.flags,
              local.method == header.method,
              local.dosTime == header.dosTime,
              local.dosDate == header.dosDate,
              local.crc32 == header.crc32,
              local.compressedBytes == header.compressedBytes,
              local.uncompressedBytes == header.uncompressedBytes else {
            throw SKZipLayoutError.inconsistent
        }

        let kind = header.externalAttributes >> 16 & 0o170000
        guard isDirectory ? kind == 0o040000 : kind == 0o100000 else {
            throw unsupported("member is not a regular file or a directory")
        }
        if isDirectory {
            guard header.compressedBytes == 0, header.uncompressedBytes == 0 else {
                throw SKZipLayoutError.inconsistent
            }
        }

        return RawMember(header: header,
                         path: path,
                         isDirectory: isDirectory,
                         dataOffset: offset + Int64(SKZip.localHeaderBytes + nameBytes + extraBytes),
                         permissions: UInt16(header.externalAttributes >> 16 & 0o777))
    }

    /// The member set is a closed list: names are unique, namespace directories are
    /// explicit, and members tile the file up to the central directory, so nothing hides.
    private static func checkMemberSet(_ members: [RawMember], centralDirectoryOffset: Int64) throws {
        var names: Set<String> = []
        for member in members {
            guard names.insert(member.path).inserted else {
                throw SKZipLayoutError.inconsistent
            }
        }
        for member in members {
            var parent = member.path.hasSuffix("/") ? String(member.path.dropLast()) : member.path
            while let separator = parent.lastIndex(of: "/") {
                parent = String(parent[parent.startIndex..<separator])
                let directory = parent.isEmpty ? "" : parent + "/"
                if directory.isEmpty || isNamespaceRoot(directory) { break }
                guard names.contains(directory) else { throw SKZipLayoutError.inconsistent }
            }
        }
        var previousEnd: Int64 = 0
        for member in members.sorted(by: { $0.header.localHeaderOffset < $1.header.localHeaderOffset }) {
            guard Int64(member.header.localHeaderOffset) == previousEnd else {
                throw SKZipLayoutError.inconsistent
            }
            previousEnd = member.dataOffset + Int64(member.header.compressedBytes)
        }
        guard previousEnd <= centralDirectoryOffset else { throw SKZipLayoutError.inconsistent }
    }

    private static func isNamespaceRoot(_ directory: String) -> Bool {
        directory == "data/" || directory == "data/home/" || directory == "app-groups/"
    }

    // MARK: - Index correspondence

    private static func checkCorrespondence(_ members: [RawMember],
                                            hashIndex: SKHashIndexDocument) throws {
        var index: [String: SKHashIndexDocument.Entry] = [:]
        for entry in hashIndex.entries { index[entry.path] = entry }
        var seen: Set<String> = []
        for member in members {
            let path = member.isDirectory ? String(member.path.dropLast()) : member.path
            guard path != SKManifest.hashIndexPath else { continue }
            guard let entry = index[path] else { throw mismatch(path) }
            guard seen.insert(path).inserted else { throw mismatch(path) }
            switch (member.isDirectory, entry.kind) {
            case (true, .directory):
                guard entry.size == 0, entry.sha256 == nil else { throw mismatch(path) }
            case (false, .regular):
                guard entry.size == member.size, entry.sha256 != nil else { throw mismatch(path) }
            default:
                throw mismatch(path)
            }
        }
        guard seen.count == index.count else {
            throw mismatch("hash index lists a member the archive does not have")
        }
    }

    private static func checkDigest(_ member: RawMember,
                                    hashIndex: SKHashIndexDocument,
                                    streamed: Streamed) throws {
        let path = member.isDirectory ? String(member.path.dropLast()) : member.path
        guard let entry = hashIndex.entries.first(where: { $0.path == path }) else { throw mismatch(path) }
        guard streamed.crc32 == member.crc32,
              streamed.size == member.size,
              entry.size == member.size else {
            throw invalid(path)
        }
        guard let expected = entry.sha256 else {
            // A directory is indexed by path and size, so only its kind decides here.
            guard member.isDirectory, entry.kind == .directory else { throw mismatch(path) }
            return
        }
        guard !member.isDirectory, expected == streamed.digest else { throw mismatch(path) }
    }

    // MARK: - Payload streaming

    private struct Streamed {
        /// The payload, retained only when the caller asked for it.
        var payload: [UInt8]
        var crc32: UInt32
        var size: Int64
        var digest: SKSHA256.Digest
    }

    /// `retaining` bounds the payload held in memory, so a lying header fails instead of
    /// allocating.
    private static func stream(_ member: RawMember,
                               descriptor: Int32,
                               retaining limit: Int? = nil) throws -> Streamed {
        var crc: UInt32 = 0
        var size: Int64 = 0
        var payload: [UInt8] = []
        var hasher = SKSHA256.Hasher()
        let inflater = member.header.method == SKZip.deflateMethod ? try SKZipInflater() : nil

        func consume(_ output: UnsafeBufferPointer<UInt8>) throws {
            size += Int64(output.count)
            if let limit, size > Int64(limit) {
                throw limitError("member payload exceeds the read limit")
            }
            crc = SKZipCompression.crc32(crc, UnsafeRawBufferPointer(output))
            hasher.update(output)
            if limit != nil { payload.append(contentsOf: output) }
        }

        var remaining = Int64(member.header.compressedBytes)
        var offset = member.dataOffset
        while remaining > 0 {
            let count = Int(min(Int64(SKZipWriter.chunkBytes), remaining))
            let chunk = try SKArchiveIO.readExactly(at: offset, count: count, from: descriptor)
            if let inflater {
                try chunk.withUnsafeBufferPointer { buffer in
                    _ = try inflater.process(buffer, finish: false, sink: consume)
                }
            } else {
                try chunk.withUnsafeBufferPointer { try consume($0) }
            }
            remaining -= Int64(count)
            offset += Int64(count)
        }
        if let inflater {
            let empty = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
            guard try inflater.process(empty, finish: true, sink: consume) else {
                throw SKZipLayoutError.inconsistent
            }
        }
        guard size == Int64(member.header.uncompressedBytes) else { throw invalid(member.path) }
        if member.header.method == SKZip.storedMethod, member.header.compressedBytes != size {
            throw invalid(member.path)
        }
        return Streamed(payload: payload, crc32: crc, size: size, digest: hasher.finalize())
    }

    /// One member as the central directory declares it, checked against its local header.
    private struct RawMember {
        var header: SKZipCentralHeader
        var path: String
        var isDirectory: Bool
        var dataOffset: Int64
        var size: Int64 { Int64(header.uncompressedBytes) }
        var compressedBytes: Int64 { Int64(header.compressedBytes) }
        var crc32: UInt32 { header.crc32 }
        var permissions: UInt16
        var localHeaderOffset: Int64 { Int64(header.localHeaderOffset) }
    }

    private static var hashLimits: SKJSONParser.Limits {
        var limits = SKJSONParser.Limits.default
        limits.maxBytes = SKResourceLimits.maxHashIndexBytes
        return limits
    }

    static func unsupported(_ reason: String) -> SKError {
        SKError(code: .archiveCorrupt, stage: "zipReader", reason: reason)
    }

    static func limitError(_ reason: String) -> SKError {
        SKError(code: .archiveLimitExceeded, stage: "zipReader", reason: reason)
    }

    static func invalid(_ path: String) -> SKError {
        SKError(code: .archiveCorrupt, stage: "zipReader", relativePath: path, reason: "member is inconsistent")
    }

    static func mismatch(_ path: String) -> SKError {
        SKError(code: .integrityHashMismatch,
                stage: "zipReader",
                relativePath: path,
                reason: "member does not match the hash index")
    }
}
