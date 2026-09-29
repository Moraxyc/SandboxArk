/// Typed view of `manifest.json` and `hashes.json`, carrying the rules JSON Schema cannot
/// express: required fields, enum membership, byte caps, integer ranges and cross-document
/// constraints. The ZIP reader adds member-set correspondence.
struct SKManifestDocument: Equatable, Sendable {
    enum Platform: String, Sendable {
        case iOS, iPadOS
    }

    enum Kind: String, Sendable {
        case user
        case preRestoreRecoveryPoint = "pre-restore-recovery-point"
    }

    enum Mode: String, Sendable {
        case standard
        case fullSandbox = "full-sandbox"
    }

    enum Completeness: String, Sendable {
        case complete, partial
    }

    enum ScopeType: String, Sendable {
        case home, appGroup
    }

    struct App: Equatable, Sendable {
        var bundleIdentifier: String
        var displayName: String?
        var shortVersion: String?
        var bundleVersion: String?
    }

    struct Environment: Equatable, Sendable {
        var platform: Platform
        var osVersion: String
        var deviceModel: String
    }

    struct Backup: Equatable, Sendable {
        var createdAt: String
        var kind: Kind
        var mode: Mode
        var completeness: Completeness
        var totalFiles: Int
        var totalBytes: Int64
        var warningCount: Int
        /// Fixed by the format: ordinary file reads cannot freeze a running app.
        var preferencesConsistency = "best-effort"
    }

    struct Root: Equatable, Sendable {
        var scopeType: ScopeType
        var relativeRoot: String
        var archivePrefix: String
        var complete: Bool
        var mirrorSafe: Bool
        var includedFiles: Int
        var includedBytes: Int64
        var unreadableCount: Int
        var excludedCounts: [String: Int]
    }

    struct AppGroup: Equatable, Sendable {
        var groupIdentifier: String
        var archivePrefix: String
        var entitlementMatchAtBackup: Bool
    }

    var app: App
    var environment: Environment
    var backup: Backup
    var roots: [Root]
    /// Passed through verbatim: the SQLite group shape is owned by the format, and the
    /// container only has to carry it without reinterpreting it.
    var sqliteGroups: [SKJSONValue]
    var appGroups: [AppGroup]

    // MARK: - Encoding

    func jsonValue() -> SKJSONValue {
        var appMembers: [(String, SKJSONValue)] = [("bundleIdentifier", .string(app.bundleIdentifier))]
        if let displayName = app.displayName { appMembers.append(("displayName", .string(displayName))) }
        if let shortVersion = app.shortVersion { appMembers.append(("shortVersion", .string(shortVersion))) }
        if let bundleVersion = app.bundleVersion { appMembers.append(("bundleVersion", .string(bundleVersion))) }
        return .object([
            ("format", .string(SKManifest.format)),
            ("formatVersion", .integer(Int64(SKManifest.formatVersion))),
            ("app", .object(appMembers)),
            ("environment", .object([
                ("platform", .string(environment.platform.rawValue)),
                ("osVersion", .string(environment.osVersion)),
                ("deviceModel", .string(environment.deviceModel)),
            ])),
            ("backup", .object([
                ("createdAt", .string(backup.createdAt)),
                ("kind", .string(backup.kind.rawValue)),
                ("mode", .string(backup.mode.rawValue)),
                ("completeness", .string(backup.completeness.rawValue)),
                ("totalFiles", .integer(Int64(backup.totalFiles))),
                ("totalBytes", .integer(backup.totalBytes)),
                ("preferencesConsistency", .string(backup.preferencesConsistency)),
                ("warningCount", .integer(Int64(backup.warningCount))),
            ])),
            ("contents", .object([
                ("roots", .array(roots.map(\.jsonValue))),
                ("hashIndexPath", .string(SKManifest.hashIndexPath)),
                ("consistency", .object([("sqliteGroups", .array(sqliteGroups))])),
                ("appGroups", .array(appGroups.map(\.jsonValue))),
            ])),
        ])
    }

    // MARK: - Decoding

    static func decode(_ value: SKJSONValue) throws -> SKManifestDocument {
        try SKBackupFormatReaderV1.checkIdentity(value)
        let root = try SKJSONObjectReader(value, label: "manifest")

        let appObject = try SKJSONObjectReader(try root.value("app"), label: "app")
        let app = App(bundleIdentifier: try appObject.string("bundleIdentifier", maxBytes: 255),
                      displayName: try appObject.optionalString("displayName", maxBytes: 255),
                      shortVersion: try appObject.optionalString("shortVersion", maxBytes: 128),
                      bundleVersion: try appObject.optionalString("bundleVersion", maxBytes: 128))

        let environmentObject = try SKJSONObjectReader(try root.value("environment"), label: "environment")
        guard let platform = Platform(rawValue: try environmentObject.string("platform", maxBytes: 16)) else {
            throw SKManifestDocument.malformed("unknown platform")
        }
        let environment = Environment(platform: platform,
                                      osVersion: try environmentObject.string("osVersion", maxBytes: 128),
                                      deviceModel: try environmentObject.string("deviceModel", maxBytes: 128))

        let backupObject = try SKJSONObjectReader(try root.value("backup"), label: "backup")
        let createdAt = try backupObject.string("createdAt", maxBytes: 64)
        guard SKRFC3339.seconds(of: createdAt) != nil else {
            throw SKManifestDocument.malformed("createdAt is not an RFC 3339 date-time")
        }
        guard let kind = Kind(rawValue: try backupObject.string("kind", maxBytes: 32)) else {
            throw SKManifestDocument.malformed("unknown backup kind")
        }
        guard let mode = Mode(rawValue: try backupObject.string("mode", maxBytes: 32)) else {
            throw SKManifestDocument.malformed("unknown backup mode")
        }
        guard let completeness = Completeness(rawValue: try backupObject.string("completeness", maxBytes: 16)) else {
            throw SKManifestDocument.malformed("unknown completeness")
        }
        let totalFiles = try backupObject.integer("totalFiles", max: Int64(SKResourceLimits.maxArchiveMembers))
        let totalBytes = try backupObject.integer("totalBytes")
        let warningCount = try backupObject.integer("warningCount")
        guard try backupObject.string("preferencesConsistency", maxBytes: 16) == "best-effort" else {
            throw SKManifestDocument.malformed("preferencesConsistency is not best-effort")
        }
        let backup = Backup(createdAt: createdAt, kind: kind, mode: mode, completeness: completeness,
                            totalFiles: Int(totalFiles), totalBytes: totalBytes, warningCount: Int(warningCount))

        let contentsObject = try SKJSONObjectReader(try root.value("contents"), label: "contents")
        guard try contentsObject.string("hashIndexPath", maxBytes: 64) == SKManifest.hashIndexPath else {
            throw SKManifestDocument.malformed("hashIndexPath is not the format's index name")
        }
        let roots = try contentsObject.array("roots", maxItems: SKResourceLimits.maxArchiveMembers)
            .map(SKManifestDocument.decodeRoot)
        let consistencyObject = try SKJSONObjectReader(try contentsObject.value("consistency"), label: "consistency")
        let sqliteGroups = try consistencyObject.array("sqliteGroups", maxItems: SKResourceLimits.maxArchiveMembers)
        let appGroups = try contentsObject.array("appGroups", maxItems: SKResourceLimits.maxArchiveMembers)
            .map(SKManifestDocument.decodeAppGroup)

        return SKManifestDocument(app: app, environment: environment, backup: backup,
                                  roots: roots, sqliteGroups: sqliteGroups, appGroups: appGroups)
    }

    private static func decodeRoot(_ value: SKJSONValue) throws -> Root {
        let object = try SKJSONObjectReader(value, label: "contents.roots[]")
        guard let scopeType = ScopeType(rawValue: try object.string("scopeType", maxBytes: 16)) else {
            throw malformed("unknown scopeType")
        }
        let relativeRoot = try object.string("relativeRoot", maxBytes: SKResourceLimits.maxArchivePathBytes)
        let archivePrefix = try object.string("archivePrefix", maxBytes: SKResourceLimits.maxArchivePathBytes)
        let includedFiles = try object.integer("includedFiles", max: Int64(SKResourceLimits.maxArchiveMembers))
        let includedBytes = try object.integer("includedBytes")
        let unreadableCount = try object.integer("unreadableCount")
        let countsObject = try SKJSONObjectReader(try object.value("excludedCounts"), label: "excludedCounts")
        var excludedCounts: [String: Int] = [:]
        for member in countsObject.members {
            guard let count = member.value.integerValue, count >= 0 else {
                throw malformed("excludedCounts value is not a count")
            }
            excludedCounts[member.name] = Int(count)
        }
        return Root(scopeType: scopeType, relativeRoot: relativeRoot, archivePrefix: archivePrefix,
                    complete: try object.boolean("complete"), mirrorSafe: try object.boolean("mirrorSafe"),
                    includedFiles: Int(includedFiles), includedBytes: includedBytes,
                    unreadableCount: Int(unreadableCount), excludedCounts: excludedCounts)
    }

    private static func decodeAppGroup(_ value: SKJSONValue) throws -> AppGroup {
        let object = try SKJSONObjectReader(value, label: "contents.appGroups[]")
        return AppGroup(groupIdentifier: try object.string("groupIdentifier", maxBytes: 255),
                        archivePrefix: try object.string("archivePrefix", maxBytes: SKResourceLimits.maxArchivePathBytes),
                        entitlementMatchAtBackup: try object.boolean("entitlementMatchAtBackup"))
    }

    static func malformed(_ reason: String) -> SKError {
        SKError(code: .integrityManifestInvalid, stage: "manifest", reason: reason)
    }
}

extension SKManifestDocument.Root {
    var jsonValue: SKJSONValue {
        .object([
            ("scopeType", .string(scopeType.rawValue)),
            ("relativeRoot", .string(relativeRoot)),
            ("archivePrefix", .string(archivePrefix)),
            ("complete", .boolean(complete)),
            ("mirrorSafe", .boolean(mirrorSafe)),
            ("includedFiles", .integer(Int64(includedFiles))),
            ("includedBytes", .integer(includedBytes)),
            ("unreadableCount", .integer(Int64(unreadableCount))),
            ("excludedCounts", .object(excludedCounts.keys.sorted().map { ($0, .integer(Int64(excludedCounts[$0]!))) })),
        ])
    }
}

extension SKManifestDocument.AppGroup {
    var jsonValue: SKJSONValue {
        .object([
            ("groupIdentifier", .string(groupIdentifier)),
            ("archivePrefix", .string(archivePrefix)),
            ("entitlementMatchAtBackup", .boolean(entitlementMatchAtBackup)),
        ])
    }
}

/// `hashes.json`: one SHA-256 per archived regular file, plus an entry per directory
/// member. The index covers `manifest.json` and never itself.
struct SKHashIndexDocument: Equatable, Sendable {
    enum Kind: String, Sendable {
        case regular, directory
    }

    struct Entry: Equatable, Sendable {
        var path: String
        var kind: Kind
        var size: Int64
        var sha256: SKSHA256.Digest?
        var modifiedAt: String?
        /// POSIX permission bits; absent when the source did not expose a usable mode.
        var mode: UInt16?
    }

    static let format = "SandboxArkHashIndex"
    static let indexVersion = 1
    static let algorithm = "SHA-256"

    var entries: [Entry]

    func jsonValue() -> SKJSONValue {
        .object([
            ("format", .string(SKHashIndexDocument.format)),
            ("indexVersion", .integer(Int64(SKHashIndexDocument.indexVersion))),
            ("algorithm", .string(SKHashIndexDocument.algorithm)),
            ("entries", .array(entries.map(\.jsonValue))),
        ])
    }

    /// Entries must arrive in ascending UTF-8 byte order, which lets the reader compare
    /// the index against the central directory without sorting.
    static func decode(_ value: SKJSONValue, limits: SKJSONParser.Limits = .default) throws -> SKHashIndexDocument {
        let root = try SKJSONObjectReader(value, label: "hash index")
        guard try root.string("format", maxBytes: 64) == SKHashIndexDocument.format else {
            throw SKManifestDocument.malformed("unknown hash index format")
        }
        guard try root.integer("indexVersion") == Int64(SKHashIndexDocument.indexVersion) else {
            throw SKManifestDocument.malformed("unknown hash index version")
        }
        guard try root.string("algorithm", maxBytes: 32) == SKHashIndexDocument.algorithm else {
            throw SKManifestDocument.malformed("unsupported hash algorithm")
        }

        let rawEntries = try root.array("entries", maxItems: limits.maxItems)
        var entries: [Entry] = []
        entries.reserveCapacity(rawEntries.count)
        var seen: Set<String> = []
        var previous: [UInt8]?
        for raw in rawEntries {
            let entry = try decodeEntry(raw)
            let bytes = Array(entry.path.utf8)
            if let previous, !previous.lexicographicallyPrecedes(bytes) {
                throw SKManifestDocument.malformed("index entries are not in ascending path order")
            }
            previous = bytes
            // Swift's String equality is canonical equivalence, so this also rejects two
            // spellings that a normalising filesystem would treat as one name.
            guard seen.insert(entry.path).inserted else {
                throw SKManifestDocument.malformed("index has a duplicate path")
            }
            // The index covers manifest.json; only the index itself stays out, because a
            // document cannot carry its own digest.
            guard entry.path != SKManifest.hashIndexPath else {
                throw SKManifestDocument.malformed("index must not list itself")
            }
            entries.append(entry)
        }
        return SKHashIndexDocument(entries: entries)
    }

    private static func decodeEntry(_ value: SKJSONValue) throws -> Entry {
        let object = try SKJSONObjectReader(value, label: "entries[]")
        let path = try object.string("path", maxBytes: SKResourceLimits.maxArchivePathBytes)
        guard let kind = Kind(rawValue: try object.string("type", maxBytes: 16)) else {
            throw SKManifestDocument.malformed("unknown entry type")
        }
        let size = try object.integer("size")

        var sha256: SKSHA256.Digest?
        if let raw = object.optional("sha256") {
            guard let text = raw.stringValue, let digest = SKSHA256.Digest(hex: text), digest.hex == text else {
                throw SKManifestDocument.malformed("sha256 is not a lowercase hex digest")
            }
            sha256 = digest
        }

        var modifiedAt: String?
        if let raw = object.optional("modifiedAt") {
            guard let text = raw.stringValue, text.utf8.count <= 64, SKRFC3339.seconds(of: text) != nil else {
                throw SKManifestDocument.malformed("modifiedAt is not an RFC 3339 date-time")
            }
            modifiedAt = text
        }

        var mode: UInt16?
        if let raw = object.optional("mode") {
            guard let bits = raw.integerValue, bits >= 0, bits <= 0o777 else {
                throw SKManifestDocument.malformed("mode is outside the permission range")
            }
            mode = UInt16(bits)
        }

        switch kind {
        case .regular:
            guard sha256 != nil else { throw SKManifestDocument.malformed("regular entry has no digest") }
        case .directory:
            guard sha256 == nil else { throw SKManifestDocument.malformed("directory entry carries a digest") }
            guard size == 0 else { throw SKManifestDocument.malformed("directory entry has a non-zero size") }
        }
        try SKArchivePath.validate(path, isDirectory: kind == .directory, form: .index)
        return Entry(path: path, kind: kind, size: size, sha256: sha256, modifiedAt: modifiedAt, mode: mode)
    }
}

extension SKHashIndexDocument.Entry {
    var jsonValue: SKJSONValue {
        var members: [SKJSONMember] = [
            SKJSONMember("path", .string(path)),
            SKJSONMember("type", .string(kind.rawValue)),
            SKJSONMember("size", .integer(size)),
        ]
        if let modifiedAt { members.append(SKJSONMember("modifiedAt", .string(modifiedAt))) }
        if let mode { members.append(SKJSONMember("mode", .integer(Int64(mode)))) }
        if let sha256 { members.append(SKJSONMember("sha256", .string(sha256.hex))) }
        return .object(members)
    }
}

/// Typed access to one JSON object, so every decoder reports the field it rejected
/// without ever echoing the value that failed.
struct SKJSONObjectReader {
    let members: [SKJSONMember]
    private let label: String

    init(_ value: SKJSONValue, label: String) throws {
        guard let members = value.objectMembers else {
            throw SKManifestDocument.malformed("\(label) is not an object")
        }
        self.members = members
        self.label = label
    }

    func optional(_ name: String) -> SKJSONValue? {
        members.first { $0.name == name }?.value
    }

    func value(_ name: String) throws -> SKJSONValue {
        guard let value = optional(name) else {
            throw SKManifestDocument.malformed("\(label) has no \(name)")
        }
        return value
    }

    func string(_ name: String, maxBytes: Int = 4096) throws -> String {
        guard let text = try value(name).stringValue else {
            throw SKManifestDocument.malformed("\(label).\(name) is not a string")
        }
        guard !text.isEmpty else { throw SKManifestDocument.malformed("\(label).\(name) is empty") }
        guard text.utf8.count <= maxBytes else {
            throw SKManifestDocument.malformed("\(label).\(name) exceeds \(maxBytes) bytes")
        }
        return text
    }

    func optionalString(_ name: String, maxBytes: Int = 4096) throws -> String? {
        guard let raw = optional(name) else { return nil }
        guard let text = raw.stringValue else {
            throw SKManifestDocument.malformed("\(label).\(name) is not a string")
        }
        guard text.utf8.count <= maxBytes else {
            throw SKManifestDocument.malformed("\(label).\(name) exceeds \(maxBytes) bytes")
        }
        return text
    }

    func boolean(_ name: String) throws -> Bool {
        guard let flag = try value(name).booleanValue else {
            throw SKManifestDocument.malformed("\(label).\(name) is not a boolean")
        }
        return flag
    }

    func integer(_ name: String, max: Int64 = Int64.max) throws -> Int64 {
        guard let number = try value(name).integerValue, number >= 0, number <= max else {
            throw SKManifestDocument.malformed("\(label).\(name) is outside its range")
        }
        return number
    }

    func array(_ name: String, maxItems: Int) throws -> [SKJSONValue] {
        guard let items = try value(name).arrayItems else {
            throw SKManifestDocument.malformed("\(label).\(name) is not an array")
        }
        guard items.count <= maxItems else {
            throw SKManifestDocument.malformed("\(label).\(name) exceeds \(maxItems) items")
        }
        return items
    }
}
