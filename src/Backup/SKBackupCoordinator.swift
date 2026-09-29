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
        case prepared, scanning, staging, checkingDatabases, archiving, verifying, readyToShare
        case cancelled, failed, cleanupRequired
    }

    struct Request: Sendable {
        var app: SKManifestDocument.App
        var environment: SKManifestDocument.Environment
        /// Published archive name, fixed per host app: the slot holds one file, so a name
        /// that changed per run would leave the previous archive behind instead of
        /// replacing it. The creation time lives in the manifest, not in the name.
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
        /// Stage counters for the progress UI, reported on the caller's thread.
        var onProgress: @Sendable (Progress) -> Void = { _ in }
    }

    /// Monotonic counters for the progress UI. Each pass reports its own unit, so `state`
    /// names the pass the numbers describe: staging counts copied files and source bytes,
    /// archiving counts written members, verifying counts members still to check.
    struct Progress: Sendable {
        var state: State
        var completedItems: Int
        var totalItems: Int
        /// Zero while the pass has no byte unit of its own.
        var completedBytes: Int64
        var totalBytes: Int64
    }

    struct Outcome: Sendable {
        /// Home-relative path of the verified archive, already published into the slot the
        /// next backup replaces. It is staging, not storage: the system may reclaim `tmp`, so
        /// only an exported copy outlives the container.
        var archivePath: String
        var manifest: SKManifestDocument
        var verifiedMembers: Int
        var verifiedBytes: Int64
    }

    // MARK: - Pipeline

    /// A caller that already scanned passes its report, so the estimate the user confirmed
    /// is the estimate the transaction uses.
    static func run(home: SKAuthorizedRoot,
                    request: Request,
                    report prepared: SKScanReport? = nil) throws -> Outcome {
        try validate(request)
        request.onStateChange(.prepared)

        let report: SKScanReport
        if let prepared {
            report = prepared
        } else {
            request.onStateChange(.scanning)
            report = try scan(home: home, request: request)
        }
        guard report.isComplete || request.allowsPartialBackup else {
            throw SKError(code: .filesystemUnreadable,
                          stage: "scan",
                          userAction: "Retry the backup, or accept a partial backup.",
                          reason: "\(report.unreadableCount) items could not be read")
        }
        let estimate = try SKBackupPreflight.run(report: report, home: home)

        request.onStateChange(.staging)
        var progress = Progress(state: .staging,
                                completedItems: 0,
                                totalItems: estimate.includedFiles,
                                completedBytes: 0,
                                totalBytes: estimate.sourceBytes)
        request.onProgress(progress)

        let transaction = try Transaction(home: home, request: request)
        defer { transaction.close() }
        do {
            let payload = try SKBackupStaging.openOrCreateDirectory(name: Transaction.payloadDirectory,
                                                                    in: transaction.staging)
            defer { SKArchiveIO.close(payload) }

            var plan = MemberPlan()
            var remainingBytes = estimate.sourceBytes
            var unstableRoots: Set<String> = []
            var unstablePaths: Set<String> = []
            try stage(report: report,
                      home: home,
                      request: request,
                      transaction: transaction,
                      plan: &plan,
                      remainingBytes: &remainingBytes,
                      unstableRoots: &unstableRoots,
                      unstablePaths: &unstablePaths,
                      progress: &progress)
            plan = try plan.completingDirectories(home: home,
                                                  reference: referenceTimestamp(request.createdAt))
            let groups = try verifyDatabases(plan: plan,
                                             report: report,
                                             unstablePaths: unstablePaths,
                                             transaction: transaction,
                                             home: home,
                                             request: request,
                                             progress: &progress)
            let documents = try makeDocuments(report: report,
                                              plan: plan,
                                              groups: groups,
                                              unstableRoots: unstableRoots,
                                              unstableFileCount: unstablePaths.count,
                                              request: request)

            transaction.set(.archiving)
            progress = Progress(state: .archiving,
                                completedItems: 0,
                                totalItems: documents.memberCount,
                                completedBytes: 0,
                                totalBytes: 0)
            request.onProgress(progress)
            try writeArchive(transaction: transaction,
                             plan: plan,
                             documents: documents,
                             request: request,
                             progress: &progress)

            transaction.set(.verifying)
            request.onProgress(Progress(state: .verifying,
                                        completedItems: 0,
                                        totalItems: documents.memberCount,
                                        completedBytes: 0,
                                        totalBytes: 0))
            let contents = try verifyArchive(transaction: transaction, expected: documents)
            guard contents.members.count == documents.memberCount else { throw SKZipLayoutError.inconsistent }

            try transaction.finalize()
            return Outcome(archivePath: transaction.archivePath,
                           manifest: documents.manifest,
                           verifiedMembers: contents.members.count,
                           verifiedBytes: documents.manifest.backup.totalBytes)
        } catch {
            throw transaction.fail(with: error)
        }
    }

    /// Scans the roots the request allows. The scan is a candidate list, never a trust
    /// anchor: staging re-opens every source through the root descriptor and re-checks it.
    static func scan(home: SKAuthorizedRoot, request: Request) throws -> SKScanReport {
        let report = SKScanner.scan(home: home,
                                    options: SKScanner.Options(rootPaths: request.rootPaths,
                                                               exclusionPolicy: request.exclusionPolicy,
                                                               isCancelled: request.isCancelled))
        if request.isCancelled() || report.status == .cancelled { throw cancelled() }
        return report
    }

    // MARK: - Staging pass

    /// Byte interval between in-file progress reports, so one multi-GiB member still moves
    /// the UI without publishing a report per chunk.
    private static let progressStride: Int64 = 4 * 1024 * 1024

    private static func stage(report: SKScanReport,
                              home: SKAuthorizedRoot,
                              request: Request,
                              transaction: Transaction,
                              plan: inout MemberPlan,
                              remainingBytes: inout Int64,
                              unstableRoots: inout Set<String>,
                              unstablePaths: inout Set<String>,
                              progress: inout Progress) throws {
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
                        let file = try stage(file: entry,
                                             memberPath: memberPath,
                                             root: root.relativePath,
                                             home: home,
                                             request: request,
                                             transaction: transaction,
                                             remainingBytes: &remainingBytes,
                                             progress: &progress)
                        plan.files.append(file)
                        progress.completedItems += 1
                        progress.completedBytes += file.size
                        request.onProgress(progress)
                    } catch let error as SKError where error.code == .filesystemChangedDuringRead
                        && request.allowsPartialBackup {
                        unstableRoots.insert(root.relativePath)
                        unstablePaths.insert(entry.relativePath)
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
                              remainingBytes: inout Int64,
                              progress: inout Progress) throws -> MemberPlan.File {
        let opened = try SKPathResolver.openRegularFile(atPath: entry.relativePath, under: home)
        defer { SKPathResolver.closeDescriptor(opened.descriptor) }
        guard opened.identity.kind == .regular, opened.identity.size == entry.size else {
            throw sourceChanged(entry.relativePath)
        }

        let stagedName = transaction.nextStagedName()
        let target = try SKArchiveIO.createExclusive(name: stagedName, in: transaction.staging)
        defer { SKArchiveIO.close(target) }

        var hasher = SKSHA256.Hasher()
        var copied: Int64 = 0
        var reported: Int64 = 0
        var headerPrefix: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: SKZipWriter.chunkBytes)
        while true {
            if request.isCancelled() { throw cancelled() }
            let count = try SKArchiveIO.readChunk(from: opened.descriptor, into: &buffer)
            if count == 0 { break }
            let slice = buffer[0..<count]
            if headerPrefix.count < SKSQLiteGroup.header.count {
                headerPrefix.append(contentsOf: slice.prefix(SKSQLiteGroup.header.count - headerPrefix.count))
            }
            try SKArchiveIO.write(slice, at: copied, to: target)
            hasher.update(slice)
            copied += Int64(count)
            remainingBytes = max(0, remainingBytes - Int64(count))
            if copied - reported >= progressStride {
                reported = copied
                var inFlight = progress
                inFlight.completedBytes = progress.completedBytes + copied
                request.onProgress(inFlight)
            }
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
                               sourcePath: entry.relativePath,
                               size: copied,
                               permissions: entry.permissions,
                               modifiedAt: entry.modifiedAt,
                               stagedName: stagedName,
                               headerPrefix: headerPrefix,
                               sha256: hasher.finalize())
    }

    // MARK: - SQLite consistency

    /// Groups the staged regular files into database units and, where a group is complete,
    /// runs the Level 2 structural check on a disposable copy. A group that cannot be
    /// checked is recorded with the reason and never presented as verified.
    ///
    /// The check runs before the manifest is built because the manifest carries the level,
    /// method and warnings, and the archive's own reopening compares the manifest it finds
    /// against the one this pass produced.
    private static func verifyDatabases(plan: MemberPlan,
                                        report: SKScanReport,
                                        unstablePaths: Set<String>,
                                        transaction: Transaction,
                                        home: SKAuthorizedRoot,
                                        request: Request,
                                        progress: inout Progress) throws -> [SKSQLiteGroup.Group] {
        let staged = plan.files.map {
            SKSQLiteGroup.StagedFile(sourcePath: $0.sourcePath,
                                     archivePath: $0.memberPath,
                                     size: $0.size,
                                     sha256: $0.sha256,
                                     headerPrefix: $0.headerPrefix,
                                     stagedName: $0.stagedName)
        }
        let collected = SKSQLiteGroup.collect(files: staged,
                                              report: report,
                                              unstablePaths: unstablePaths)
        guard !collected.isEmpty else { return [] }

        transaction.set(.checkingDatabases)
        progress = Progress(state: .checkingDatabases,
                            completedItems: 0,
                            totalItems: collected.count,
                            completedBytes: 0,
                            totalBytes: 0)
        request.onProgress(progress)

        let validation = try SKBackupStaging.openOrCreateDirectory(name: Transaction.validationDirectory,
                                                                   in: transaction.staging)
        defer { SKArchiveIO.close(validation) }

        var groups: [SKSQLiteGroup.Group] = []
        for (index, group) in collected.enumerated() {
            if request.isCancelled() { throw cancelled() }
            groups.append(verify(group: group,
                                 index: index,
                                 plan: plan,
                                 transaction: transaction,
                                 home: home,
                                 validation: validation,
                                 request: request))
            progress.completedItems += 1
            request.onProgress(progress)
        }
        return groups
    }

    /// One group's check. Only a complete group is opened: a copy missing a sidecar would
    /// describe a database the archive does not contain.
    private static func verify(group: SKSQLiteGroup.Group,
                               index: Int,
                               plan: MemberPlan,
                               transaction: Transaction,
                               home: SKAuthorizedRoot,
                               validation: Int32,
                               request: Request) -> SKSQLiteGroup.Group {
        guard group.complete, group.database.isPackaged else {
            return group.skippingVerification()
        }
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors { SKArchiveIO.close(descriptor) } }
        var inputs: [SKSQLiteInspector.Input] = []
        var copyBytes: Int64 = 0
        for member in group.members where member.isPackaged {
            guard let file = plan.files.first(where: { $0.sourcePath == member.sourcePath }),
                  let descriptor = try? SKArchiveIO.openReadOnly(name: file.stagedName,
                                                                 in: transaction.staging) else {
                return group.applying(SKSQLiteGroup.VerificationResult(outcome: .copyFailed))
            }
            descriptors.append(descriptor)
            copyBytes += max(0, file.size)
            inputs.append(SKSQLiteInspector.Input(copyName: "g\(index)-\(group.baseName)"
                                                    + (member.role.sidecarSuffix ?? ""),
                                                  isDatabase: member.role == .database,
                                                  descriptor: descriptor,
                                                  size: file.size))
        }
        if let available = try? SKBackupPreflight.availableBytes(home: home),
           !SKBackupPreflight.hasHeadroom(availableBytes: available, remainingBytes: copyBytes) {
            return group.applying(SKSQLiteGroup.VerificationResult(outcome: .storageInsufficient))
        }
        let result = SKSQLiteInspector.verify(inputs: inputs,
                                              in: validation,
                                              directoryPath: transaction.validationPath,
                                              isCancelled: request.isCancelled)
        return group.applying(result)
    }

    // MARK: - Archive pass

    private static func writeArchive(transaction: Transaction,
                                     plan: MemberPlan,
                                     documents: Documents,
                                     request: Request,
                                     progress: inout Progress) throws {
        let partial = try SKArchiveIO.createExclusive(name: transaction.partialName, in: transaction.staging)
        defer { SKArchiveIO.close(partial) }
        var writer = try SKZipWriter(descriptor: partial)

        _ = try writer.addPayload(path: SKManifest.manifestPath,
                                  bytes: documents.manifestBytes,
                                  permissions: 0o644,
                                  modifiedAt: documents.reference)
        countMember(&progress, request)
        _ = try writer.addPayload(path: SKManifest.hashIndexPath,
                                  bytes: documents.hashBytes,
                                  permissions: 0o644,
                                  modifiedAt: documents.reference)
        countMember(&progress, request)
        for directory in plan.orderedDirectories {
            _ = try writer.addDirectory(path: directory.memberPath,
                                        permissions: directory.permissions,
                                        modifiedAt: directory.modifiedAt)
            countMember(&progress, request)
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
            countMember(&progress, request)
        }
        try writer.finish()
    }

    /// Counts one written member: the archive pass reports members, not bytes, because a
    /// member's compressed size is not known until the deflater has run.
    private static func countMember(_ progress: inout Progress, _ request: Request) {
        progress.completedItems += 1
        request.onProgress(progress)
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
                                      groups: [SKSQLiteGroup.Group],
                                      unstableRoots: Set<String>,
                                      unstableFileCount: Int,
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

        // A database whose bytes are missing from the archive makes the whole archive
        // partial, even when the root it lived in could be read.
        let hasFailedGroup = groups.contains { $0.status == .failed }
        let databaseWarnings = groups.filter { $0.status != .verified }.count
        let reference = referenceTimestamp(request.createdAt)
        let manifest = SKManifestDocument(
            app: request.app,
            environment: request.environment,
            backup: SKManifestDocument.Backup(createdAt: request.createdAt,
                                              kind: request.kind,
                                              mode: request.mode,
                                              completeness: roots.allSatisfy(\.complete) && !hasFailedGroup
                                                  ? .complete : .partial,
                                              totalFiles: totalFiles,
                                              totalBytes: totalBytes,
                                              warningCount: report.unreadableCount + unstableFileCount
                                                  + databaseWarnings),
            roots: roots,
            sqliteGroups: groups.map(\.jsonValue),
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
            // Mask before narrowing: the shift alone still leaves 63 bits at shift 0.
            text.append(SKHex.digits[Int((value >> UInt64(shift)) & 0x0F)])
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

/// One transaction's private staging directory, the slot it renames the archive into, and
/// the cleanup that owns both. The slot is `stagingParent` itself: it holds at most one
/// archive, beside the transient transaction directories.
private final class Transaction {
    static let payloadDirectory = "payload"
    /// Disposable copies the SQLite check reads. They never leave staging, so a source is
    /// opened for reading only inside this tree.
    static let validationDirectory = "validation"

    let request: SKBackupCoordinator.Request
    let stagingParent: Int32
    let staging: Int32
    let partialName: String
    var archivePath: String { SKReservedPaths.stagingRoot + "/" + request.outputName }
    /// Absolute path of the validation directory, when the platform resolved one. SQLite
    /// opens by name, so without a path the Level 2 check reports unsupported.
    var validationPath: String? {
        guard let canonicalPath else { return nil }
        return canonicalPath + "/" + SKReservedPaths.stagingRoot + "/" + directoryName
            + "/" + Transaction.validationDirectory
    }

    private let directoryName: String
    private let canonicalPath: String?
    private var nextPayloadIndex = 0
    private var finalized = false

    init(home: SKAuthorizedRoot, request: SKBackupCoordinator.Request) throws {
        let identifier = SKBackupCoordinator.makeTransactionID()
        let parent = try SKBackupStaging.openOrCreatePath(SKReservedPaths.stagingRoot,
                                                          under: home.descriptor)
        let staging: Int32
        do {
            staging = try SKBackupStaging.openOrCreateDirectory(name: identifier, in: parent)
        } catch {
            SKArchiveIO.close(parent)
            throw error
        }
        self.request = request
        self.directoryName = identifier
        self.canonicalPath = home.canonicalPath
        self.partialName = String(request.outputName.dropLast(".sandboxark".count)) + ".partial"
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

    /// Publishes the verified `.partial` into the slot and drops this transaction's staging.
    /// The rename replaces the previous archive in one step, so the slot never holds two
    /// archives and a failure before the rename leaves the previous one untouched.
    func finalize() throws {
        try SKBackupStaging.rename(partialName,
                                   in: staging,
                                   to: request.outputName,
                                   in: stagingParent)
        finalized = true
        var failure: SKError?
        do {
            try SKArchiveIO.sync(stagingParent)
        } catch let error as SKError {
            failure = error
        }
        set(.readyToShare)
        do {
            try removeStaging()
        } catch let error as SKError {
            failure = failure ?? error
        }
        if let failure {
            throw SKError(code: failure.code,
                          stage: "cleanup",
                          retryable: failure.retryable,
                          userAction: failure.userAction,
                          underlyingCode: failure.underlyingCode,
                          recoveryState: SKBackupCoordinator.State.readyToShare.rawValue,
                          reason: failure.reason)
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
            // The published slot is never touched here: only a completed transaction may
            // replace the previous archive, so a failed run leaves it in place.
            try removeStaging()
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

    /// Removes this transaction's staging directory and everything it created. The shape is
    /// fixed — `payload/` holding flat positional copies, plus at most one `.partial` — so
    /// cleanup names those entries instead of walking an arbitrary tree. Entries the system
    /// already reclaimed are not a failure.
    private func removeStaging() throws {
        if let payload = try? SKBackupStaging.openDirectory(name: Transaction.payloadDirectory,
                                                           in: staging) {
            defer { SKArchiveIO.close(payload) }
            for index in 0..<nextPayloadIndex {
                try SKBackupStaging.unlink(String(index), in: payload)
            }
        }
        try SKBackupStaging.removeDirectory(name: Transaction.payloadDirectory, in: staging)
        if let validation = try? SKBackupStaging.openDirectory(name: Transaction.validationDirectory,
                                                              in: staging) {
            defer { SKArchiveIO.close(validation) }
            var names: [String] = []
            _ = try? SKPathResolver.enumerate(childrenOf: validation) { entry in
                if case .child(let name) = entry { names.append(name) }
                return true
            }
            for name in names { try SKBackupStaging.unlink(name, in: validation) }
        }
        try SKBackupStaging.removeDirectory(name: Transaction.validationDirectory, in: staging)
        try SKBackupStaging.unlink(partialName, in: staging)
        try SKBackupStaging.removeDirectory(name: directoryName, in: stagingParent)
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
        /// Home-relative source path; the manifest records members by archive path, but the
        /// SQLite grouping and the staging copies are keyed by the source they came from.
        var sourcePath: String
        var size: Int64
        var permissions: UInt16
        var modifiedAt: SKFileTimestamp
        var stagedName: String
        /// First bytes of the staged copy, so grouping never reopens the source.
        var headerPrefix: [UInt8]
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
    /// Opens a home-relative directory SandboxArk owns, creating every missing component.
    /// The caller owns the returned descriptor; the intermediates are closed here.
    static func openOrCreatePath(_ relativePath: String, under home: Int32) throws -> Int32 {
        var owned: [Int32] = []
        do {
            for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
                owned.append(try openOrCreateDirectory(name: String(component), in: owned.last ?? home))
            }
        } catch {
            for descriptor in owned { SKArchiveIO.close(descriptor) }
            throw error
        }
        guard let deepest = owned.last else { throw failure(EINVAL, "open") }
        for descriptor in owned.dropLast() { SKArchiveIO.close(descriptor) }
        return deepest
    }

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

    /// Replaces `to` with `from` in one step, even across directories on the same volume:
    /// a reader sees either the previous archive or the new one, never a partial file.
    static func rename(_ from: String, in fromDirectory: Int32,
                       to: String, in toDirectory: Int32) throws {
        guard renameat(fromDirectory, from, toDirectory, to) == 0 else {
            throw failure(errno, "rename")
        }
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

    private static func failure(_ code: Int32, _ operation: String) -> SKError {
        SKError(code: .storageDurabilityFailure,
                stage: "staging",
                retryable: true,
                underlyingCode: code,
                reason: "\(operation) failed")
    }
}
