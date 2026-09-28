/// Per-scene runtime state: trigger registration, SandboxArk window presentation, and
/// teardown when a scene deactivates or disconnects.
///
/// State is keyed by scene; a single process-wide "current window" or "current trigger"
/// would break on iPad multiwindow, and nothing here replaces host delegates.
enum SKSceneCoordinator {
}
