#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Component-wise no-follow path resolution under an authorized root and mapping to
/// archive-relative paths.
///
/// Path strings alone are not a security boundary; every component is opened relative
/// to a verified parent descriptor.
enum SKPathResolver {
    /// Directories are opened read-only with `O_NOFOLLOW`; the type check comes from
    /// `fstat` on the resulting descriptor rather than from `O_DIRECTORY` alone,
    /// because a replaced component must fail closed on identity, not on flags.
    static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    static let regularFileOpenFlags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC

    /// `realpath` needs a caller-owned buffer; the value covers both Darwin PATH_MAX
    /// and Linux PATH_MAX without depending on either macro.
    private static let canonicalPathBufferBytes = 4096

    /// Hard bounds applied to every path string this layer accepts.
    struct PathLimits: Sendable {
        var pathBytes = SKResourceLimits.maxScanPathBytes
        var componentBytes = SKResourceLimits.maxScanPathComponentBytes

        static let `default` = PathLimits()
    }

    // MARK: - Path strings

    /// Splits a home-relative path into components, rejecting anything that could name
    /// an object outside the root: empty names, `.`, `..`, NUL, and over-long input.
    static func components(ofPath path: String, limits: PathLimits = .default) throws -> [String] {
        guard !path.isEmpty else { throw invalidPathError("path is empty") }
        guard path.utf8.count <= limits.pathBytes else {
            throw invalidPathError("path exceeds \(limits.pathBytes) bytes")
        }
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            try validate(component: String(component), limits: limits)
            components.append(String(component))
        }
        return components
    }

    static func validate(component: String, limits: PathLimits = .default) throws {
        guard !component.isEmpty else { throw invalidPathError("path component is empty") }
        guard component != ".", component != ".." else {
            throw invalidPathError("path component is not addressable")
        }
        guard !component.utf8.contains(0) else { throw invalidPathError("path component contains NUL") }
        // A backslash is a legal iOS filename byte, so it stays addressable for browse
        // and preview; the archive writer rejects it separately as a member path.
        guard component.utf8.count <= limits.componentBytes else {
            throw invalidPathError("path component exceeds \(limits.componentBytes) bytes")
        }
    }

    // MARK: - Metadata

    static func identity(of descriptor: Int32) throws -> SKFileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw error(forErrno: errno, relativePath: nil)
        }
        return makeIdentity(status)
    }

    /// Classifies one child without following it and without opening it. Nothing here
    /// can block: a FIFO or device is reported as `special` and is never opened.
    static func classify(component: String, in parentDescriptor: Int32) throws -> SKFileIdentity {
        var status = stat()
        let result = component.withCString {
            fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else { throw error(forErrno: errno, relativePath: component) }
        return makeIdentity(status)
    }

    // MARK: - Descriptor-relative access

    static func openDirectory(component: String, in parentDescriptor: Int32) throws -> (descriptor: Int32, identity: SKFileIdentity) {
        try open(component: component, in: parentDescriptor, flags: directoryOpenFlags, expected: .directory)
    }

    static func openRegularFile(component: String, in parentDescriptor: Int32) throws -> (descriptor: Int32, identity: SKFileIdentity) {
        try open(component: component, in: parentDescriptor, flags: regularFileOpenFlags, expected: .regular)
    }

    /// Opens a directory below the root, one verified component at a time.
    static func openDirectory(atPath relativePath: String, under root: SKAuthorizedRoot, limits: PathLimits = .default) throws -> (descriptor: Int32, identity: SKFileIdentity) {
        try open(atPath: relativePath, under: root, limits: limits, as: .directory)
    }

    /// Opens a regular file below the root for reading. Reserved paths are refused here
    /// as well as by policy, so no reader can reach SandboxArk's own state.
    static func openRegularFile(atPath relativePath: String, under root: SKAuthorizedRoot, limits: PathLimits = .default) throws -> (descriptor: Int32, identity: SKFileIdentity) {
        try open(atPath: relativePath, under: root, limits: limits, as: .regular)
    }

    /// Lists one directory. `body` returns `false` to stop early, which is how the
    /// scanner stays responsive to cancellation inside a huge directory.
    static func enumerate(childrenOf directoryDescriptor: Int32,
                          _ body: (SKDirectoryEntry) -> Bool) throws {
        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0 else { throw error(forErrno: errno, relativePath: nil) }
        guard let stream = fdopendir(duplicate) else {
            let value = errno
            closeDescriptor(duplicate)
            throw error(forErrno: value, relativePath: nil)
        }
        defer { closedir(stream) }

        // `errno` is cleared before every `readdir`, not once before the loop: the
        // caller's body performs its own syscalls, and a failure there would otherwise
        // be misread as the end of the directory failing.
        while true {
            errno = 0
            guard let entry = readdir(stream) else { break }
            guard let name = name(of: entry) else {
                if !body(.unrepresentableName) { return }
                continue
            }
            if name == "." || name == ".." { continue }
            if !body(.child(name: name)) { return }
        }
        guard errno == 0 else { throw error(forErrno: errno, relativePath: nil) }
    }

    // MARK: - Additional canonical check

    /// Verifies that the object behind `identity` is still the object the canonical
    /// path names, and that the canonical path is inside the root. The walk itself
    /// cannot leave the root, so this only catches a component replaced between
    /// `openat` and the check. A platform that cannot resolve a canonical path reports
    /// success, because the descriptor identity remains the boundary.
    static func isWithinRoot(relativePath: String, identity: SKFileIdentity, canonicalRootPath: String?) -> Bool {
        guard let canonicalRootPath else { return true }
        guard let resolved = canonicalPath(ofAbsolutePath: canonicalRootPath + "/" + relativePath) else {
            return true
        }
        guard SKSecurityPolicy.path(resolved, matchesPrefix: canonicalRootPath) else { return false }
        var status = stat()
        guard resolved.withCString({ stat($0, &status) }) == 0 else { return true }
        return UInt64(status.st_dev) == identity.device && UInt64(status.st_ino) == identity.inode
    }

    static func canonicalPath(ofAbsolutePath path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: canonicalPathBufferBytes)
        let resolved = path.withCString { realpath($0, &buffer) }
        guard resolved != nil else { return nil }
        return String(validatingUTF8: buffer)
    }

    // MARK: - Errors and cleanup

    static func invalidPathError(_ reason: String) -> SKError {
        SKError(code: .filesystemUnreadable, stage: "pathValidation", reason: reason)
    }

    static func changedDuringReadError(_ relativePath: String) -> SKError {
        SKError(code: .filesystemChangedDuringRead, stage: "descriptorOpen", relativePath: relativePath)
    }

    static func reservedPathError(_ relativePath: String) -> SKError {
        SKError(code: .filesystemReservedPathConflict, stage: "pathValidation", relativePath: relativePath)
    }

    static func error(forErrno value: Int32, relativePath: String?) -> SKError {
        let code: SKErrorCode = value == ELOOP ? .filesystemSymlinkEscape : .filesystemUnreadable
        return SKError(code: code, stage: "descriptorAccess", relativePath: relativePath, underlyingCode: value)
    }

    static func closeDescriptor(_ descriptor: Int32) {
        #if canImport(Darwin)
        Darwin.close(descriptor)
        #else
        Glibc.close(descriptor)
        #endif
    }

    static func kind(ofMode mode: mode_t) -> SKFileKind {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): .regular
        case mode_t(S_IFDIR): .directory
        case mode_t(S_IFLNK): .symlink
        case mode_t(S_IFIFO), mode_t(S_IFCHR), mode_t(S_IFBLK), mode_t(S_IFSOCK): .special
        default: .unknown
        }
    }

    // MARK: - Internals

    private static func open(component: String, in parentDescriptor: Int32, flags: Int32, expected: SKFileKind) throws -> (descriptor: Int32, identity: SKFileIdentity) {
        let descriptor = component.withCString { openat(parentDescriptor, $0, flags) }
        guard descriptor >= 0 else {
            throw openFailure(errno, component: component, in: parentDescriptor)
        }
        do {
            let identity = try identity(of: descriptor)
            // A component swapped between classification and open lands here: the
            // descriptor is valid but no longer describes the object we listed.
            guard identity.kind == expected else { throw changedDuringReadError(component) }
            return (descriptor, identity)
        } catch {
            closeDescriptor(descriptor)
            throw error
        }
    }

    /// `O_NOFOLLOW` reports a refused symlink as `ELOOP` on Darwin but as `ENOTDIR`
    /// on Linux, where the flag combination is checked against the link itself. A
    /// failed open is therefore re-classified before it becomes a plain read error.
    private static func openFailure(_ value: Int32, component: String, in parentDescriptor: Int32) -> SKError {
        if value == ENOTDIR, (try? classify(component: component, in: parentDescriptor))?.kind == .symlink {
            return SKError(code: .filesystemSymlinkEscape, stage: "descriptorOpen",
                           relativePath: component, underlyingCode: value)
        }
        return error(forErrno: value, relativePath: component)
    }

    private static func open(atPath relativePath: String, under root: SKAuthorizedRoot, limits: PathLimits, as expected: SKFileKind) throws -> (descriptor: Int32, identity: SKFileIdentity) {
        let components = try components(ofPath: relativePath, limits: limits)
        guard !SKReservedPaths.isReserved(homeRelativePath: components.joined(separator: "/")) else {
            throw reservedPathError(components.joined(separator: "/"))
        }

        var descriptor = dup(root.descriptor)
        guard descriptor >= 0 else { throw error(forErrno: errno, relativePath: relativePath) }
        do {
            for component in components.dropLast() {
                let next = try openDirectory(component: component, in: descriptor)
                closeDescriptor(descriptor)
                descriptor = next.descriptor
            }
            let last = try open(component: components[components.count - 1], in: descriptor, flags: expected == .directory ? directoryOpenFlags : regularFileOpenFlags, expected: expected)
            closeDescriptor(descriptor)
            return last
        } catch {
            closeDescriptor(descriptor)
            throw error
        }
    }

    private static func makeIdentity(_ status: stat) -> SKFileIdentity {
        #if canImport(Darwin)
        let modified = status.st_mtimespec
        #else
        let modified = status.st_mtim
        #endif
        return SKFileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            kind: kind(ofMode: status.st_mode),
            size: Int64(status.st_size),
            permissions: UInt16(status.st_mode & mode_t(0o777)),
            modifiedSeconds: Int64(modified.tv_sec),
            modifiedNanoseconds: Int64(modified.tv_nsec)
        )
    }

    private static func name(of entry: UnsafeMutablePointer<dirent>) -> String? {
        withUnsafeBytes(of: entry.pointee.d_name) { raw in
            guard let base = raw.baseAddress else { return nil }
            return String(validatingUTF8: base.assumingMemoryBound(to: CChar.self))
        }
    }
}

/// Type of a directory entry, decided from `fstat`/`fstatat` mode bits rather than
/// from `d_type`, which is not authoritative on every filesystem.
enum SKFileKind: String, Sendable {
    case regular
    case directory
    case symlink
    case special
    case unknown
}

/// Wall-clock timestamp without a Foundation dependency, so the scan layer stays
/// usable from a plain POSIX build as well.
struct SKFileTimestamp: Equatable, Sendable, Comparable {
    let seconds: Int64
    let nanoseconds: Int64

    static func now() -> SKFileTimestamp {
        var value = timespec()
        clock_gettime(CLOCK_REALTIME, &value)
        return SKFileTimestamp(seconds: Int64(value.tv_sec), nanoseconds: Int64(value.tv_nsec))
    }

    static func monotonicNanoseconds() -> UInt64 {
        var value = timespec()
        clock_gettime(CLOCK_MONOTONIC, &value)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    static func < (lhs: SKFileTimestamp, rhs: SKFileTimestamp) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }
}

/// Object identity captured from a descriptor. Two identities describe the same
/// object only when device and inode both match; size and mtime are evidence about
/// content, not identity.
struct SKFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let kind: SKFileKind
    let size: Int64
    let permissions: UInt16
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    var modifiedAt: SKFileTimestamp {
        SKFileTimestamp(seconds: modifiedSeconds, nanoseconds: modifiedNanoseconds)
    }

    func isSameObject(as other: SKFileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

/// One raw directory entry. A name that is not valid UTF-8 cannot be addressed or
/// displayed, so it is reported separately instead of being rendered lossily.
enum SKDirectoryEntry: Equatable, Sendable {
    case child(name: String)
    case unrepresentableName
}
