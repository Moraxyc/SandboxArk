#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Capability handle for one authorized root: NSHomeDirectory() in 0.1.0, later a per-group
/// opt-in App Group container. The descriptor is the capability and the access boundary;
/// copying the value never duplicates it, and the owner closes it once every reader is done.
struct SKAuthorizedRoot: Sendable {
    /// Manifest vocabulary for `contents.roots[].scopeType`.
    static let homeScopeType = "home"

    let scopeType: String
    /// Opened with `O_DIRECTORY | O_NOFOLLOW`.
    let descriptor: Int32
    let identity: SKFileIdentity
    /// Canonical absolute path of the descriptor, or nil when the platform could not resolve one.
    let canonicalPath: String?

    /// Opens the current process container. `path` is NSHomeDirectory() of the host app;
    /// nothing else is a root in 0.1.0.
    static func openHome(_ path: String) throws -> SKAuthorizedRoot {
        let descriptor = path.withCString {
            openat(AT_FDCWD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw SKPathResolver.error(forErrno: errno, relativePath: nil)
        }
        do {
            let identity = try SKPathResolver.identity(of: descriptor)
            guard identity.kind == .directory else {
                throw SKPathResolver.invalidPathError("home is not a directory")
            }
            return SKAuthorizedRoot(
                scopeType: homeScopeType,
                descriptor: descriptor,
                identity: identity,
                canonicalPath: SKPathResolver.canonicalPath(ofAbsolutePath: path)
            )
        } catch {
            SKPathResolver.closeDescriptor(descriptor)
            throw error
        }
    }

    func close() {
        SKPathResolver.closeDescriptor(descriptor)
    }
}
