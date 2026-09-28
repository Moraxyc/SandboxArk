import UIKit

/// Entry screen hosted by `SKUtilityWindow`: it identifies the host app, opens the
/// read-only browser and closes the window. Host files are only read after the user
/// opens the browser; presenting this screen alone scans nothing.
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

        let browse = UIButton(type: .system)
        browse.setTitle("Browse Sandbox", for: .normal)
        browse.addTarget(self, action: #selector(browseTapped), for: .touchUpInside)

        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, identity, browse, close])
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

    @objc private func browseTapped() {
        let home: SKAuthorizedRoot
        do {
            home = try SKAuthorizedRoot.openHome(NSHomeDirectory())
        } catch let error as SKError {
            presentFailure(error.code.rawValue)
            return
        } catch {
            presentFailure(SKErrorCode.filesystemUnreadable.rawValue)
            return
        }
        let browser = SKSandboxBrowserViewController(home: home) { home.close() }
        let navigation = UINavigationController(rootViewController: browser)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
        SKRuntimeDiagnostics.record("browse_opened")
    }

    private func presentFailure(_ code: String) {
        let alert = UIAlertController(title: "Browse unavailable",
                                      message: "This container could not be opened (\(code)).",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        SKRuntimeDiagnostics.record("browse_open_failed;code=\(code)")
    }

    @objc private func closeTapped() {
        onClose?()
    }
}
