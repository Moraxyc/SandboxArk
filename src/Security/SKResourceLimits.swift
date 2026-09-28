/// Hard limits and user-confirmable warnings for untrusted archive input.
///
/// Hard limits are never raised by a user confirmation; the 4 GiB total and
/// 100:1 ratio thresholds only gate extraction behind an explicit confirmation.
enum SKResourceLimits {
    static let maxArchiveMembers = 100_000
    static let maxManifestBytes = 1 * 1024 * 1024
    static let maxHashIndexBytes = 64 * 1024 * 1024
    static let maxArchivePathBytes = 4096
    static let uncompressedTotalWarningBytes = 4 * 1024 * 1024 * 1024
    static let compressionRatioWarning = 100

    /// Browse limits. One entry limit covers every emitted item (directories, excluded
    /// items and unreadable items), so a scan's memory stays bounded by one number.
    static let maxScanEntries = 100_000
    static let maxScanPathBytes = 4096
    static let maxScanPathComponentBytes = 255
    /// Bound on recursion; a path cannot nest deeper than this many components.
    static let maxScanDepth = 256

    /// A preview reads one bounded buffer and never the whole file.
    static let maxPreviewBytes = 256 * 1024
    static let previewChunkBytes = 64 * 1024
}
