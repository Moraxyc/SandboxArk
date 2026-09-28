/// Policy decisions shared by scanning, archiving and restore: Keychain exclusion,
/// per-directory opt-in, entitlement checks and reserved-root ownership conflicts.
enum SKSecurityPolicy {
    /// Addresses in the sandbox are compared the way the volume compares them. iOS
    /// containers live on case-insensitive volumes, so `library/caches` and
    /// `Library/Caches` are the same directory and a rule that only matches one
    /// spelling is not a rule. Comparison stays on ASCII bytes: that is the folding the
    /// volume performs, and it does not depend on locale or Unicode tables.
    static func equalsIgnoringASCIICase(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.utf8.count == rhs.utf8.count else { return false }
        for (left, right) in zip(lhs.utf8, rhs.utf8) where foldASCIICase(left) != foldASCIICase(right) {
            return false
        }
        return true
    }

    /// True when `path` is `prefix` or sits below it, comparing whole components only.
    /// A prefix match never treats `Library/Caches-other` as `Library/Caches`.
    static func path(_ path: String, matchesPrefix prefix: String) -> Bool {
        if equalsIgnoringASCIICase(path, prefix) { return true }
        guard path.utf8.count > prefix.utf8.count else { return false }
        let head = String(decoding: path.utf8.prefix(prefix.utf8.count), as: UTF8.self)
        guard equalsIgnoringASCIICase(head, prefix) else { return false }
        let boundary = path.utf8.index(path.utf8.startIndex, offsetBy: prefix.utf8.count)
        return path.utf8[boundary] == 0x2F
    }

    /// True when any single component of `path` is one of `names`, compared without
    /// ASCII case. Used for credential-store directory names, which must be excluded
    /// wherever they appear rather than only under one known parent.
    static func path(_ path: String, hasComponentNamed names: [String]) -> Bool {
        path.utf8.split(separator: 0x2F).contains { component in
            let name = String(decoding: component, as: UTF8.self)
            return names.contains { equalsIgnoringASCIICase(name, $0) }
        }
    }

    /// True when any single component of `path` ends with `suffix`, compared without
    /// ASCII case.
    static func path(_ path: String, hasComponentEndingWith suffix: String) -> Bool {
        path.utf8.split(separator: 0x2F).contains { component in
            let bytes = Array(component)
            guard bytes.count > suffix.utf8.count else { return false }
            let tail = String(decoding: bytes.suffix(suffix.utf8.count), as: UTF8.self)
            return equalsIgnoringASCIICase(tail, suffix)
        }
    }

    private static func foldASCIICase(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }
}
