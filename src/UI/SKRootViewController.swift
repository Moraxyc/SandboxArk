import UIKit

/// Entry screen hosted by `SKUtilityWindow`: it identifies the host app and closes the
/// window. Browsing, backup and history entries arrive with the phases that implement
/// them; presenting this screen never scans or reads host files.
final class SKRootViewController: UIViewController {
    var onClose: (@MainActor () -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "SandboxArk"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.adjustsFontForContentSizeCategory = true

        let identity = UILabel()
        identity.text = hostIdentity
        identity.font = .preferredFont(forTextStyle: .subheadline)
        identity.textColor = .secondaryLabel
        identity.textAlignment = .center
        identity.numberOfLines = 0

        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, identity, close])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private var hostIdentity: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleName"] as? String ?? "Unknown App"
        let identifier = Bundle.main.bundleIdentifier ?? "unknown"
        return "\(name)\n\(identifier)"
    }

    @objc private func closeTapped() {
        onClose?()
    }
}
