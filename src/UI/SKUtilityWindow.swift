import UIKit

/// Scene-bound SandboxArk window. It becomes key only inside the scene that launched
/// it, and restores the host window's key state on close only while that window is
/// still visible and in the same scene.
final class SKUtilityWindow: UIWindow {
}
