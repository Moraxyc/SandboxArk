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
}
