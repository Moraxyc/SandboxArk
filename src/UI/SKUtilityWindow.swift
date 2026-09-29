import UIKit

/// Scene-bound SandboxArk window. It becomes key only inside the scene that launched
/// it, and restores the host window's key state on close only while that window is
/// still visible and in the same scene.
final class SKUtilityWindow: UIWindow {
    private weak var returningKeyWindow: UIWindow?
    private var privacyScreen: UIView?

    init(scene: UIWindowScene, rootViewController: UIViewController) {
        super.init(windowScene: scene)
        self.rootViewController = rootViewController
    }

    required init?(coder: NSCoder) {
        fatalError("SKUtilityWindow is created in code only")
    }

    func present(returningFocusTo keyWindow: UIWindow?) {
        returningKeyWindow = keyWindow
        makeKeyAndVisible()
    }

    func setPrivacyScreenVisible(_ visible: Bool) {
        if visible {
            guard !isHidden, privacyScreen == nil else { return }
            let cover = UIView(frame: bounds)
            cover.backgroundColor = .systemBackground
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.accessibilityViewIsModal = true
            addSubview(cover)
            privacyScreen = cover
            if let returning = returningKeyWindow,
               returning.windowScene === windowScene, !returning.isHidden {
                returning.makeKey()
            }
        } else {
            guard privacyScreen != nil else { return }
            privacyScreen?.removeFromSuperview()
            privacyScreen = nil
            if !isHidden { makeKeyAndVisible() }
        }
    }

    @discardableResult
    func dismiss() -> Bool {
        isHidden = true
        defer { returningKeyWindow = nil }
        guard let returning = returningKeyWindow,
              returning.windowScene === windowScene,
              !returning.isHidden else { return false }
        returning.makeKey()
        return returning.isKeyWindow
    }
}
