/// Host-relative paths permanently reserved for SandboxArk's own state: never backup
/// sources, never inside a `.sandboxark`, never restore targets.
enum SKReservedPaths {
    /// Long-lived private state: restore journal, snapshots, history, diagnostics.
    static let applicationSupport = "Library/Application Support/SandboxArk"
    /// Per-operation staging only; transaction IDs live here and never reach the format.
    static let stagingRoot = "tmp/SandboxArk"

    static let all = [applicationSupport, stagingRoot]

    /// True when a home-relative path is SandboxArk's own state, so it can never be a
    /// backup source, an archive member or a restore target.
    static func isReserved(homeRelativePath path: String) -> Bool {
        all.contains { SKSecurityPolicy.path(path, matchesPrefix: $0) }
    }
}
