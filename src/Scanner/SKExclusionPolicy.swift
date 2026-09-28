/// Fixed reason codes for items a scan leaves out. They are the vocabulary the manifest
/// records as `excludedCounts`, so raw values are part of the format contract.
enum SKExclusionReason: String, Sendable, CaseIterable {
    case cache = "cache"
    case tmp = "tmp"
    case logs = "logs"
    case sandboxArkPrivate = "sandboxark-private"
    case keychain = "keychain"
    case credentialStore = "credential-store"
    case symlink = "symlink"
    case specialFile = "special-file"
    case userOptOut = "user-opt-out"
}

/// Data categories that stay out of a standard scan until the user selects them for the
/// run. Both carry session state, so they are never enabled implicitly.
enum SKOptInCategory: String, Sendable, CaseIterable {
    case webKit = "webkit"
    case cookies = "cookies"

    var homeRelativeRoot: String {
        switch self {
        case .webKit: "Library/WebKit"
        case .cookies: "Library/Cookies"
        }
    }
}

enum SKExclusionDecision: Equatable, Sendable {
    case include
    case exclude(SKExclusionReason)
}

/// Default exclude and opt-in rules: Caches, tmp and Logs are excluded, Cookies and
/// WebKit data are opt-in per category, and reserved roots are always excluded.
///
/// The rule set is data so a later phase can relax exactly one category after user
/// confirmation without changing the traversal.
struct SKExclusionPolicy: Sendable {
    var optIn: Set<SKOptInCategory>

    /// 0.1.0 standard scan: every opt-in category is off.
    static let standard = SKExclusionPolicy(optIn: [])

    private static let cachePrefixes = ["Library/Caches"]
    private static let tmpPrefixes = ["tmp"]
    private static let logsPrefixes = ["Library/Logs"]
    /// Credential stores are excluded wherever they appear, not only under one parent:
    /// a nested `.ssh` or `credentials` directory is as sensitive as the canonical one.
    private static let credentialStoreComponents = ["credentials", ".credentials", ".ssh", ".aws", ".gnupg", ".netrc"]
    private static let keychainComponents = ["keychain", "keychains"]
    private static let keychainComponentSuffix = ".keychain-db"

    func decision(homeRelativePath path: String, kind: SKFileKind) -> SKExclusionDecision {
        if SKReservedPaths.isReserved(homeRelativePath: path) { return .exclude(.sandboxArkPrivate) }
        if SKSecurityPolicy.path(path, hasComponentNamed: Self.keychainComponents)
            || SKSecurityPolicy.path(path, hasComponentEndingWith: Self.keychainComponentSuffix) {
            return .exclude(.keychain)
        }
        if SKSecurityPolicy.path(path, hasComponentNamed: Self.credentialStoreComponents) {
            return .exclude(.credentialStore)
        }
        for prefix in Self.cachePrefixes where SKSecurityPolicy.path(path, matchesPrefix: prefix) {
            return .exclude(.cache)
        }
        for prefix in Self.tmpPrefixes where SKSecurityPolicy.path(path, matchesPrefix: prefix) {
            return .exclude(.tmp)
        }
        for prefix in Self.logsPrefixes where SKSecurityPolicy.path(path, matchesPrefix: prefix) {
            return .exclude(.logs)
        }
        for category in SKOptInCategory.allCases where !optIn.contains(category) {
            if SKSecurityPolicy.path(path, matchesPrefix: category.homeRelativeRoot) {
                return .exclude(.userOptOut)
            }
        }
        switch kind {
        case .symlink: return .exclude(.symlink)
        case .special, .unknown: return .exclude(.specialFile)
        case .regular, .directory: return .include
        }
    }
}
