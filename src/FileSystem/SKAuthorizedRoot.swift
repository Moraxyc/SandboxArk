/// Capability handle for one authorized root: the current NSHomeDirectory() in 0.1.0,
/// and later a per-group opt-in App Group container.
///
/// The root's identity comes from its file descriptor, not from a path string; App
/// Group roots are only registered when the current entitlement contains that exact
/// identifier.
enum SKAuthorizedRoot {
}
