import UIKit

/// Default entry gesture: a three-finger long press of 1.5 s with 12 pt movement tolerance
/// on the active scene's host window. It never cancels or delays host touches, and the user
/// can disable it if it conflicts with the host's own gestures.
@MainActor
final class SKTriggerCoordinator: NSObject, UIGestureRecognizerDelegate {
    static let minimumPressDuration: TimeInterval = 1.5
    static let numberOfTouchesRequired = 3
    static let allowableMovement: CGFloat = 12

    private let onTrigger: @MainActor () -> Void
    private var recognizer: UILongPressGestureRecognizer?

    init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
        super.init()
    }

    var isEnabled: Bool {
        get { recognizer?.isEnabled ?? false }
        set { recognizer?.isEnabled = newValue }
    }

    func install(on view: UIView) {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        recognizer.minimumPressDuration = Self.minimumPressDuration
        recognizer.numberOfTouchesRequired = Self.numberOfTouchesRequired
        recognizer.allowableMovement = Self.allowableMovement
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        view.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
    }

    func remove() {
        if let recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onTrigger()
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
