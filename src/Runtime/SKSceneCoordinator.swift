import UIKit

/// Per-scene runtime state: trigger registration, SandboxArk window presentation, and
/// teardown when a scene deactivates or disconnects.
///
/// State is keyed by scene; a single process-wide "current window" or "current trigger"
/// would break on iPad multiwindow, and nothing here replaces host delegates.
@MainActor
final class SKSceneCoordinator {
    static let shared = SKSceneCoordinator()

    private final class SceneState {
        weak var hostWindow: UIWindow?
        weak var hostView: UIView?
        var trigger: SKTriggerCoordinator?
        var utilityWindow: SKUtilityWindow?
        var isPresenting = false
    }

    private var started = false
    private var scenes: [ObjectIdentifier: SceneState] = [:]

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        SKRuntimeDiagnostics.record("runtime_started")

        let center = NotificationCenter.default
        for name in [
            UIApplication.didFinishLaunchingNotification,
            UIScene.willConnectNotification,
            UIScene.didActivateNotification,
            UIWindow.didBecomeKeyNotification,
        ] {
            center.addObserver(self, selector: #selector(refreshHosts), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
                           name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDidDisconnect(_:)),
                           name: UIScene.didDisconnectNotification, object: nil)
        refreshHosts()
    }

    @objc private func refreshHosts() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        where scene.activationState == .foregroundActive {
            adoptHost(in: scene)
        }
    }

    private func adoptHost(in scene: UIWindowScene) {
        let id = ObjectIdentifier(scene)
        let state = scenes[id] ?? SceneState()
        guard !state.isPresenting else { return }
        guard let host = hostWindow(in: scene),
              let hostView = host.rootViewController?.view else { return }

        if state.hostView === hostView, let trigger = state.trigger {
            trigger.isEnabled = true
            return
        }
        state.trigger?.remove()
        let trigger = SKTriggerCoordinator { [weak self, weak scene] in
            guard let scene else { return }
            self?.present(overlayFor: scene)
        }
        trigger.install(on: hostView)
        state.hostWindow = host
        state.hostView = hostView
        state.trigger = trigger
        scenes[id] = state
        SKRuntimeDiagnostics.record("trigger_registered")
    }

    private func hostWindow(in scene: UIWindowScene) -> UIWindow? {
        scene.windows.first { $0.isKeyWindow && isHostWindow($0) }
            ?? scene.windows.first { isHostWindow($0) }
    }

    private func isHostWindow(_ window: UIWindow) -> Bool {
        !window.isHidden && window.alpha > 0 && window.windowLevel == .normal
            && window.rootViewController != nil
    }

    private func present(overlayFor scene: UIWindowScene) {
        let id = ObjectIdentifier(scene)
        guard scene.activationState == .foregroundActive,
              let state = scenes[id],
              !state.isPresenting,
              let host = state.hostWindow,
              host.windowScene === scene else { return }

        let previousKeyWindow = scene.windows.first { $0.isKeyWindow && !$0.isHidden } ?? host
        let overlay = state.utilityWindow
            ?? SKUtilityWindow(scene: scene, rootViewController: makeRootViewController(for: scene))
        state.utilityWindow = overlay
        state.isPresenting = true
        state.trigger?.isEnabled = false
        overlay.present(returningFocusTo: previousKeyWindow)
        SKRuntimeDiagnostics.record("overlay_opened;overlay_key=\(overlay.isKeyWindow)")
    }

    private func makeRootViewController(for scene: UIWindowScene) -> SKRootViewController {
        let controller = SKRootViewController()
        controller.onClose = { [weak self, weak scene] in
            guard let scene else { return }
            self?.dismiss(overlayFor: scene, reason: "user")
        }
        return controller
    }

    private func dismiss(overlayFor scene: UIWindowScene, reason: String) {
        let id = ObjectIdentifier(scene)
        guard let state = scenes[id], state.isPresenting, let overlay = state.utilityWindow else { return }
        state.isPresenting = false
        let hostFocusRestored = overlay.dismiss()
        state.trigger?.isEnabled = scene.activationState == .foregroundActive
        SKRuntimeDiagnostics.record("overlay_closed_\(reason);host_key_restored=\(hostFocusRestored)")
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        SKRuntimeDiagnostics.record("scene_will_deactivate")
        dismiss(overlayFor: scene, reason: "scene_deactivated")
        scenes[ObjectIdentifier(scene)]?.trigger?.isEnabled = false
    }

    @objc private func sceneDidDisconnect(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        let id = ObjectIdentifier(scene)
        SKRuntimeDiagnostics.record("scene_did_disconnect")
        dismiss(overlayFor: scene, reason: "scene_disconnected")
        scenes[id]?.trigger?.remove()
        scenes.removeValue(forKey: id)
    }
}

/// Bounded, redacted lifecycle markers, never host content. The owned TestHost reads
/// the same defaults key for its report, so the key is shared across the two targets.
enum SKRuntimeDiagnostics {
    static let eventsKey = "com.moraxyc.SandboxArk.runtime.events"

    static func record(_ event: String) {
        let defaults = UserDefaults.standard
        var events = defaults.stringArray(forKey: eventsKey) ?? []
        events.append("\(ISO8601DateFormatter().string(from: Date())): \(event)")
        if events.count > 100 {
            events.removeFirst(events.count - 100)
        }
        defaults.set(events, forKey: eventsKey)
    }
}
