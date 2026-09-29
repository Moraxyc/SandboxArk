#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(SQLite3)
import SQLite3
#endif

/// Level 2 verification: copy an already hashed payload into a disposable directory, open
/// the copy read-only and run a full `PRAGMA integrity_check` there. A source database is
/// never checkpointed, vacuumed, or opened for writing.
///
/// The check is deliberately best effort. When the toolchain exposes the system `SQLite3`
/// module the copy is really opened; otherwise the result is `unsupported`, which the group
/// records as a warning instead of a pass. A passing check means the copy is structurally
/// sound; it does not describe the app's own invariants, and it never raises a group above
/// Level 2.
enum SKSQLiteInspector {
    struct Budget: Sendable {
        /// Bytes this check may copy before it gives up and leaves the group unverified.
        var maximumCopyBytes: Int64 = 512 * 1024 * 1024
        /// Wall-clock ceiling for one group's check.
        var timeoutNanoseconds: UInt64 = 20 * 1_000_000_000
        /// How long the copy may wait on a locked database before SQLite reports busy.
        var busyTimeoutMilliseconds: Int32 = 2_000
        /// Virtual-machine instructions between two deadline checks.
        var progressSteps: Int32 = 2_000

        static let standard = Budget()
    }

    /// One member of the disposable copy. `copyName` is the name SQLite will see, so a
    /// sidecar copy must be the database copy's name plus its suffix or SQLite will not
    /// find it. The caller keeps every descriptor open until `verify` returns.
    struct Input: Sendable {
        var copyName: String
        var isDatabase: Bool
        var descriptor: Int32
        var size: Int64
    }

    /// Copies `inputs` into `validationDirectory` and checks the database copy. `directoryPath`
    /// is the absolute path of that directory, which SQLite needs because it opens by name;
    /// without one the check is reported unsupported rather than guessed at.
    static func verify(inputs: [Input],
                       in validationDirectory: Int32,
                       directoryPath: String?,
                       budget: Budget = .standard,
                       isCancelled: @escaping () -> Bool) -> SKSQLiteGroup.VerificationResult {
        guard let database = inputs.first(where: { $0.isDatabase }) else {
            return SKSQLiteGroup.VerificationResult(outcome: .notRun)
        }
        #if canImport(SQLite3)
        let version = String(cString: sqlite3_libversion())
        guard isPlainName(database.copyName),
              inputs.allSatisfy({ isPlainName($0.copyName) }),
              let directoryPath else {
            return SKSQLiteGroup.VerificationResult(outcome: .unsupported, sqliteVersion: version)
        }
        let totalBytes = inputs.reduce(Int64(0)) { $0 + max(0, $1.size) }
        guard totalBytes <= budget.maximumCopyBytes else {
            return SKSQLiteGroup.VerificationResult(outcome: .budgetExhausted, sqliteVersion: version)
        }
        for input in inputs {
            do {
                try copy(input, into: validationDirectory)
            } catch let error as SKError {
                let outcome: SKSQLiteGroup.VerificationOutcome =
                    error.underlyingCode == ENOSPC ? .storageInsufficient : .copyFailed
                return SKSQLiteGroup.VerificationResult(outcome: outcome,
                                                        sqliteVersion: version,
                                                        sqliteCode: error.underlyingCode,
                                                        errorCode: error.code)
            } catch {
                return SKSQLiteGroup.VerificationResult(outcome: .copyFailed, sqliteVersion: version)
            }
        }
        if isCancelled() {
            return SKSQLiteGroup.VerificationResult(outcome: .cancelRequested, sqliteVersion: version)
        }
        return check(databaseName: database.copyName,
                     directoryPath: directoryPath,
                     version: version,
                     budget: budget,
                     isCancelled: isCancelled)
        #else
        _ = database
        _ = inputs
        _ = validationDirectory
        _ = directoryPath
        _ = budget
        _ = isCancelled
        return SKSQLiteGroup.VerificationResult(outcome: .unsupported)
        #endif
    }

    // MARK: - Disposable copy

    private static func copy(_ input: Input, into directory: Int32) throws {
        let target = try SKArchiveIO.createExclusive(name: input.copyName, in: directory)
        defer { SKArchiveIO.close(target) }
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: SKZipWriter.chunkBytes)
        while offset < input.size {
            let count = try SKArchiveIO.readChunk(from: input.descriptor, into: &buffer)
            if count == 0 { break }
            try SKArchiveIO.write(buffer[0..<count], at: offset, to: target)
            offset += Int64(count)
        }
        guard offset == input.size else {
            throw SKError(code: .storageDurabilityFailure,
                          stage: "sqliteVerification",
                          reason: "the validation copy ended early")
        }
        try SKArchiveIO.sync(target)
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= SKResourceLimits.maxScanPathComponentBytes
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
            && name != "." && name != ".."
    }
}

#if canImport(SQLite3)
extension SKSQLiteInspector {
    /// The check itself, in its own type so the C progress handler has a stable context.
    private static func check(databaseName: String,
                              directoryPath: String,
                              version: String,
                              budget: Budget,
                              isCancelled: @escaping () -> Bool) -> SKSQLiteGroup.VerificationResult {
        var handle: OpaquePointer?
        let path = directoryPath + "/" + databaseName
        let opened = path.withCString { sqlite3_open_v2($0, &handle, SQLITE_OPEN_READONLY, nil) }
        guard opened == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return SKSQLiteGroup.VerificationResult(outcome: outcome(forOpen: opened),
                                                    sqliteVersion: version,
                                                    sqliteCode: opened,
                                                    errorCode: errorCode(forOpen: opened))
        }
        defer { sqlite3_close_v2(handle) }
        _ = sqlite3_busy_timeout(handle, budget.busyTimeoutMilliseconds)

        let state = ProgressState(isCancelled: isCancelled,
                                  deadline: SKFileTimestamp.monotonicNanoseconds() &+ budget.timeoutNanoseconds)
        return withExtendedLifetime(state) {
            sqlite3_progress_handler(handle, budget.progressSteps, skSQLiteProgress,
                                     Unmanaged.passUnretained(state).toOpaque())
            defer { sqlite3_progress_handler(handle, 0, nil, nil) }
            return integrityCheck(handle: handle, version: version, state: state)
        }
    }

    private static func integrityCheck(handle: OpaquePointer,
                                       version: String,
                                       state: ProgressState) -> SKSQLiteGroup.VerificationResult {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let code = sqlite3_errcode(handle)
            return SKSQLiteGroup.VerificationResult(outcome: outcome(forOpen: code),
                                                    sqliteVersion: version,
                                                    sqliteCode: code,
                                                    errorCode: errorCode(forOpen: code))
        }
        defer { sqlite3_finalize(statement) }

        var rows = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                rows += 1
                guard let text = sqlite3_column_text(statement, 0), String(cString: text) == "ok" else {
                    return SKSQLiteGroup.VerificationResult(outcome: .failed,
                                                            sqliteVersion: version,
                                                            sqliteCode: step,
                                                            errorCode: .sqliteIntegrityCheckFailed)
                }
                continue
            }
            if step == SQLITE_DONE {
                // An empty result is not a pass: SQLite always reports at least one row.
                guard rows > 0 else {
                    return SKSQLiteGroup.VerificationResult(outcome: .failed,
                                                            sqliteVersion: version,
                                                            sqliteCode: step,
                                                            errorCode: .sqliteIntegrityCheckFailed)
                }
                return SKSQLiteGroup.VerificationResult(outcome: .verified,
                                                        sqliteVersion: version,
                                                        sqliteCode: step)
            }
            if step == SQLITE_INTERRUPT { return interrupted(state: state, version: version) }
            return SKSQLiteGroup.VerificationResult(outcome: outcome(forOpen: step),
                                                    sqliteVersion: version,
                                                    sqliteCode: step,
                                                    errorCode: errorCode(forOpen: step))
        }
    }

    private static func interrupted(state: ProgressState,
                                    version: String) -> SKSQLiteGroup.VerificationResult {
        let outcome: SKSQLiteGroup.VerificationOutcome
        let code: SKErrorCode?
        switch state.stop {
        case .cancelled:
            outcome = .cancelRequested
            code = .cancelled
        case .timedOut:
            outcome = .timedOut
            code = .sqliteVerificationTimedOut
        case .budgetExhausted, .none:
            outcome = .budgetExhausted
            code = .sqliteVerificationTimedOut
        }
        return SKSQLiteGroup.VerificationResult(outcome: outcome,
                                                sqliteVersion: version,
                                                sqliteCode: SQLITE_INTERRUPT,
                                                errorCode: code)
    }

    private static func outcome(forOpen code: Int32) -> SKSQLiteGroup.VerificationOutcome {
        switch code {
        case SQLITE_OK: .notRun
        case SQLITE_BUSY, SQLITE_LOCKED: .busy
        default: .failed
        }
    }

    private static func errorCode(forOpen code: Int32) -> SKErrorCode {
        switch code {
        case SQLITE_BUSY, SQLITE_LOCKED: .sqliteBusy
        default: .sqliteOpenFailed
        }
    }

    /// Why the progress handler aborted the statement; SQLite reports all three as one code.
    fileprivate enum StopReason {
        case cancelled, timedOut, budgetExhausted
    }

    /// Shared with the C callback, which cannot capture. It is only ever read after the
    /// statement returns, so one non-atomic flag is enough.
    fileprivate final class ProgressState {
        let isCancelled: () -> Bool
        let deadline: UInt64
        fileprivate var stop: StopReason?
        private var checks = 0
        /// A second ceiling so a database that answers the deadline too slowly still stops.
        private let maximumChecks = 1_000_000

        init(isCancelled: @escaping () -> Bool, deadline: UInt64) {
            self.isCancelled = isCancelled
            self.deadline = deadline
        }

        func shouldStop() -> Bool {
            if isCancelled() { stop = .cancelled; return true }
            if SKFileTimestamp.monotonicNanoseconds() >= deadline { stop = .timedOut; return true }
            checks += 1
            if checks >= maximumChecks { stop = .budgetExhausted; return true }
            return false
        }
    }
}

/// Top-level so it converts to a C function pointer: a Swift closure that captured would not.
private func skSQLiteProgress(_ context: UnsafeMutableRawPointer?) -> Int32 {
    guard let context else { return 0 }
    let state = Unmanaged<SKSQLiteInspector.ProgressState>.fromOpaque(context).takeUnretainedValue()
    return state.shouldStop() ? 1 : 0
}
#endif
