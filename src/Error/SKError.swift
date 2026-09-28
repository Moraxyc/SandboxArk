import Foundation

/// Stable error domain shared by every module boundary.
let SKErrorDomain = "SKErrorDomain"

/// Coarse routing category. Control flow keys off `SKErrorCode`, never off localized text.
enum SKErrorCategory: String, Sendable {
    case filesystem
    case permission
    case archive
    case integrity
    case sqlite
    case manifest
    case compatibility
    case restore
    case storage
    case cancelled
}

/// Stable error codes. The raw values are part of the API.
enum SKErrorCode: String, Sendable {
    case filesystemUnreadable = "SKFilesystemErrorUnreadable"
    case filesystemChangedDuringRead = "SKFilesystemErrorChangedDuringRead"
    case filesystemSymlinkEscape = "SKFilesystemErrorSymlinkEscape"
    case filesystemReservedPathConflict = "SKFilesystemErrorReservedPathConflict"

    case permissionScopeExpired = "SKPermissionErrorScopeExpired"
    case permissionEntitlementMismatch = "SKPermissionErrorEntitlementMismatch"

    case archiveCorrupt = "SKArchiveErrorCorrupt"
    case archivePathTraversal = "SKArchiveErrorPathTraversal"
    case archiveLimitExceeded = "SKArchiveErrorLimitExceeded"

    case integrityHashMismatch = "SKIntegrityErrorHashMismatch"
    case integrityManifestInvalid = "SKIntegrityErrorManifestInvalid"

    case sqliteOpenFailed = "SKSQLiteErrorOpenFailed"
    case sqliteBusy = "SKSQLiteErrorBusy"
    case sqliteIntegrityCheckFailed = "SKSQLiteErrorIntegrityCheckFailed"
    case sqliteVerificationTimedOut = "SKSQLiteErrorVerificationTimedOut"

    case manifestUnsupportedVersion = "SKManifestErrorUnsupportedVersion"
    case manifestMigrationFailed = "SKManifestErrorMigrationFailed"

    case compatibilityBundleIdentifierMismatch = "SKCompatibilityErrorBundleIdentifierMismatch"
    case compatibilityVersionRisk = "SKCompatibilityErrorVersionRisk"

    case restoreQuiescenceUnavailable = "SKRestoreErrorQuiescenceUnavailable"
    case restoreSnapshotFailed = "SKRestoreErrorSnapshotFailed"
    case restorePlanStale = "SKRestoreErrorPlanStale"
    case restoreConflict = "SKRestoreErrorConflict"
    case restoreRollbackRequired = "SKRestoreErrorRollbackRequired"
    case restoreJournalCorrupt = "SKRestoreErrorJournalCorrupt"

    case storageInsufficientSpace = "SKStorageErrorInsufficientSpace"
    case storageDurabilityFailure = "SKStorageErrorDurabilityFailure"

    case cancelled = "SKOperationCancelled"

    var category: SKErrorCategory {
        switch self {
        case .filesystemUnreadable, .filesystemChangedDuringRead,
             .filesystemSymlinkEscape, .filesystemReservedPathConflict:
            .filesystem
        case .permissionScopeExpired, .permissionEntitlementMismatch:
            .permission
        case .archiveCorrupt, .archivePathTraversal, .archiveLimitExceeded:
            .archive
        case .integrityHashMismatch, .integrityManifestInvalid:
            .integrity
        case .sqliteOpenFailed, .sqliteBusy, .sqliteIntegrityCheckFailed,
             .sqliteVerificationTimedOut:
            .sqlite
        case .manifestUnsupportedVersion, .manifestMigrationFailed:
            .manifest
        case .compatibilityBundleIdentifierMismatch, .compatibilityVersionRisk:
            .compatibility
        case .restoreQuiescenceUnavailable, .restoreSnapshotFailed, .restorePlanStale,
             .restoreConflict, .restoreRollbackRequired, .restoreJournalCorrupt:
            .restore
        case .storageInsufficientSpace, .storageDurabilityFailure:
            .storage
        case .cancelled:
            .cancelled
        }
    }
}

/// Structured error crossing module boundaries.
///
/// Paths stay sandbox-relative; absolute host paths, file contents and credential
/// values never appear here, because they would reach logs and user-facing reports.
/// `stage` and `recoveryState` use the vocabularies defined by the owning engines.
struct SKError: Error, Sendable {
    let code: SKErrorCode
    var operationID: String?
    var stage: String?
    var relativePath: String?
    var retryable: Bool = false
    var userAction: String?
    var underlyingCode: Int32?
    var recoveryState: String?
    var reason: String?
}
