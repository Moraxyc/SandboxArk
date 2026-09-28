#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Recursive read-only discovery over authorized roots, with per-root completeness
/// evidence, cancellation and resource limits.
///
/// Every item is reached through a verified parent descriptor, and an item that cannot
/// be inspected becomes an entry carrying its error rather than an abort, so one bad
/// file never hides the rest of the root.
enum SKScanner {
    /// Roots a standard scan covers, in display order.
    static let standardRootPaths = ["Documents", "Library/Application Support", "Library/Preferences"]

    struct Options: Sendable {
        var rootPaths: [String] = SKScanner.standardRootPaths
        var exclusionPolicy = SKExclusionPolicy.standard
        var pathLimits = SKPathResolver.PathLimits()
        /// Covers every item the walk touches, including excluded and unreadable ones,
        /// so memory is bounded by one number rather than by the tree's size.
        var maxEntries = SKResourceLimits.maxScanEntries
        var maxDepth = SKResourceLimits.maxScanDepth
        /// Polled between items, so a cancel stops the walk at an entry boundary.
        var isCancelled: @Sendable () -> Bool = { false }

        static let standard = Options()
    }

    // MARK: - Entry points

    /// Walks every configured root. One shared budget spans the roots, and a cancel or
    /// an exhausted budget stops the scan instead of starting the next root.
    static func scan(home: SKAuthorizedRoot, options: Options = .standard) -> SKScanReport {
        let budget = ScanBudget(maxItems: max(0, options.maxEntries))
        var roots: [SKScanRootResult] = []
        for rootPath in options.rootPaths {
            let result = scanRoot(rootPath, home: home, options: options, budget: budget)
            roots.append(result)
            if result.status == .cancelled || result.status == .entryLimitExceeded { break }
        }
        return SKScanReport(roots: roots)
    }

    /// Direct children of one directory, classified by the same rules as the walk.
    static func listDirectory(_ relativePath: String,
                              under home: SKAuthorizedRoot,
                              options: Options = .standard) -> SKDirectoryListing {
        let opened: (descriptor: Int32, identity: SKFileIdentity)
        do {
            opened = try SKPathResolver.openDirectory(atPath: relativePath, under: home, limits: options.pathLimits)
        } catch {
            return SKDirectoryListing(relativePath: relativePath, entries: [], status: .complete, error: asError(error))
        }
        defer { SKPathResolver.closeDescriptor(opened.descriptor) }

        let budget = ScanBudget(maxItems: max(0, options.maxEntries))
        var entries: [SKScanEntry] = []
        var status: SKScanStatus = .complete
        var listingError: SKError?
        do {
            try SKPathResolver.enumerate(childrenOf: opened.descriptor) { item in
                guard case .child(let name) = item else { return true }
                guard budget.consume() else { status = .entryLimitExceeded; return false }
                if options.isCancelled() { status = .cancelled; return false }
                let childPath = Self.childPath(component: name, in: relativePath)
                do {
                    entries.append(try childEntry(component: name, in: opened.descriptor, parentPath: relativePath, options: options))
                } catch {
                    entries.append(unreadableEntry(relativePath: childPath, error: asError(error)))
                }
                return true
            }
        } catch {
            listingError = asError(error)
        }
        return SKDirectoryListing(relativePath: relativePath,
                                  entries: entries.sorted { $0.relativePath < $1.relativePath },
                                  status: status,
                                  error: listingError)
    }

    // MARK: - Walk

    private static func scanRoot(_ relativePath: String,
                                 home: SKAuthorizedRoot,
                                 options: Options,
                                 budget: ScanBudget) -> SKScanRootResult {
        let accumulator = Accumulator(relativePath: relativePath, options: options, budget: budget)
        if options.isCancelled() {
            accumulator.status = .cancelled
            return accumulator.result()
        }
        do {
            let opened = try SKPathResolver.openDirectory(atPath: relativePath, under: home, limits: options.pathLimits)
            walk(directoryDescriptor: opened.descriptor, relativePath: relativePath, depth: 0, accumulator: accumulator)
            SKPathResolver.closeDescriptor(opened.descriptor)
        } catch let error as SKError where error.underlyingCode == ENOENT {
            // A root that does not exist in this container is absent, not unreadable.
        } catch {
            accumulator.recordUnreadable(relativePath: relativePath, error: asError(error))
        }
        return accumulator.result()
    }

    private static func walk(directoryDescriptor: Int32,
                             relativePath: String,
                             depth: Int,
                             accumulator: Accumulator) {
        do {
            try SKPathResolver.enumerate(childrenOf: directoryDescriptor) { item in
                guard !accumulator.stop else { return false }
                guard case .child(let name) = item else {
                    accumulator.recordUnrepresentableName()
                    return !accumulator.stop
                }
                guard accumulator.budget.consume() else {
                    accumulator.status = .entryLimitExceeded
                    accumulator.stop = true
                    return false
                }
                if accumulator.options.isCancelled() {
                    accumulator.status = .cancelled
                    accumulator.stop = true
                    return false
                }

                let childPath = childPath(component: name, in: relativePath)
                let entry: SKScanEntry
                do {
                    entry = try childEntry(component: name, in: directoryDescriptor, parentPath: relativePath, options: accumulator.options)
                } catch {
                    accumulator.recordUnreadable(relativePath: childPath, error: asError(error))
                    return !accumulator.stop
                }
                accumulator.append(entry)

                guard entry.excludedReason == nil, entry.kind == .directory else { return !accumulator.stop }
                guard depth + 1 <= accumulator.options.maxDepth else {
                    accumulator.status = .depthExceeded
                    accumulator.hasUnrepresentedSubtree = true
                    return !accumulator.stop
                }
                do {
                    let opened = try SKPathResolver.openDirectory(component: name, in: directoryDescriptor)
                    walk(directoryDescriptor: opened.descriptor, relativePath: childPath, depth: depth + 1, accumulator: accumulator)
                    SKPathResolver.closeDescriptor(opened.descriptor)
                } catch {
                    accumulator.markUnreadable(relativePath: childPath, error: asError(error))
                }
                return !accumulator.stop
            }
        } catch {
            accumulator.markUnreadable(relativePath: relativePath, error: asError(error))
        }
    }

    // MARK: - Items

    /// Classifies one child without following it and applies the exclusion policy.
    private static func childEntry(component: String,
                                   in parentDescriptor: Int32,
                                   parentPath: String,
                                   options: Options) throws -> SKScanEntry {
        let childPath = childPath(component: component, in: parentPath)
        guard childPath.utf8.count <= options.pathLimits.pathBytes else {
            throw SKPathResolver.invalidPathError("path exceeds \(options.pathLimits.pathBytes) bytes")
        }
        let identity = try SKPathResolver.classify(component: component, in: parentDescriptor)
        let reason: SKExclusionReason?
        switch options.exclusionPolicy.decision(homeRelativePath: childPath, kind: identity.kind) {
        case .include: reason = nil
        case .exclude(let value): reason = value
        }
        return SKScanEntry(relativePath: childPath,
                           kind: identity.kind,
                           size: identity.size,
                           permissions: identity.permissions,
                           modifiedAt: identity.modifiedAt,
                           excludedReason: reason,
                           error: nil)
    }

    private static func unreadableEntry(relativePath: String, error: SKError) -> SKScanEntry {
        SKScanEntry(relativePath: relativePath,
                    kind: .unknown,
                    size: 0,
                    permissions: 0,
                    modifiedAt: SKFileTimestamp(seconds: 0, nanoseconds: 0),
                    excludedReason: nil,
                    error: error)
    }

    private static func childPath(component: String, in parentPath: String) -> String {
        parentPath.isEmpty ? component : parentPath + "/" + component
    }

    private static func asError(_ error: Error) -> SKError {
        (error as? SKError) ?? SKError(code: .filesystemUnreadable, stage: "scan")
    }

    // MARK: - Budget

    final class ScanBudget {
        private let maxItems: Int
        private(set) var used = 0

        init(maxItems: Int) {
            self.maxItems = maxItems
        }

        func consume() -> Bool {
            guard used < maxItems else { return false }
            used += 1
            return true
        }
    }

    // MARK: - Accumulator

    final class Accumulator {
        let relativePath: String
        let options: Options
        let budget: ScanBudget

        var entries: [SKScanEntry] = []
        var includedFiles = 0
        var includedBytes: Int64 = 0
        var unreadableCount = 0
        var excludedCounts: [SKExclusionReason: Int] = [:]
        var hasUnrepresentedSubtree = false
        var status: SKScanStatus = .complete
        var stop = false

        init(relativePath: String, options: Options, budget: ScanBudget) {
            self.relativePath = relativePath
            self.options = options
            self.budget = budget
        }

        func append(_ entry: SKScanEntry) {
            entries.append(entry)
            if let reason = entry.excludedReason {
                excludedCounts[reason, default: 0] += 1
                if entry.kind == .directory { hasUnrepresentedSubtree = true }
            } else if entry.error == nil, entry.kind == .regular {
                includedFiles += 1
                includedBytes += max(0, entry.size)
            }
        }

        /// An item that could not be inspected at all: no usable metadata exists, so
        /// the error is the only evidence it left behind.
        func recordUnreadable(relativePath: String, error: SKError) {
            unreadableCount += 1
            guard budget.consume() else {
                status = .entryLimitExceeded
                stop = true
                return
            }
            entries.append(unreadableEntry(relativePath: relativePath, error: error))
        }

        func recordUnrepresentableName() {
            unreadableCount += 1
            guard budget.consume() else {
                status = .entryLimitExceeded
                stop = true
                return
            }
        }

        /// The item was listed successfully, so its entry already exists; only the
        /// failure to descend is new information.
        func markUnreadable(relativePath: String, error: SKError) {
            unreadableCount += 1
            if let index = entries.lastIndex(where: { $0.relativePath == relativePath }) {
                entries[index].error = error
            }
        }

        func result() -> SKScanRootResult {
            SKScanRootResult(relativePath: relativePath,
                             entries: entries.sorted { $0.relativePath < $1.relativePath },
                             status: status,
                             includedFiles: includedFiles,
                             includedBytes: includedBytes,
                             unreadableCount: unreadableCount,
                             excludedCounts: excludedCounts,
                             hasUnrepresentedSubtree: hasUnrepresentedSubtree)
        }
    }
}

/// Why a walk stopped early, or that it finished.
enum SKScanStatus: String, Sendable {
    case complete
    case cancelled
    case entryLimitExceeded = "entry-limit-exceeded"
    case depthExceeded = "depth-exceeded"
}

/// One item the walk touched. `error` and `excludedReason` are mutually exclusive with
/// a successful include, and together they carry everything the UI reports.
struct SKScanEntry: Sendable {
    let relativePath: String
    let kind: SKFileKind
    let size: Int64
    let permissions: UInt16
    let modifiedAt: SKFileTimestamp
    let excludedReason: SKExclusionReason?
    var error: SKError?
}

/// Result for one root. `isComplete` and `isMirrorSafe` are the evidence the manifest
/// records, so they are computed from the walk rather than from a caller's summary.
struct SKScanRootResult: Sendable {
    let relativePath: String
    let entries: [SKScanEntry]
    let status: SKScanStatus
    let includedFiles: Int
    let includedBytes: Int64
    let unreadableCount: Int
    let excludedCounts: [SKExclusionReason: Int]
    /// True when an excluded directory subtree is absent from `entries`, so a mirror
    /// restore could not compute a delete set for this root.
    let hasUnrepresentedSubtree: Bool

    var isComplete: Bool {
        status == .complete && unreadableCount == 0
            && excludedCounts[.symlink] == nil && excludedCounts[.specialFile] == nil
    }

    var isMirrorSafe: Bool {
        isComplete && !hasUnrepresentedSubtree
    }

    func excludedCount(_ reason: SKExclusionReason) -> Int {
        excludedCounts[reason] ?? 0
    }
}

struct SKScanReport: Sendable {
    let roots: [SKScanRootResult]

    var status: SKScanStatus {
        if roots.contains(where: { $0.status == .cancelled }) { return .cancelled }
        if roots.contains(where: { $0.status == .entryLimitExceeded }) { return .entryLimitExceeded }
        if roots.contains(where: { $0.status == .depthExceeded }) { return .depthExceeded }
        return .complete
    }

    var includedFiles: Int { roots.reduce(0) { $0 + $1.includedFiles } }
    var includedBytes: Int64 { roots.reduce(0) { $0 + $1.includedBytes } }
    var unreadableCount: Int { roots.reduce(0) { $0 + $1.unreadableCount } }
    var isComplete: Bool { roots.allSatisfy(\.isComplete) }

    var excludedCounts: [SKExclusionReason: Int] {
        var totals: [SKExclusionReason: Int] = [:]
        for root in roots {
            for (reason, count) in root.excludedCounts {
                totals[reason, default: 0] += count
            }
        }
        return totals
    }

    func entry(relativePath: String) -> SKScanEntry? {
        for root in roots {
            if let match = root.entries.first(where: { $0.relativePath == relativePath }) { return match }
        }
        return nil
    }
}

struct SKDirectoryListing: Sendable {
    let relativePath: String
    let entries: [SKScanEntry]
    let status: SKScanStatus
    let error: SKError?
}
