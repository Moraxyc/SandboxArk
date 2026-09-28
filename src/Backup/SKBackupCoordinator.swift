#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Backup transaction state machine and pipeline ownership. One transaction owns a
/// staging directory, the `.partial` file and the verification that promotes it: sources
/// are hashed into staging first, so the archive is built from bytes already validated.
struct SKBackupCoordinator {
    enum State: String, Sendable {
        case prepared, scanning, staging, archiving, verifying, readyToShare
        case cancelled, failed, cleanupRequired
    }

    struct Request: Sendable {
        var app: SKManifestDocument.App
        var environment: SKManifestDocument.Environment
        /// Final file name of the archive; the `.partial` stage replaces its extension.
        var outputName: String
        var createdAt: String
        var kind: SKManifestDocument.Kind = .user
        var mode: SKManifestDocument.Mode = .standard
        var rootPaths: [String] = SKScanner.standardRootPaths
        var exclusionPolicy: SKExclusionPolicy = .standard
        /// A source that changed while read cancels the transaction unless a partial backup
        /// was accepted.
        var allowsPartialBackup = false
        var isCancelled: @Sendable () -> Bool = { false }
        var onStateChange: @Sendable (State) -> Void = { _ in }
    }

    struct Outcome: Sendable {
        /// Home-relative path of the verified archive, kept in staging until the share
        /// handoff closes.
        var archivePath: String
        var stagingPath: String
        var manifest: SKManifestDocument
        var verifiedMembers: Int
        var verifiedBytes: Int64
    }

    // MARK: - Pipeline

    static func run(home: SKAuthorizedRoot, request: Request) throws -> Outcome {
        try validate(request)
        request.onStateChange(.prepared)

        request.onStateChange(.scanning)
        let report = SKScanner.scan(home: home,
                                    options: SKScanner.Options(rootPaths: request.rootPaths,
                                                               exclusionPolicy: request.exclusionPolicy,
                                                               isCancelled: request.isCancelled))
        if request.isCancelled() || report.status == .cancelled { throw cancelled() }
        guard report.isComplete || request.allowsPartialBackup else {
            throw SKError(code: .filesystemUnreadable,
                          stage: "scan",
                          userAction: "Retry the backup, or accept a partial backup.",
                          reason: "\(report.unreadableCount) items could not be read")
        }
        let estimate = try SKBackupPreflight.run(report: report, home: home)

        request.onStateChange(.staging)
        let transaction = try Transaction(home: home, request: request)
        defer { transaction.close() }
        do {
            let payload = try SKBackupStaging.openOrCreateDirectory(name: Transaction.payloadDirectory,
                                                                    in: transaction.staging)
            defer { SKArchiveIO.close(payload) }

            var plan = MemberPlan()
            var remainingBytes = estimate.sourceBytes
            var unstableRoots: Set<String> = []
            var unstableFiles = 0
            try stage(report: report,
                      home: home,
                      request: request,
                      transaction: transaction,
                      plan: &plan,
                      remainingBytes: &remainingBytes,
                      unstableRoots: &unstableRoots,
                      unstableFiles: &unstableFiles)
            plan = try plan.completingDirectories(home: home,
                                                  reference: referenceTimestamp(request.createdAt))
            let documents = try makeDocuments(report: report,
                                              plan: plan,
                                              unstableRoots: unstableRoots,
                                              unstableFiles: unstableFiles,
                                              request: request)

            transaction.set(.archiving)
            try writeArchive(transaction: transaction, plan: plan, documents: documents)

            transaction.set(.verifying)
            let contents = try verifyArchive(transaction: transaction, expected: documents)
            guard contents.members.count == documents.memberCount else { throw SKZipLayoutError.inconsistent }

            try transaction.finalize()
            return Outcome(archivePath: transaction.archivePath,
                           stagingPath: transaction.stagingName,
                           manifest: documents.manifest,
                           verifiedMembers: contents.members.count,
                           verifiedBytes: documents.manifest.backup.totalBytes)
        } catch {
            throw transaction.fail(with: error)
        }
    }

    // MARK: - Staging pass

    private static func stage(report: SKScanReport,
                              home: SKAuthorizedRoot,
                              request: Request,
                              transaction: Transaction,
                              plan: inout MemberPlan,
                              remainingBytes: inout Int64,
                              unstableRoots: inout Set<String>,
                              unstableFiles: inout Int) throws {
        for root in report.roots {
            for entry in root.entries where entry.excludedReason == nil && entry.error == nil {
                if request.isCancelled() { throw cancelled() }
                let memberPath = SKManifest.homeRoot + "/" + entry.relativePath
                switch entry.kind {
                case .directory:
                    plan.directories.append(MemberPlan.Directory(memberPath: memberPath + "/",
                                                                 permissions: entry.permissions,
                                                                 modifiedAt: entry.modifiedAt))
                case .regular:
                    do {
                        plan.files.append(try stage(file: entry,
                                                    memberPath: memberPath,
                                                    root: root.relativePath,
                                                    home: home,
                                                    request: request,
                                                    transaction: transaction,
                                                    remainingBytes: &remainingBytes))
                    } catch let error as SKError where error.code == .filesystemChangedDuringRead
                        && request.allowsPartialBackup {
                        unstableRoots.insert(root.relativePath)
                        unstableFiles += 1
                    }
                case .symlink, .special, .unknown:
                    continue
                }
            }
        }
    }

    /// Copies one source into staging while hashing it, so the index precedes the archive
    /// and later stages compare against the bytes this pass validated.
    private static func stage(file entry: SKScanEntry,
                              memberPath: String,
                              root: String,
                              home: SKAuthorizedRoot,
                              request: Request,
                              transaction: Transaction,
                              remainingBytes: inout Int64) throws -> MemberPlan.File {
        let opened = try SKPathResolver.openRegularFile(atPath: entry.relativePath, under: home)
        defer { SKPathResolver.closeDescriptor(opened.descriptor) }
        guard opened.identity.kind == .regular, opened.identity.size == entry.size else {
            throw sourceChanged(entry.relativePath)
        }

        let stagedName = transaction.nextStagedName()
        let target = try SKArchiveIO.createExclusive(name: stagedName, in: transaction.staging)
        transaction.record(stagedName: stagedName)
        defer { SKArchiveIO.close(target) }

        var hasher = SKSHA256.Hasher()
        var copied: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: SKZipWriter.chunkBytes)
        while true {
            if request.isCancelled() { throw cancelled() }
            let count = try SKArchiveIO.readChunk(from: opened.descriptor, into: &buffer)
            if count == 0 { break }
            let slice = buffer[0..<count]
            try SKArchiveIO.write(slice, at: copied, to: target)
            hasher.update(slice)
            copied += Int64(count)
            remainingBytes = max(0, remainingBytes - Int64(count))
            let available = try SKBackupPreflight.availableBytes(home: home)
            // Staging holds one copy of the unread bytes and the archive holds at most
            // another, so the pending worst case is twice what is still unread.
            guard SKBackupPreflight.hasHeadroom(availableBytes: available,
                                                remainingBytes: 2 * remainingBytes) else {
                throw SKError(code: .storageInsufficientSpace,
                              stage: "staging",
                              retryable: true,
                              userAction: "Free space, then retry the backup.",
                              reason: "free space fell into the reserve")
            }
        }
        guard copied == entry.size else { throw sourceChanged(entry.relativePath) }
        let closed = try SKPathResolver.identity(of: opened.descriptor)
        guard closed.isSameObject(as: opened.identity),
              closed.size == opened.identity.size,
              closed.modifiedSeconds == opened.identity.modifiedSeconds,
              closed.modifiedNanoseconds == opened.identity.modifiedNanoseconds else {
            throw sourceChanged(entry.relativePath)
        }
        return MemberPlan.File(memberPath: memberPath,
                               root: root,
                               size: copied,
                               permissions: entry.permissions,
                               modifiedAt: entry.modifiedAt,
                               stagedName: stagedName,
                               sha256: hasher.finalize())
    }

    // MARK: - Archive pass

    private static func writeArchive(transaction: Transaction,
                                     plan: MemberPlan,
                                     documents: Documents) throws {
        let partial = try SKArchiveIO.createExclusive(name: transaction.partialName, in: transaction.staging)
        defer { SKArchiveIO.close(partial) }
        var writer = try SKZipWriter(descriptor: partial)

        _ = try writer.addPayload(path: SKManifest.manifestPath,
                                  bytes: documents.manifestBytes,
                                  permissions: 0o644,
                                  modifiedAt: documents.reference)
        _ = try writer.addPayload(path: SKManifest.hashIndexPath,
                                  bytes: documents.hashBytes,
                                  permissions: 0o644,
                                  modifiedAt: documents.reference)
        for directory in plan.orderedDirectories {
            _ = try writer.addDirectory(path: directory.memberPath,
                                        permissions: directory.permissions,
                                        modifiedAt: directory.modifiedAt)
        }
        for file in plan.orderedFiles {
            let staged = try SKArchiveIO.openReadOnly(name: file.stagedName, in: transaction.staging)
            defer { SKArchiveIO.close(staged) }
            let member = try writer.addRegularFile(path: file.memberPath,
                                                   descriptor: staged,
                                                   declaredBytes: file.size,
                                                   permissions: file.permissions,
                                                   modifiedAt: file.modifiedAt)
            guard member.sha256 == file.sha256, member.uncompressedBytes == file.size else {
                throw SKZipReader.invalid(file.memberPath)
            }
        }
        try writer.finish()
    }

    private static func verifyArchive(transaction: Transaction, expected: Documents) throws -> SKZipReader.Contents {
        let descriptor = try SKArchiveIO.openReadOnly(name: transaction.partialName, in: transaction.staging)
        defer { SKArchiveIO.close(descriptor) }
        let contents = try SKZipReader.verify(descriptor: descriptor)
        guard contents.manifest == expected.manifest, contents.hashIndex == expected.hashIndex else {
            throw SKZipReader.invalid(SKManifest.manifestPath)
        }
        return contents
    }

    // MARK: - Documents

    private struct Documents {
        var manifest: SKManifestDocument
        var hashIndex: SKHashIndexDocument
        var manifestBytes: [UInt8]
        var hashBytes: [UInt8]
        var reference: SKFileTimestamp
        var memberCount: Int
    }

    private static func makeDocuments(report: SKScanReport,
                                      plan: MemberPlan,
                                      unstableRoots: Set<String>,
                                      unstableFiles: Int,
                                      request: Request) throws -> Documents {
        var roots: [SKManifestDocument.Root] = []
        var totalFiles = 0
        var totalBytes: Int64 = 0
        for root in report.roots {
            let files = plan.files.filter { $0.root == root.relativePath }
            let bytes = files.reduce(Int64(0)) { $0 + $1.size }
            totalFiles += files.count
            totalBytes += bytes
            let stable = !unstableRoots.contains(root.relativePath)
            roots.append(SKManifestDocument.Root(
                scopeType: .home,
                relativeRoot: root.relativePath,
                archivePrefix: SKManifest.homeRoot + "/" + root.relativePath,
                complete: root.isComplete && stable,
                mirrorSafe: root.isMirrorSafe && stable,
                includedFiles: files.count,
                includedBytes: bytes,
                unreadableCount: root.unreadableCount,
                excludedCounts: Dictionary(uniqueKeysWithValues: root.excludedCounts.map { ($0.key.rawValue, $0.value) })))
        }

        let reference = referenceTimestamp(request.createdAt)
        let manifest = SKManifestDocument(
            app: request.app,
            environment: request.environment,
            backup: SKManifestDocument.Backup(createdAt: request.createdAt,
                                              kind: request.kind,
                                              mode: request.mode,
                                              completeness: roots.allSatisfy(\.complete) ? .complete : .partial,
                                              totalFiles: totalFiles,
                                              totalBytes: totalBytes,
                                              warningCount: report.unreadableCount + unstableFiles),
            roots: roots,
            sqliteGroups: [],
            appGroups: [])
        let manifestBytes = SKJSONEncoder.bytes(manifest.jsonValue())
        guard manifestBytes.count <= SKResourceLimits.maxManifestBytes else {
            throw SKZipReader.limitError("manifest exceeds the manifest limit")
        }

        var entries: [SKHashIndexDocument.Entry] = [SKHashIndexDocument.Entry(
            path: SKManifest.manifestPath,
            kind: .regular,
            size: Int64(manifestBytes.count),
            sha256: SKSHA256.digest(of: manifestBytes),
            modifiedAt: SKZipTimestamp(reference)?.rfc3339,
            mode: 0o644)]
        for directory in plan.directories {
            entries.append(SKHashIndexDocument.Entry(path: String(directory.memberPath.dropLast()),
                                                     kind: .directory,
                                                     size: 0,
                                                     sha256: nil,
                                                     modifiedAt: nil,
                                                     mode: directory.permissions))
        }
        for file in plan.files {
            entries.append(SKHashIndexDocument.Entry(path: file.memberPath,
                                                     kind: .regular,
                                                     size: file.size,
                                                     sha256: file.sha256,
                                                     modifiedAt: SKZipTimestamp(file.modifiedAt)?.rfc3339,
                                                     mode: file.permissions))
        }
        entries.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        let hashIndex = SKHashIndexDocument(entries: entries)
        let hashBytes = SKJSONEncoder.bytes(hashIndex.jsonValue())
        guard hashBytes.count <= SKResourceLimits.maxHashIndexBytes else {
            throw SKZipReader.limitError("hash index exceeds the hash index limit")
        }
        return Documents(manifest: manifest,
                         hashIndex: hashIndex,
                         manifestBytes: manifestBytes,
                         hashBytes: hashBytes,
                         reference: reference,
                         memberCount: 2 + plan.directories.count + plan.files.count)
    }

    // MARK: - Requests

    private static func validate(_ request: Request) throws {
        let name = request.outputName
        guard !name.isEmpty, name.utf8.count <= 255,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              name != ".", name != "..", name.hasSuffix(".sandboxark") else {
            throw SKError(code: .archivePathTraversal,
                          stage: "backupRequest",
                          reason: "output name is not a plain archive file name")
        }
        guard SKRFC3339.seconds(of: request.createdAt) != nil else {
            throw SKError(code: .integrityManifestInvalid,
                          stage: "backupRequest",
                          reason: "createdAt is not an RFC 3339 date-time")
        }
    }

    /// One instant for the transaction's own members, so manifest.json and hashes.json
    /// carry the backup's creation time.
    private static func referenceTimestamp(_ text: String) -> SKFileTimestamp {
        SKFileTimestamp(seconds: SKRFC3339.seconds(of: text) ?? 0, nanoseconds: 0)
    }

    static func makeTransactionID() -> String {
        var value = SKFileTimestamp.monotonicNanoseconds() ^ UInt64(getpid()) << 32
        value = value &* 0x9E37_79B9_7F4A_7C15
        var text = "tx-"
        for shift in stride(from: 60, through: 0, by: -4) {
            text.append(SKHex.digits[Int(value >> UInt64(shift)) & 0x0F])
        }
        return text
    }

    static func cancelled() -> SKError {
        SKError(code: .cancelled, stage: "backup", recoveryState: State.cancelled.rawValue)
    }

    static func sourceChanged(_ path: String) -> SKError {
        SKError(code: .filesystemChangedDuringRead,
                stage: "staging",
                relativePath: path,
                reason: "source changed while it was read")
    }
}

/// One transaction's private staging directory and the cleanup that owns it.
private final class Transaction {
    static let payloadDirectory = "payload"

    let request: SKBackupCoordinator.Request
    let stagingName: String
    let stagingParent: Int32
    let staging: Int32
    let partialName: String
    var archivePath: String { stagingName + "/" + request.outputName }

    private let directoryName: String
    private var stagedNames: [String] = []
    private var nextPayloadIndex = 0
    private var finalized = false

    init(home: SKAuthorizedRoot, request: SKBackupCoordinator.Request) throws {
        let identifier = SKBackupCoordinator.makeTransactionID()
        let stagingName = SKReservedPaths.stagingRoot + "/" + identifier
        let stem = String(request.outputName.dropLast(".sandboxark".count))
        let partialName = stem + ".partial"

        let tmp = try SKBackupStaging.openOrCreateDirectory(name: "tmp", in: home.descriptor)
        let parent: Int32
        let staging: Int32
        do {
            parent = try SKBackupStaging.openOrCreateDirectory(name: "SandboxArk", in: tmp)
        } catch {
            SKArchiveIO.close(tmp)
            throw error
        }
        SKArchiveIO.close(tmp)
        do {
            staging = try SKBackupStaging.openOrCreateDirectory(name: identifier, in: parent)
        } catch {
            SKArchiveIO.close(parent)
            throw error
        }
        self.request = request
        self.directoryName = identifier
        self.stagingName = stagingName
        self.partialName = partialName
        self.stagingParent = parent
        self.staging = staging
    }

    func set(_ state: SKBackupCoordinator.State) {
        request.onStateChange(state)
    }

    /// Payload names are positions in the plan, not source paths: staging never mirrors the
    /// home tree, so a source name cannot leak into a second place on disk.
    func nextStagedName() -> String {
        defer { nextPayloadIndex += 1 }
        return Transaction.payloadDirectory + "/" + String(nextPayloadIndex)
    }

    func record(stagedName: String) {
        stagedNames.append(stagedName)
    }

    /// Promotes the `.partial` to the archive, then drops the staged payload copies.
    func finalize() throws {
        try SKBackupStaging.rename(partialName, to: request.outputName, in: staging)
        try SKArchiveIO.sync(staging)
        finalized = true
        set(.readyToShare)
        do {
            try SKBackupStaging.removeStagedPayload(stagedNames, in: staging)
        } catch {
            throw SKError(code: .storageDurabilityFailure,
                          stage: "cleanup",
                          recoveryState: SKBackupCoordinator.State.readyToShare.rawValue,
                          reason: "archive is verified but staged payload removal failed")
        }
    }

    /// Removes what this transaction created and reports the state reached; a verified
    /// archive is never deleted by cleanup, however the cleanup itself went.
    func fail(with error: Error) -> SKError {
        var failure = (error as? SKError)
            ?? SKError(code: .archiveCorrupt, stage: "backup", reason: "transaction failed")
        if finalized { return failure }
        let isCancelled = failure.code == .cancelled
        do {
            try SKBackupStaging.unlink(partialName, in: staging)
            try SKBackupStaging.unlink(request.outputName, in: staging)
            try SKBackupStaging.removeStagedPayload(stagedNames, in: staging)
            try SKBackupStaging.removeDirectory(name: directoryName, in: stagingParent)
        } catch {
            failure.recoveryState = SKBackupCoordinator.State.cleanupRequired.rawValue
            set(.cleanupRequired)
            return failure
        }
        let state: SKBackupCoordinator.State = isCancelled ? .cancelled : .failed
        failure.recoveryState = state.rawValue
        set(state)
        return failure
    }

    func close() {
        SKArchiveIO.close(staging)
        SKArchiveIO.close(stagingParent)
    }
}

/// Everything one transaction intends to write, in the order the archive receives it.
private struct MemberPlan {
    struct File {
        var memberPath: String
        var root: String
        var size: Int64
        var permissions: UInt16
        var modifiedAt: SKFileTimestamp
        var stagedName: String
        var sha256: SKSHA256.Digest
    }

    struct Directory {
        var memberPath: String
        var permissions: UInt16
        var modifiedAt: SKFileTimestamp
    }

    var files: [File] = []
    var directories: [Directory] = []

    var orderedFiles: [File] {
        files.sorted { Array($0.memberPath.utf8).lexicographicallyPrecedes(Array($1.memberPath.utf8)) }
    }

    var orderedDirectories: [Directory] {
        directories.sorted { Array($0.memberPath.utf8).lexicographicallyPrecedes(Array($1.memberPath.utf8)) }
    }

    /// Adds the namespace roots and the parent directories the scan never visits on its
    /// own, because a reader has to find every directory a member path names.
    func completingDirectories(home: SKAuthorizedRoot, reference: SKFileTimestamp) throws -> MemberPlan {
        var known: [String: Directory] = [:]
        for directory in directories { known[directory.memberPath] = directory }

        var names: Set<String> = ["data/", SKManifest.homeRoot + "/"]
        // Scanned directories are seeded as themselves, not only as parents: an empty
        // directory has no child to introduce it, and the profile keeps every one.
        for directory in directories { names.insert(directory.memberPath) }
        for file in files { insertParents(of: file.memberPath, into: &names) }
        for directory in directories { insertParents(of: directory.memberPath, into: &names) }

        var resolved: [Directory] = []
        for name in names.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            if let directory = known[name] {
                resolved.append(directory)
                continue
            }
            if name == "data/" || name == SKManifest.homeRoot + "/" {
                resolved.append(Directory(memberPath: name, permissions: 0o755, modifiedAt: reference))
                continue
            }
            let relative = String(name.dropFirst(SKManifest.homeRoot.utf8.count + 1).dropLast())
            let opened = try SKPathResolver.openDirectory(atPath: relative, under: home)
            SKPathResolver.closeDescriptor(opened.descriptor)
            resolved.append(Directory(memberPath: name,
                                      permissions: opened.identity.permissions,
                                      modifiedAt: opened.identity.modifiedAt))
        }
        return MemberPlan(files: files, directories: resolved)
    }

    private func insertParents(of memberPath: String, into names: inout Set<String>) {
        var path = memberPath.hasSuffix("/") ? String(memberPath.dropLast()) : memberPath
        while let separator = path.lastIndex(of: "/") {
            path = String(path[path.startIndex..<separator])
            let directory = path.isEmpty ? "" : path + "/"
            if directory.isEmpty || directory == "data/" || directory == SKManifest.homeRoot + "/" { break }
            names.insert(directory)
        }
    }
}

/// Staging directory operations. SandboxArk's own staging tree is the only place the tool
/// creates paths, and source-path rules deliberately do not apply inside it: the reserved
/// prefix is exactly what makes the tree private.
private enum SKBackupStaging {
    static func openOrCreateDirectory(name: String, in parent: Int32) throws -> Int32 {
        if let descriptor = try? openDirectory(name: name, in: parent) { return descriptor }
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else {
            throw failure(errno, "mkdir")
        }
        return try openDirectory(name: name, in: parent)
    }

    static func openDirectory(name: String, in parent: Int32) throws -> Int32 {
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw failure(errno, "open") }
        return descriptor
    }

    static func rename(_ from: String, to: String, in directory: Int32) throws {
        guard renameat(directory, from, directory, to) == 0 else { throw failure(errno, "rename") }
    }

    static func unlink(_ name: String, in directory: Int32) throws {
        guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else {
            throw failure(errno, "unlink")
        }
    }

    static func removeDirectory(name: String, in parent: Int32) throws {
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw failure(errno, "rmdir")
        }
    }

    /// Removes the staged payload copies and their directory; leftover payload is a space
    /// failure, not data.
    static func removeStagedPayload(_ names: [String], in directory: Int32) throws {
        for name in names { try unlink(name, in: directory) }
        try removeDirectory(name: Transaction.payloadDirectory, in: directory)
    }

    private static func failure(_ code: Int32, _ operation: String) -> SKError {
        SKError(code: .storageDurabilityFailure,
                stage: "staging",
                retryable: true,
                underlyingCode: code,
                reason: "\(operation) failed")
    }
}
