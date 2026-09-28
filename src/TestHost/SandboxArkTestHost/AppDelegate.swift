import UIKit

/// Minimal owned host used to verify dylib injection: SandboxArk is injected into this
/// bundle by the sideload signer, and the target never links the dylib directly. The
/// fixture generator and quiescence adapter arrive with the phases that need them.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
