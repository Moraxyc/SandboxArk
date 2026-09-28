#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Backup preflight: worst-case space estimate for a scan and the verdict that decides
/// whether a backup may start.
enum SKBackupPreflight {
    /// Worst-case space budget for one backup transaction.
    struct Budget: Sendable {
        /// Free space left untouched so a failed backup never fills the container.
        var minimumFreeBytes = SKResourceLimits.backupMinimumFreeBytes
        /// Archive member names carry this prefix before the root-relative path.
        var archivePathPrefix = SKManifest.homeRoot
        var localHeaderBytes: Int64 = 30
        var centralHeaderBytes: Int64 = 46
        /// Emitted on every member so a size crossing the 32-bit boundary never changes
        /// the local layout.
        var zip64ExtraFieldBytes: Int64 = 20
        var manifestBytesPerRoot = SKResourceLimits.backupManifestBytesPerRoot
        var manifestFloorBytes = SKResourceLimits.backupManifestFloorBytes
        var hashEntryOverheadBytes = SKResourceLimits.backupHashEntryOverheadBytes
        var hashIndexFloorBytes = SKResourceLimits.backupHashIndexFloorBytes
        var perTransactionOverheadBytes = SKResourceLimits.backupPerTransactionOverheadBytes

        static let standard = Budget()
    }

    struct Estimate: Sendable {
        let includedFiles: Int
        let directoryMembers: Int
        let sourceBytes: Int64
        /// Uncompressed payload copies held in this transaction's staging directory.
        let stagingBytes: Int64
        /// Worst-case archive size, including per-member headers.
        let archiveBytes: Int64
        /// manifest.json plus hashes.json, derived from the members actually scanned.
        let metadataBytes: Int64
        let reserveBytes: Int64

        var members: Int { includedFiles + directoryMembers }
        var totalBytes: Int64 { stagingBytes + archiveBytes + metadataBytes }
        /// Space the transaction needs before it may start: working set plus the reserve.
        var requiredBytes: Int64 { totalBytes + reserveBytes }
    }

    enum Verdict: Sendable {
        case proceed(Estimate)
        case blocked(Estimate, SKError)
    }

    /// Builds the worst-case estimate from the members a scan would actually archive,
    /// falling back to the uncompressed total when a deflated size cannot be bounded.
    static func estimate(report: SKScanReport, budget: Budget = .standard) -> Estimate {
        let prefixBytes = Int64(budget.archivePathPrefix.utf8.count + 1)
        var includedFiles = 0
        var directoryMembers = 0
        var sourceBytes: Int64 = 0
        var nameBytes: Int64 = 0
        var indexEntryBytes: Int64 = 0

        for root in report.roots {
            for entry in root.entries where entry.excludedReason == nil && entry.error == nil {
                let memberNameBytes = prefixBytes + Int64(entry.relativePath.utf8.count)
                nameBytes += memberNameBytes
                indexEntryBytes += memberNameBytes + budget.hashEntryOverheadBytes
                if entry.kind == .directory {
                    directoryMembers += 1
                } else if entry.kind == .regular {
                    includedFiles += 1
                    sourceBytes += entry.size
                }
            }
        }

        let members = Int64(includedFiles + directoryMembers)
        let perMemberHeader = budget.localHeaderBytes + budget.centralHeaderBytes
            + 2 * budget.zip64ExtraFieldBytes
        let archiveBytes = sourceBytes + members * perMemberHeader + nameBytes
            + budget.perTransactionOverheadBytes
        let manifestBytes = budget.manifestFloorBytes
            + Int64(report.roots.count) * budget.manifestBytesPerRoot
        let hashIndexBytes = budget.hashIndexFloorBytes + indexEntryBytes

        return Estimate(includedFiles: includedFiles,
                        directoryMembers: directoryMembers,
                        sourceBytes: sourceBytes,
                        stagingBytes: sourceBytes,
                        archiveBytes: archiveBytes,
                        metadataBytes: manifestBytes + hashIndexBytes,
                        reserveBytes: budget.minimumFreeBytes)
    }

    /// Free space on the volume holding this root, read through the already open
    /// directory descriptor.
    static func availableBytes(home: SKAuthorizedRoot) throws -> Int64 {
        var fileSystem = statvfs()
        guard fstatvfs(home.descriptor, &fileSystem) == 0 else {
            throw SKError(code: .filesystemUnreadable,
                          stage: "preflight",
                          underlyingCode: errno,
                          reason: "free space could not be read")
        }
        let blockSize = Int64(fileSystem.f_frsize)
        let available = Int64(fileSystem.f_bavail)
        guard blockSize > 0, available > 0 else { return 0 }
        return blockSize * available
    }

    static func decide(_ estimate: Estimate,
                       availableBytes: Int64,
                       budget: Budget = .standard) -> Verdict {
        guard availableBytes < estimate.requiredBytes else { return .proceed(estimate) }
        let shortfall = estimate.requiredBytes - availableBytes
        let error = SKError(code: .storageInsufficientSpace,
                            stage: "preflight",
                            retryable: true,
                            userAction: "Free space, or back up fewer roots.",
                            reason: "needs \(estimate.totalBytes) bytes plus a"
                                + " \(budget.minimumFreeBytes) byte reserve; short by \(shortfall)")
        return .blocked(estimate, error)
    }

    /// Re-checked before each chunk copy, because free space can shrink while a backup runs.
    static func hasHeadroom(availableBytes: Int64,
                            remainingBytes: Int64,
                            budget: Budget = .standard) -> Bool {
        availableBytes >= remainingBytes + budget.minimumFreeBytes
    }

    /// Estimate and decide in one step.
    static func run(report: SKScanReport,
                    home: SKAuthorizedRoot,
                    budget: Budget = .standard) throws -> Estimate {
        let estimate = estimate(report: report, budget: budget)
        let available = try availableBytes(home: home)
        switch decide(estimate, availableBytes: available, budget: budget) {
        case .proceed(let estimate):
            return estimate
        case .blocked(_, let error):
            throw error
        }
    }
}
