/// Host-relative paths permanently reserved for SandboxArk's own state.
///
/// They are never backup sources, never appear inside a `.sandboxark`, and are
/// never restore targets.
enum SKReservedPaths {
    /// Long-lived private state: restore journal, snapshots, history, diagnostics.
    static let applicationSupport = "Library/Application Support/SandboxArk"
    /// Per-operation staging only; transaction IDs live here and never reach the format.
    static let stagingRoot = "tmp/SandboxArk"

    static let all = [applicationSupport, stagingRoot]
}
