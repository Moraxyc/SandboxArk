#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Wire layout of the public SandboxArk/1 ZIP subset: APPNOTE 6.3.10 Stored/Deflate,
/// UTF-8 names, ZIP64 on overflow, no encryption, no data descriptors, no archive
/// comment. Writer and verifier share these definitions.
enum SKZip {
    static let localHeaderSignature: UInt32 = 0x0403_4B50
    static let centralHeaderSignature: UInt32 = 0x0201_4B50
    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4B50
    static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    static let zip64ExtraFieldID: UInt16 = 0x0001

    /// General-purpose bit 11: the member name is UTF-8.
    static let utf8NameFlag: UInt16 = 0x0800
    static let storedMethod: UInt16 = 0
    static let deflateMethod: UInt16 = 8

    static let versionNeededStoredOrDeflate: UInt16 = 20
    static let versionNeededZip64: UInt16 = 45
    /// Host system 3 (Unix) with spec version 3.0, and 4.5 for ZIP64 members.
    static let versionMadeByUnix: UInt16 = 0x031E
    static let versionMadeByUnixZip64: UInt16 = 0x032D

    static let localHeaderBytes = 30
    static let centralHeaderBytes = 46
    static let endOfCentralDirectoryBytes = 22
    static let zip64EndOfCentralDirectoryBytes = 56
    static let zip64LocatorBytes = 20

    static let maxUInt16: UInt64 = 0xFFFF
    static let maxUInt32: UInt64 = 0xFFFF_FFFF
    static let sentinel16: UInt16 = 0xFFFF
    static let sentinel32: UInt32 = 0xFFFF_FFFF

    /// Highest member count and offset the non-ZIP64 records can carry.
    static let maxClassicMemberCount = Int(maxUInt16)
    static let maxClassicOffset = Int64(maxUInt32)

    /// Sources at or above this size get a ZIP64 local extra field; the margin covers
    /// Deflate's worst-case expansion, so smaller members cannot overflow 32 bits.
    static let zip64LocalHeaderThreshold: Int64 = Int64(maxUInt32) - 1_048_576

    /// External attributes: Unix mode in the high half, the DOS directory bit in the low.
    static let msdosDirectoryAttribute: UInt32 = 0x10

    static func externalAttributes(isDirectory: Bool, permissions: UInt16) -> UInt32 {
        let type: UInt32 = isDirectory ? 0o040000 : 0o100000
        let mode = type | UInt32(permissions & 0o777)
        return mode << 16 | (isDirectory ? msdosDirectoryAttribute : 0)
    }
}

/// Member-path rules of the SandboxArk/1 profile, run by writer and reader alike: no
/// absolute or `.`/`..` components, backslashes, controls, or space/dot endings; one
/// trailing slash at most, and only on a directory.
enum SKArchivePath {
    /// A member name keeps the trailing slash for directories; an index path never does.
    enum Form {
        case member
        case index
    }

    static func validate(_ path: String, isDirectory: Bool, form: Form = .member) throws {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty else { throw invalid("member path is empty") }
        guard bytes.count <= SKResourceLimits.maxArchivePathBytes else {
            throw invalid("member path exceeds \(SKResourceLimits.maxArchivePathBytes) bytes")
        }
        guard bytes[0] != 0x2F else { throw invalid("member path is absolute") }
        guard !bytes.contains(0x5C) else { throw invalid("member path contains a backslash") }

        var name = bytes
        switch (form, isDirectory) {
        case (.member, true):
            guard bytes.last == 0x2F else { throw invalid("directory member has no trailing slash") }
            name = Array(bytes.dropLast())
            guard !name.isEmpty else { throw invalid("directory member is the container root") }
        case (.index, true):
            guard bytes.last != 0x2F else { throw invalid("directory index path carries a trailing slash") }
        case (_, false):
            guard bytes.last != 0x2F else { throw invalid("file path ends in a slash") }
        }

        var start = 0
        for index in 0...name.count {
            let isBoundary = index == name.count || name[index] == 0x2F
            guard isBoundary else { continue }
            try validate(component: name[start..<index])
            start = index + 1
        }
    }

    private static func validate(component: ArraySlice<UInt8>) throws {
        guard !component.isEmpty else { throw invalid("member path has an empty component") }
        guard component.count <= SKResourceLimits.maxScanPathComponentBytes else {
            throw invalid("member path component exceeds \(SKResourceLimits.maxScanPathComponentBytes) bytes")
        }
        if component.count == 1, component.first == 0x2E { throw invalid("member path has a dot component") }
        if component.count == 2, component.first == 0x2E, component.last == 0x2E {
            throw invalid("member path has a parent component")
        }
        for byte in component {
            switch byte {
            case 0x00...0x1F, 0x7F: throw invalid("member path component contains a control character")
            default: break
            }
        }
        guard let last = component.last, last != 0x20, last != 0x2E else {
            throw invalid("member path component ends in a space or a dot")
        }
    }

    /// Whitelist: the two control members and the two data namespaces, nothing else.
    static func authorized(_ path: String, isDirectory: Bool) throws {
        if !isDirectory, path == SKManifest.manifestPath || path == SKManifest.hashIndexPath { return }
        if isDirectory {
            let namespace = path.hasSuffix("/") ? String(path.dropLast()) : path
            if namespace == "data" || namespace == SKManifest.homeRoot
                || namespace == SKManifest.appGroupsRoot {
                return
            }
        }
        if path.hasPrefix(SKManifest.homeRoot + "/") || path.hasPrefix(SKManifest.appGroupsRoot + "/") {
            return
        }
        throw invalid("member path is outside the archive's namespaces")
    }

    /// A path inside SandboxArk's own state never enters or leaves an archive.
    static func checkNotReserved(_ path: String) throws {
        guard path.hasPrefix(SKManifest.homeRoot + "/") else { return }
        let homeRelative = String(path.dropFirst(SKManifest.homeRoot.utf8.count + 1))
        guard !SKReservedPaths.isReserved(homeRelativePath: homeRelative) else {
            throw invalid("member path is SandboxArk's own state")
        }
    }

    private static func invalid(_ reason: String) -> SKError {
        SKError(code: .archivePathTraversal, stage: "memberPath", reason: reason)
    }
}

/// Little-endian emitter for the fixed-layout records below.
struct SKByteWriter {
    private(set) var bytes: [UInt8] = []

    var count: Int { bytes.count }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func u32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func u64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func append(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    mutating func append(_ value: String) {
        bytes.append(contentsOf: value.utf8)
    }

    /// Fills a field the caller has not computed yet, keeping the record length fixed.
    mutating func pad(_ count: Int) {
        bytes.append(contentsOf: [UInt8](repeating: 0, count: count))
    }
}

/// Bounds-checked reader for the same records; every accessor throws instead of
/// trapping, because the input is an untrusted archive.
struct SKByteReader {
    let bytes: [UInt8]
    private(set) var offset = 0

    var remaining: Int { bytes.count - offset }

    mutating func u16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    mutating func u64() throws -> UInt64 {
        try require(8)
        defer { offset += 8 }
        var result: UInt64 = 0
        for index in stride(from: offset + 7, through: offset, by: -1) {
            result = result << 8 | UInt64(bytes[index])
        }
        return result
    }

    /// Field bytes are copied out, not sliced: a slice carries absolute indices, so
    /// `value[0]` would trap whenever the field starts later in the record.
    mutating func take(_ count: Int) throws -> [UInt8] {
        try require(count)
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    mutating func extraField() throws -> (id: UInt16, payload: [UInt8]) {
        let id = try u16()
        let size = Int(try u16())
        return (id, try take(size))
    }

    private func require(_ count: Int) throws {
        guard count >= 0, remaining >= count else {
            throw SKZipLayoutError.truncated
        }
    }
}

enum SKZipLayoutError {
    static let truncated = SKError(code: .archiveCorrupt, stage: "zipLayout", reason: "record is truncated")
    static let inconsistent = SKError(code: .archiveCorrupt, stage: "zipLayout", reason: "record is inconsistent")
}

/// The ZIP64 extra field for one record. APPNOTE 4.5.3 fixes the payload order —
/// uncompressed size, compressed size, local header offset — with a field present only
/// where the 32-bit slot holds the sentinel.
struct SKZip64Extra: Equatable {
    var uncompressedBytes: UInt64?
    var compressedBytes: UInt64?
    var localHeaderOffset: UInt64?

    init(uncompressedBytes: UInt64? = nil,
         compressedBytes: UInt64? = nil,
         localHeaderOffset: UInt64? = nil) {
        self.uncompressedBytes = uncompressedBytes
        self.compressedBytes = compressedBytes
        self.localHeaderOffset = localHeaderOffset
    }

    var payloadBytes: Int {
        let sized = (uncompressedBytes == nil ? 0 : 1) + (compressedBytes == nil ? 0 : 1)
        return 8 * (sized + (localHeaderOffset == nil ? 0 : 1))
    }

    /// A record with nothing to declare writes no field: a zero-length entry is malformed.
    var recordBytes: Int { payloadBytes == 0 ? 0 : 4 + payloadBytes }

    func encoded() -> [UInt8] {
        guard payloadBytes > 0 else { return [] }
        var writer = SKByteWriter()
        writer.u16(SKZip.zip64ExtraFieldID)
        writer.u16(UInt16(payloadBytes))
        if let value = uncompressedBytes { writer.u64(value) }
        if let value = compressedBytes { writer.u64(value) }
        if let value = localHeaderOffset { writer.u64(value) }
        return writer.bytes
    }

    /// Resolves one record's extra-field area. `needsSizes`/`needsOffset` mirror the
    /// record's sentinels and say which fields must be present; other identifiers are
    /// skipped because this profile interprets nothing else.
    static func resolve(extra: [UInt8],
                        needsSizes: Bool,
                        needsOffset: Bool) throws -> SKZip64Extra {
        var reader = SKByteReader(bytes: extra)
        var resolved = SKZip64Extra()
        var found = false
        while reader.remaining > 0 {
            let field = try reader.extraField()
            guard field.id == SKZip.zip64ExtraFieldID else { continue }
            guard !found else { throw SKZipLayoutError.inconsistent }
            found = true
            var payload = SKByteReader(bytes: field.payload)
            if needsSizes {
                resolved.uncompressedBytes = try payload.u64()
                resolved.compressedBytes = try payload.u64()
            }
            if needsOffset { resolved.localHeaderOffset = try payload.u64() }
            guard payload.remaining == 0 else { throw SKZipLayoutError.inconsistent }
        }
        guard found || !needsSizes && !needsOffset else { throw SKZipLayoutError.inconsistent }
        return resolved
    }
}

/// A member's local file header plus the name and extra field that follow it in the
/// stream. A ZIP64 member keeps both sizes in the extra field, so backfilling is fixed-width.
struct SKZipLocalHeader: Equatable {
    var versionNeeded: UInt16
    var flags: UInt16
    var method: UInt16
    var dosTime: UInt16
    var dosDate: UInt16
    var crc32: UInt32
    var compressedBytes: UInt64
    var uncompressedBytes: UInt64
    var name: [UInt8]
    var zip64: Bool

    var zip64Extra: SKZip64Extra {
        zip64
            ? SKZip64Extra(uncompressedBytes: uncompressedBytes, compressedBytes: compressedBytes)
            : SKZip64Extra()
    }

    var recordBytes: Int { SKZip.localHeaderBytes + name.count + zip64Extra.recordBytes }

    func encoded() -> [UInt8] {
        var writer = SKByteWriter()
        writer.u32(SKZip.localHeaderSignature)
        writer.u16(zip64 ? SKZip.versionNeededZip64 : versionNeeded)
        writer.u16(flags)
        writer.u16(method)
        writer.u16(dosTime)
        writer.u16(dosDate)
        writer.u32(crc32)
        writer.u32(zip64 ? SKZip.sentinel32 : UInt32(truncatingIfNeeded: compressedBytes))
        writer.u32(zip64 ? SKZip.sentinel32 : UInt32(truncatingIfNeeded: uncompressedBytes))
        writer.u16(UInt16(name.count))
        writer.u16(UInt16(zip64Extra.recordBytes))
        writer.append(name)
        writer.append(zip64Extra.encoded())
        return writer.bytes
    }

    static func parse(_ reader: inout SKByteReader) throws -> SKZipLocalHeader {
        guard try reader.u32() == SKZip.localHeaderSignature else { throw SKZipLayoutError.inconsistent }
        let versionNeeded = try reader.u16()
        let flags = try reader.u16()
        let method = try reader.u16()
        let dosTime = try reader.u16()
        let dosDate = try reader.u16()
        let crc32 = try reader.u32()
        let compressedSlot = try reader.u32()
        let uncompressedSlot = try reader.u32()
        let nameBytes = Int(try reader.u16())
        let extraBytes = Int(try reader.u16())
        guard nameBytes > 0, nameBytes <= SKResourceLimits.maxArchivePathBytes else {
            throw SKZipLayoutError.inconsistent
        }
        let name = try reader.take(nameBytes)
        let extra = try reader.take(extraBytes)

        let zip64 = compressedSlot == SKZip.sentinel32 || uncompressedSlot == SKZip.sentinel32
        let resolved = try SKZip64Extra.resolve(extra: extra, needsSizes: zip64, needsOffset: false)
        let compressedBytes: UInt64
        let uncompressedBytes: UInt64
        if zip64 {
            guard let compressed = resolved.compressedBytes,
                  let uncompressed = resolved.uncompressedBytes else {
                throw SKZipLayoutError.inconsistent
            }
            compressedBytes = compressed
            uncompressedBytes = uncompressed
        } else {
            compressedBytes = UInt64(compressedSlot)
            uncompressedBytes = UInt64(uncompressedSlot)
        }
        return SKZipLocalHeader(versionNeeded: versionNeeded,
                                flags: flags,
                                method: method,
                                dosTime: dosTime,
                                dosDate: dosDate,
                                crc32: crc32,
                                compressedBytes: compressedBytes,
                                uncompressedBytes: uncompressedBytes,
                                name: name,
                                zip64: zip64)
    }
}

struct SKZipCentralHeader: Equatable {
    var versionMadeBy: UInt16
    var versionNeeded: UInt16
    var flags: UInt16
    var method: UInt16
    var dosTime: UInt16
    var dosDate: UInt16
    var crc32: UInt32
    var compressedBytes: UInt64
    var uncompressedBytes: UInt64
    var name: [UInt8]
    var externalAttributes: UInt32
    var localHeaderOffset: UInt64
    var zip64: Bool

    var zip64Extra: SKZip64Extra {
        guard zip64 else { return SKZip64Extra() }
        return SKZip64Extra(uncompressedBytes: uncompressedBytes,
                            compressedBytes: compressedBytes,
                            localHeaderOffset: localHeaderOffset)
    }

    var recordBytes: Int { SKZip.centralHeaderBytes + name.count + zip64Extra.recordBytes }

    func encoded() -> [UInt8] {
        var writer = SKByteWriter()
        writer.u32(SKZip.centralHeaderSignature)
        writer.u16(zip64 ? SKZip.versionMadeByUnixZip64 : versionMadeBy)
        writer.u16(zip64 ? SKZip.versionNeededZip64 : versionNeeded)
        writer.u16(flags)
        writer.u16(method)
        writer.u16(dosTime)
        writer.u16(dosDate)
        writer.u32(crc32)
        writer.u32(zip64 ? SKZip.sentinel32 : UInt32(truncatingIfNeeded: compressedBytes))
        writer.u32(zip64 ? SKZip.sentinel32 : UInt32(truncatingIfNeeded: uncompressedBytes))
        writer.u16(UInt16(name.count))
        writer.u16(UInt16(zip64Extra.recordBytes))
        writer.u16(0)  // no per-member comment
        writer.u16(0)  // single-disk archive
        writer.u16(0)  // no internal attributes
        writer.u32(externalAttributes)
        writer.u32(zip64 ? SKZip.sentinel32 : UInt32(truncatingIfNeeded: localHeaderOffset))
        writer.append(name)
        writer.append(zip64Extra.encoded())
        return writer.bytes
    }

    static func parse(_ reader: inout SKByteReader) throws -> SKZipCentralHeader {
        guard try reader.u32() == SKZip.centralHeaderSignature else { throw SKZipLayoutError.inconsistent }
        let versionMadeBy = try reader.u16()
        let versionNeeded = try reader.u16()
        let flags = try reader.u16()
        let method = try reader.u16()
        let dosTime = try reader.u16()
        let dosDate = try reader.u16()
        let crc32 = try reader.u32()
        let compressedSlot = try reader.u32()
        let uncompressedSlot = try reader.u32()
        let nameBytes = Int(try reader.u16())
        let extraBytes = Int(try reader.u16())
        let commentBytes = Int(try reader.u16())
        let diskStart = try reader.u16()
        let internalAttributes = try reader.u16()
        let externalAttributes = try reader.u32()
        let offsetSlot = try reader.u32()
        guard nameBytes > 0, nameBytes <= SKResourceLimits.maxArchivePathBytes,
              commentBytes == 0, diskStart == 0, internalAttributes == 0 else {
            throw SKZipLayoutError.inconsistent
        }
        let name = try reader.take(nameBytes)
        let extra = try reader.take(extraBytes)

        let zip64 = compressedSlot == SKZip.sentinel32 || uncompressedSlot == SKZip.sentinel32
            || offsetSlot == SKZip.sentinel32
        let resolved = try SKZip64Extra.resolve(extra: extra,
                                                needsSizes: compressedSlot == SKZip.sentinel32
                                                    || uncompressedSlot == SKZip.sentinel32,
                                                needsOffset: offsetSlot == SKZip.sentinel32)
        let compressedBytes: UInt64
        let uncompressedBytes: UInt64
        let localHeaderOffset: UInt64
        if compressedSlot == SKZip.sentinel32 || uncompressedSlot == SKZip.sentinel32 {
            guard let compressed = resolved.compressedBytes,
                  let uncompressed = resolved.uncompressedBytes else {
                throw SKZipLayoutError.inconsistent
            }
            compressedBytes = compressed
            uncompressedBytes = uncompressed
        } else {
            compressedBytes = UInt64(compressedSlot)
            uncompressedBytes = UInt64(uncompressedSlot)
        }
        if offsetSlot == SKZip.sentinel32 {
            guard let offset = resolved.localHeaderOffset else { throw SKZipLayoutError.inconsistent }
            localHeaderOffset = offset
        } else {
            localHeaderOffset = UInt64(offsetSlot)
        }
        return SKZipCentralHeader(versionMadeBy: versionMadeBy,
                                  versionNeeded: versionNeeded,
                                  flags: flags,
                                  method: method,
                                  dosTime: dosTime,
                                  dosDate: dosDate,
                                  crc32: crc32,
                                  compressedBytes: compressedBytes,
                                  uncompressedBytes: uncompressedBytes,
                                  name: name,
                                  externalAttributes: externalAttributes,
                                  localHeaderOffset: localHeaderOffset,
                                  zip64: zip64)
    }
}

/// The classic end record, written with sentinels in whichever fields overflowed.
struct SKZipEndOfCentralDirectory: Equatable {
    var memberCount: UInt16
    var centralDirectoryBytes: UInt32
    var centralDirectoryOffset: UInt32

    func encoded() -> [UInt8] {
        var writer = SKByteWriter()
        writer.u32(SKZip.endOfCentralDirectorySignature)
        writer.u16(0)
        writer.u16(0)
        writer.u16(memberCount)
        writer.u16(memberCount)
        writer.u32(centralDirectoryBytes)
        writer.u32(centralDirectoryOffset)
        writer.u16(0)
        return writer.bytes
    }
}

/// The ZIP64 end record, which carries the values the classic record could not.
struct SKZip64EndOfCentralDirectory: Equatable {
    var memberCount: UInt64
    var centralDirectoryBytes: UInt64
    var centralDirectoryOffset: UInt64

    /// The record body the size field announces: everything after the 12-byte prologue.
    static let bodyBytes = SKZip.zip64EndOfCentralDirectoryBytes - 12

    func encoded() -> [UInt8] {
        var writer = SKByteWriter()
        writer.u32(SKZip.zip64EndOfCentralDirectorySignature)
        writer.u64(UInt64(SKZip64EndOfCentralDirectory.bodyBytes))
        writer.u16(SKZip.versionMadeByUnixZip64)
        writer.u16(SKZip.versionNeededZip64)
        writer.u32(0)
        writer.u32(0)
        writer.u64(memberCount)
        writer.u64(memberCount)
        writer.u64(centralDirectoryBytes)
        writer.u64(centralDirectoryOffset)
        return writer.bytes
    }
}

/// The ZIP64 locator, which has to sit between the ZIP64 end record and the classic one.
struct SKZip64Locator: Equatable {
    var zip64EndOfCentralDirectoryOffset: UInt64

    func encoded() -> [UInt8] {
        var writer = SKByteWriter()
        writer.u32(SKZip.zip64LocatorSignature)
        writer.u32(0)
        writer.u64(zip64EndOfCentralDirectoryOffset)
        writer.u32(1)
        return writer.bytes
    }
}

/// The end records of one archive. SandboxArk/1 has no archive comment, so the classic
/// record must be exactly the last 22 bytes, with any ZIP64 records immediately before
/// it; anything else is a different archive shape, not a variant to guess at.
struct SKZipTrailer: Equatable {
    var memberCount: UInt64
    var centralDirectoryBytes: UInt64
    var centralDirectoryOffset: UInt64
    var isZip64: Bool
    /// Absolute file offset of the classic end record, which the last 22 bytes always are.
    var endOfCentralDirectoryOffset: Int64
    /// Absolute file offset of the ZIP64 end record, present only when `isZip64`.
    var zip64EndOfCentralDirectoryOffset: Int64?

    /// First byte after the central directory: the ZIP64 end record when there is one.
    var centralDirectoryEnd: Int64 {
        zip64EndOfCentralDirectoryOffset ?? endOfCentralDirectoryOffset
    }

    static func parse(tail: [UInt8], fileBytes: Int64) throws -> SKZipTrailer {
        let classicBytes = SKZip.endOfCentralDirectoryBytes
        guard fileBytes >= Int64(classicBytes), tail.count >= classicBytes,
              tail.count <= fileBytes else {
            throw SKZipLayoutError.truncated
        }
        var reader = SKByteReader(bytes: Array(tail.suffix(classicBytes)))
        guard try reader.u32() == SKZip.endOfCentralDirectorySignature else {
            throw SKZipLayoutError.inconsistent
        }
        guard try reader.u16() == 0, try reader.u16() == 0 else { throw SKZipLayoutError.inconsistent }
        let entriesOnDisk = try reader.u16()
        let totalEntries = try reader.u16()
        let centralBytes = try reader.u32()
        let centralOffset = try reader.u32()
        guard try reader.u16() == 0, entriesOnDisk == totalEntries else {
            throw SKZipLayoutError.inconsistent
        }

        let tailStart = fileBytes - Int64(tail.count)
        let classicOffset = fileBytes - Int64(classicBytes)
        let isZip64 = entriesOnDisk == SKZip.sentinel16 || centralBytes == SKZip.sentinel32
            || centralOffset == SKZip.sentinel32
        guard isZip64 else {
            return SKZipTrailer(memberCount: UInt64(totalEntries),
                                centralDirectoryBytes: UInt64(centralBytes),
                                centralDirectoryOffset: UInt64(centralOffset),
                                isZip64: false,
                                endOfCentralDirectoryOffset: classicOffset,
                                zip64EndOfCentralDirectoryOffset: nil)
        }

        let locatorOffset = classicOffset - Int64(SKZip.zip64LocatorBytes)
        guard locatorOffset >= tailStart else { throw SKZipLayoutError.truncated }
        let locatorIndex = Int(locatorOffset - tailStart)
        var locatorReader = SKByteReader(bytes: Array(tail[locatorIndex..<(locatorIndex + SKZip.zip64LocatorBytes)]))
        guard try locatorReader.u32() == SKZip.zip64LocatorSignature,
              try locatorReader.u32() == 0 else {
            throw SKZipLayoutError.inconsistent
        }
        let recordOffset = try locatorReader.u64()
        guard try locatorReader.u32() == 1 else { throw SKZipLayoutError.inconsistent }

        guard recordOffset >= UInt64(tailStart), recordOffset <= UInt64(locatorOffset) else {
            throw SKZipLayoutError.truncated
        }
        guard recordOffset + UInt64(SKZip.zip64EndOfCentralDirectoryBytes) <= UInt64(locatorOffset) else {
            throw SKZipLayoutError.inconsistent
        }
        var recordReader = SKByteReader(bytes: Array(tail[Int(recordOffset - UInt64(tailStart))...]))
        guard try recordReader.u32() == SKZip.zip64EndOfCentralDirectorySignature,
              try recordReader.u64() == UInt64(SKZip64EndOfCentralDirectory.bodyBytes) else {
            throw SKZipLayoutError.inconsistent
        }
        _ = try recordReader.u16()  // version made by
        _ = try recordReader.u16()  // version needed
        guard try recordReader.u32() == 0, try recordReader.u32() == 0 else {
            throw SKZipLayoutError.inconsistent
        }
        let membersOnDisk = try recordReader.u64()
        let members = try recordReader.u64()
        let centralDirectoryBytes = try recordReader.u64()
        let centralDirectoryOffset = try recordReader.u64()
        guard membersOnDisk == members else { throw SKZipLayoutError.inconsistent }
        return SKZipTrailer(memberCount: members,
                            centralDirectoryBytes: centralDirectoryBytes,
                            centralDirectoryOffset: centralDirectoryOffset,
                            isZip64: true,
                            endOfCentralDirectoryOffset: classicOffset,
                            zip64EndOfCentralDirectoryOffset: Int64(recordOffset))
    }
}

/// Descriptor-level I/O for the archive layer. Both writer and verifier work on a
/// caller-opened descriptor, never a path, and use `pread`/`pwrite` because a local
/// header is backfilled after the member data that follows it.
enum SKArchiveIO {
    static func createExclusive(name: String, in directory: Int32) throws -> Int32 {
        let descriptor = name.withCString {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw error(errno, operation: "create") }
        return descriptor
    }

    static func openReadOnly(name: String, in directory: Int32) throws -> Int32 {
        let descriptor = name.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw error(errno, operation: "open") }
        return descriptor
    }

    static func size(of descriptor: Int32) throws -> Int64 {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw error(errno, operation: "stat") }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw error(EINVAL, operation: "stat") }
        return Int64(status.st_size)
    }

    /// Every write names its offset: `pwrite` does not advance a position, so a caller
    /// cannot forget the offset and silently overwrite an earlier member.
    static func write(_ bytes: [UInt8], at offset: Int64, to descriptor: Int32) throws {
        try bytes.withUnsafeBufferPointer { try write($0, at: offset, to: descriptor) }
    }

    static func write(_ bytes: ArraySlice<UInt8>, at offset: Int64, to descriptor: Int32) throws {
        try bytes.withUnsafeBufferPointer { try write($0, at: offset, to: descriptor) }
    }

    /// Backfilling uses this form too; the length must match what the placeholder
    /// reserved, which keeps the following member offsets valid.
    static func write(_ bytes: UnsafeBufferPointer<UInt8>,
                      at offset: Int64,
                      to descriptor: Int32) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        var written = 0
        while written < bytes.count {
            let count = pwrite(descriptor, base + written, bytes.count - written, off_t(offset) + off_t(written))
            if count > 0 {
                written += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            throw error(count < 0 ? errno : EIO, operation: "write")
        }
    }

    /// Reads up to `count` bytes, returning fewer only at end of file.
    static func read(at offset: Int64, count: Int, from descriptor: Int32) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: count)
        var readBytes = 0
        while readBytes < count {
            let result = buffer.withUnsafeMutableBytes { raw -> Int in
                pread(descriptor, raw.baseAddress! + readBytes, count - readBytes, off_t(offset) + off_t(readBytes))
            }
            if result > 0 {
                readBytes += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result < 0 { throw error(errno, operation: "read") }
            break
        }
        return Array(buffer[0..<readBytes])
    }

    /// Reads the next sequential chunk into `buffer`, returning the byte count; zero
    /// means EOF. The writer owns the buffer size, so member memory cost stays fixed.
    static func readChunk(from descriptor: Int32, into buffer: inout [UInt8]) throws -> Int {
        guard !buffer.isEmpty else { return 0 }
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                posixRead(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 { return count }
            if count == 0 { return 0 }
            if errno == EINTR { continue }
            throw error(errno, operation: "read")
        }
    }

    static func readExactly(at offset: Int64, count: Int, from descriptor: Int32) throws -> [UInt8] {
        let bytes = try read(at: offset, count: count, from: descriptor)
        guard bytes.count == count else { throw SKZipLayoutError.truncated }
        return bytes
    }

    static func sync(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else { throw error(errno, operation: "sync") }
    }

    static func close(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        _ = closeDescriptor(descriptor)
    }

    private static func posixRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(descriptor, buffer, count)
        #else
        Glibc.read(descriptor, buffer, count)
        #endif
    }

    private static func closeDescriptor(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(descriptor)
        #else
        Glibc.close(descriptor)
        #endif
    }

    private static func error(_ code: Int32, operation: String) -> SKError {
        SKError(code: .storageDurabilityFailure,
                stage: "archiveIO",
                relativePath: nil,
                retryable: true,
                underlyingCode: code,
                reason: "\(operation) failed")
    }
}
