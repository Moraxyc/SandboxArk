#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A main database plus its `-wal`, `-shm` and `-journal` sidecars, treated as one
/// unit for hashing, packaging and restore decisions, because a database copied
/// without its WAL loses committed transactions.
///
/// Discovery is name-first: a database extension, the header every SQLite file starts with,
/// or a sidecar suffix beside a database name. A file that matches none of them stays an
/// ordinary file, so a custom database name or an encrypted container is reported as an
/// ordinary file instead of being guessed at.
enum SKSQLiteGroup {
    /// Position of one member inside its group. The order is fixed — the database first,
    /// then the sidecars SQLite may keep beside it — because the manifest stores the set as
    /// an ordered list and a reader has to be able to compare it.
    enum Role: String, Sendable, CaseIterable {
        case database
        case wal
        case shm
        case journal

        var sidecarSuffix: String? {
            switch self {
            case .database: nil
            case .wal: "-wal"
            case .shm: "-shm"
            case .journal: "-journal"
            }
        }
    }

    static let databaseExtensions = [".db", ".sqlite", ".sqlite3"]
    /// Every SQLite database file starts with these 16 bytes; the check is only a hint about
    /// content, so an encrypted database is still grouped by its name.
    static let header: [UInt8] = Array("SQLite format 3\0".utf8)

    /// What happened to one member while the backup ran. `absent` is a fact about the source,
    /// not a defect: a rollback-journal database normally has no sidecars at all.
    enum MemberState: String, Sendable {
        /// Copied and hashed into the archive.
        case packaged
        /// Not present in the source when the group was observed.
        case absent
        /// Present in the source, but the scan or the copy could not read it.
        case unreadable
        /// Present in the source, but changed while it was copied.
        case changed
        /// Present in the source, but excluded by policy, so it cannot be in the archive.
        case excluded

        var isPackaged: Bool { self == .packaged }
    }

    struct Member: Equatable, Sendable {
        var role: Role
        /// Home-relative source path. Recorded even when the member is not packaged, so a
        /// reader can tell which sidecar the group expected and did not get.
        var sourcePath: String
        /// Archive member path; only a packaged member has one.
        var archivePath: String?
        var state: MemberState
        var size: Int64?
        var sha256: SKSHA256.Digest?

        var isPackaged: Bool { state.isPackaged }
    }

    /// The SQLite data level from `design/08-sqlite-consistency.md`. A reader assigns
    /// `unknown` when an archive predates the field and never upgrades it by inference.
    enum Level: Int, Sendable {
        case raw = 0
        case walAware = 1
        case verified = 2
        case unknown = -1
    }

    enum Method: String, Sendable {
        case rawCopy = "raw-copy"
        case walAwareCopy = "wal-aware-copy"
        case integrityCheck = "sqlite-integrity-check"
        case unknown
    }

    /// `failed` means the group is incomplete in the archive — bytes are missing. A check
    /// that did not pass is `warning` or `unverified`, because nothing was lost by not
    /// knowing; the warning code says which check it was.
    enum Status: String, Sendable {
        case verified, unverified, warning, failed
    }

    enum Warning: String, Sendable, CaseIterable {
        case databaseUnreadable = "database-unreadable"
        case sidecarUnreadable = "sidecar-unreadable"
        case memberChanged = "member-changed-during-read"
        case memberExcluded = "member-excluded"
        case verificationSkipped = "verification-skipped"
        case verificationUnsupported = "verification-unsupported"
        case verificationBusy = "verification-busy"
        case verificationFailed = "verification-failed"
        case verificationTimedOut = "verification-timed-out"
        case verificationBudgetExhausted = "verification-budget-exhausted"
        case verificationCopyFailed = "verification-copy-failed"
        case storageInsufficient = "storage-insufficient"
    }

    struct Group: Equatable, Sendable {
        /// Observed basename of the database, e.g. `app.sqlite`.
        var baseName: String
        var members: [Member]
        var level: Level
        var method: Method
        var status: Status
        var warnings: [Warning]
        /// SQLite runtime version, recorded when the verifier could ask the runtime.
        var sqliteVersion: String?
        /// True when every member that exists in the source was copied and hashed.
        var complete: Bool

        var database: Member { members[0] }
    }
}

// MARK: - Grouping

extension SKSQLiteGroup {
    /// One staged regular file: what the grouping and the Level 2 check need about a member
    /// without reopening the source.
    struct StagedFile: Equatable, Sendable {
        var sourcePath: String
        var archivePath: String
        var size: Int64
        var sha256: SKSHA256.Digest
        /// First bytes of the staged copy, so the header hint reads the bytes the archive
        /// will hold rather than the source it came from.
        var headerPrefix: [UInt8]
        /// Position of the staged copy inside the transaction's payload directory.
        var stagedName: String
    }

    /// Groups staged files by canonical database path. A member that is not in `files` is
    /// recorded as absent, unreadable, changed or excluded from the scan report, which is the
    /// only record of a file that existed and was refused.
    static func collect(files: [StagedFile],
                        report: SKScanReport,
                        unstablePaths: Set<String>) -> [Group] {
        var observed: [String: [Role: StagedFile]] = [:]
        for file in files.sorted(by: { utf8Less($0.sourcePath, $1.sourcePath) }) {
            guard let candidate = candidate(of: file) else { continue }
            // The first file to name a role owns it; staging already rejected a second copy
            // of the same source path, so this only settles an ambiguous name.
            if observed[candidate.databasePath]?[candidate.role] == nil {
                observed[candidate.databasePath, default: [:]][candidate.role] = file
            }
        }
        return observed.keys.sorted(by: utf8Less).map { databasePath in
            group(databasePath: databasePath,
                  staged: observed[databasePath] ?? [:],
                  report: report,
                  unstablePaths: unstablePaths)
        }
    }

    /// Which group a staged file belongs to, and as which member. A sidecar name is only a
    /// clue: a real database saved under a `-wal` name is a database of its own name, not a
    /// sidecar, so the header decides that case.
    private static func candidate(of file: StagedFile) -> (databasePath: String, role: Role)? {
        let name = lastComponent(of: file.sourcePath)
        let directory = String(file.sourcePath.dropLast(name.utf8.count))
        if hasDatabaseExtension(name) { return (file.sourcePath, .database) }
        for role in Role.allCases where role != .database {
            guard let suffix = role.sidecarSuffix, name.lowercased().hasSuffix(suffix) else { continue }
            let stem = String(name.dropLast(suffix.utf8.count))
            guard hasDatabaseExtension(stem), !hasDatabaseHeader(file.headerPrefix) else { continue }
            return (directory + stem, role)
        }
        guard hasDatabaseHeader(file.headerPrefix) else { return nil }
        return (file.sourcePath, .database)
    }

    private static func group(databasePath: String,
                              staged: [Role: StagedFile],
                              report: SKScanReport,
                              unstablePaths: Set<String>) -> Group {
        var members: [Member] = []
        var warnings: [Warning] = []
        for role in Role.allCases {
            let sourcePath = databasePath + (role.sidecarSuffix ?? "")
            if let file = staged[role] {
                members.append(Member(role: role,
                                      sourcePath: file.sourcePath,
                                      archivePath: file.archivePath,
                                      state: .packaged,
                                      size: file.size,
                                      sha256: file.sha256))
                continue
            }
            let state = stateOf(unstaged: sourcePath, report: report, unstablePaths: unstablePaths)
            members.append(Member(role: role,
                                  sourcePath: sourcePath,
                                  archivePath: nil,
                                  state: state,
                                  size: nil,
                                  sha256: nil))
            switch state {
            case .unreadable:
                warnings.append(role == .database ? .databaseUnreadable : .sidecarUnreadable)
            case .changed:
                warnings.append(.memberChanged)
            case .excluded:
                warnings.append(.memberExcluded)
            case .absent, .packaged:
                break
            }
        }

        let complete = members.allSatisfy { $0.state == .packaged || $0.state == .absent }
        let database = members[0]
        // A group only reaches Level 1 when every member that exists is in the archive:
        // dropping a sidecar and still announcing WAL-aware coverage is exactly the claim
        // this level is meant to exclude.
        let level: Level = complete && database.isPackaged ? .walAware : .raw
        let status: Status
        if !database.isPackaged {
            status = .failed
        } else if complete {
            status = .unverified
        } else {
            status = .warning
        }
        return Group(baseName: lastComponent(of: databasePath),
                     members: members,
                     level: level,
                     method: level == .walAware ? .walAwareCopy : .rawCopy,
                     status: status,
                     warnings: deduplicated(warnings),
                     sqliteVersion: nil,
                     complete: complete)
    }

    private static func stateOf(unstaged path: String,
                                report: SKScanReport,
                                unstablePaths: Set<String>) -> MemberState {
        if unstablePaths.contains(path) { return .changed }
        guard let entry = report.entry(relativePath: path) else { return .absent }
        if entry.error != nil { return .unreadable }
        if entry.excludedReason != nil { return .excluded }
        return .absent
    }

    static func hasDatabaseExtension(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return databaseExtensions.contains { lowered.hasSuffix($0) }
    }

    static func hasDatabaseHeader(_ prefix: [UInt8]) -> Bool {
        prefix.count >= header.count && Array(prefix.prefix(header.count)) == header
    }

    private static func lastComponent(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: separator)...])
    }

    fileprivate static func deduplicated(_ warnings: [Warning]) -> [Warning] {
        var seen: Set<Warning> = []
        return warnings.filter { seen.insert($0).inserted }
    }

    private static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
    }
}

// MARK: - Level 2 result

extension SKSQLiteGroup {
    /// What the read-only check found, in the manifest's own vocabulary. `notRun` is not a
    /// failure: it says the platform or the build has no verifier, so nothing was claimed.
    enum VerificationOutcome: String, Sendable {
        case verified
        case unsupported
        case busy
        case failed
        case timedOut
        case notRun
        case budgetExhausted
        case copyFailed
        case storageInsufficient
        case cancelRequested
    }

    /// Facts from one verification attempt. The codes are for diagnostics; no text reaches a
    /// log or the UI from here.
    struct VerificationResult: Sendable {
        var outcome: VerificationOutcome
        var sqliteVersion: String?
        var sqliteCode: Int32?
        var errorCode: SKErrorCode?
    }
}

extension SKSQLiteGroup.Group {
    /// Folds a verification result into the group. Only a passing full integrity check
    /// raises the level, and only an already complete group can pass.
    func applying(_ result: SKSQLiteGroup.VerificationResult) -> SKSQLiteGroup.Group {
        var group = self
        var warnings = group.warnings
        switch result.outcome {
        case .verified:
            group.level = .verified
            group.method = .integrityCheck
            group.status = .verified
        case .unsupported:
            warnings.append(.verificationUnsupported)
            group.status = .warning
        case .busy:
            warnings.append(.verificationBusy)
            group.status = .warning
        case .failed:
            warnings.append(.verificationFailed)
            group.status = .warning
        case .timedOut:
            warnings.append(.verificationTimedOut)
            group.status = .warning
        case .budgetExhausted:
            warnings.append(.verificationBudgetExhausted)
            group.status = .warning
        case .copyFailed:
            warnings.append(.verificationCopyFailed)
            group.status = .warning
        case .storageInsufficient:
            warnings.append(.storageInsufficient)
            group.status = .warning
        case .notRun:
            group.status = .unverified
        case .cancelRequested:
            break
        }
        group.warnings = SKSQLiteGroup.deduplicated(warnings)
        if let version = result.sqliteVersion { group.sqliteVersion = version }
        return group
    }

    /// An incomplete group is never opened: verifying the main database alone would claim
    /// more than the bytes in the archive support.
    func skippingVerification() -> SKSQLiteGroup.Group {
        var group = self
        group.warnings = SKSQLiteGroup.deduplicated(group.warnings + [.verificationSkipped])
        return group
    }
}

// MARK: - Manifest representation

extension SKSQLiteGroup.Group {
    var jsonValue: SKJSONValue {
        var members: [SKJSONValue] = []
        for member in self.members {
            var fields: [(String, SKJSONValue)] = [
                ("role", .string(member.role.rawValue)),
                ("sourcePath", .string(member.sourcePath)),
                ("state", .string(member.state.rawValue)),
            ]
            if let archivePath = member.archivePath { fields.append(("archivePath", .string(archivePath))) }
            if let size = member.size { fields.append(("size", .integer(size))) }
            if let sha256 = member.sha256 { fields.append(("sha256", .string(sha256.hex))) }
            members.append(.object(fields))
        }
        var fields: [(String, SKJSONValue)] = [
            // A reader derives every member path from this one, so the group is self-describing.
            ("sourcePath", .string(database.sourcePath)),
            ("baseName", .string(baseName)),
            ("consistency", .object([
                ("level", .integer(Int64(level.rawValue))),
                ("method", .string(method.rawValue)),
            ])),
            ("status", .string(status.rawValue)),
            ("complete", .boolean(complete)),
            ("members", .array(members)),
            ("warnings", .array(warnings.map { .string($0.rawValue) })),
        ]
        if let sqliteVersion { fields.append(("sqliteVersion", .string(sqliteVersion))) }
        return .object(fields)
    }
}

extension SKSQLiteGroup {
    static func decode(_ values: [SKJSONValue]) throws -> [Group] {
        try values.map(decodeGroup)
    }

    private static func decodeGroup(_ value: SKJSONValue) throws -> Group {
        let object = try SKJSONObjectReader(value, label: "consistency.sqliteGroups[]")
        let databasePath = try object.string("sourcePath", maxBytes: SKResourceLimits.maxArchivePathBytes)
        _ = try SKPathResolver.components(ofPath: databasePath)
        guard !SKReservedPaths.isReserved(homeRelativePath: databasePath) else {
            throw SKManifestDocument.malformed("sqlite group names SandboxArk's own state")
        }
        let baseName = try object.string("baseName", maxBytes: SKResourceLimits.maxScanPathComponentBytes)
        guard baseName == lastComponent(of: databasePath) else {
            throw SKManifestDocument.malformed("sqlite group baseName does not match its source path")
        }
        guard let status = Status(rawValue: try object.string("status", maxBytes: 16)) else {
            throw SKManifestDocument.malformed("unknown sqlite group status")
        }

        // An archive that predates the field decodes as unknown, never as level 2.
        var level = Level.unknown
        var method = Method.unknown
        if let consistency = object.optional("consistency") {
            let reader = try SKJSONObjectReader(consistency, label: "consistency.sqliteGroups[].consistency")
            if let raw = reader.optional("level")?.integerValue, let value = Level(rawValue: Int(raw)) {
                level = value
            }
            if let raw = reader.optional("method")?.stringValue, let value = Method(rawValue: raw) {
                method = value
            }
        }

        var warnings: [Warning] = []
        if let raw = object.optional("warnings") {
            guard let items = raw.arrayItems, items.count <= Warning.allCases.count else {
                throw SKManifestDocument.malformed("sqlite group warnings are not a bounded array")
            }
            for item in items {
                guard let text = item.stringValue, let warning = Warning(rawValue: text) else {
                    throw SKManifestDocument.malformed("unknown sqlite group warning")
                }
                warnings.append(warning)
            }
        }

        let members = try object.array("members", maxItems: Role.allCases.count).map(decodeMember)
        try checkMembers(members, databasePath: databasePath)

        return Group(baseName: baseName,
                     members: members,
                     level: level,
                     method: method,
                     status: status,
                     warnings: deduplicated(warnings),
                     sqliteVersion: try object.optionalString("sqliteVersion", maxBytes: 64),
                     complete: try object.boolean("complete"))
    }

    private static func decodeMember(_ value: SKJSONValue) throws -> Member {
        let object = try SKJSONObjectReader(value, label: "consistency.sqliteGroups[].members[]")
        guard let role = Role(rawValue: try object.string("role", maxBytes: 16)) else {
            throw SKManifestDocument.malformed("unknown sqlite group role")
        }
        let sourcePath = try object.string("sourcePath", maxBytes: SKResourceLimits.maxArchivePathBytes)
        _ = try SKPathResolver.components(ofPath: sourcePath)
        guard let state = MemberState(rawValue: try object.string("state", maxBytes: 16)) else {
            throw SKManifestDocument.malformed("unknown sqlite member state")
        }

        var archivePath: String?
        if let raw = object.optional("archivePath") {
            guard let path = raw.stringValue else {
                throw SKManifestDocument.malformed("sqlite member archivePath is not a string")
            }
            try SKArchivePath.validate(path, isDirectory: false)
            try SKArchivePath.authorized(path, isDirectory: false)
            try SKArchivePath.checkNotReserved(path)
            archivePath = path
        }

        var size: Int64?
        if let raw = object.optional("size") {
            guard let value = raw.integerValue, value >= 0 else {
                throw SKManifestDocument.malformed("sqlite member size is outside its range")
            }
            size = value
        }

        var sha256: SKSHA256.Digest?
        if let raw = object.optional("sha256") {
            guard let text = raw.stringValue, let digest = SKSHA256.Digest(hex: text), digest.hex == text else {
                throw SKManifestDocument.malformed("sqlite member sha256 is not a lowercase hex digest")
            }
            sha256 = digest
        }

        switch state {
        case .packaged:
            guard archivePath != nil, size != nil, sha256 != nil else {
                throw SKManifestDocument.malformed("packaged sqlite member is missing its archive record")
            }
        case .absent, .unreadable, .changed, .excluded:
            guard archivePath == nil, size == nil, sha256 == nil else {
                throw SKManifestDocument.malformed("unpackaged sqlite member carries an archive record")
            }
        }
        return Member(role: role, sourcePath: sourcePath, archivePath: archivePath,
                      state: state, size: size, sha256: sha256)
    }

    /// The member list is derived from the database path, so a reader can check it instead
    /// of trusting it: roles ascend without a gap, and every source path is the database
    /// path plus that role's suffix.
    private static func checkMembers(_ members: [Member], databasePath: String) throws {
        guard !members.isEmpty, members[0].role == .database else {
            throw SKManifestDocument.malformed("sqlite group does not start with its database")
        }
        var previous = -1
        for member in members {
            guard let index = Role.allCases.firstIndex(of: member.role), index > previous else {
                throw SKManifestDocument.malformed("sqlite group repeats or reorders a role")
            }
            previous = index
            guard member.sourcePath == databasePath + (member.role.sidecarSuffix ?? "") else {
                throw SKManifestDocument.malformed("sqlite member path is not the database path and its suffix")
            }
        }
    }
}
