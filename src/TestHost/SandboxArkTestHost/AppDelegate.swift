import UIKit

/// Minimal owned host used to verify dylib injection. SandboxArk is injected into this
/// bundle by the sideload signer; the target never links the dylib directly.
///
/// The deterministic fixture generator and the quiescence adapter arrive with the
/// phases that need them; this host stays inert until then.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
