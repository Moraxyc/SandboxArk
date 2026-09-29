import UIKit

/// Entry screen hosted by `SKUtilityWindow`: it identifies the host app, opens the read-only
/// browser or the backup flow, and closes the window. Host files are only read after the user
/// starts one of those; presenting this screen alone scans nothing.
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

        let backup = UIButton(type: .system)
        backup.setTitle("Create Backup", for: .normal)
        backup.addTarget(self, action: #selector(backupTapped), for: .touchUpInside)

        let browse = UIButton(type: .system)
        browse.setTitle("Browse Sandbox", for: .normal)
        browse.addTarget(self, action: #selector(browseTapped), for: .touchUpInside)

        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let notice = UILabel()
        notice.text = "SandboxArk may access all files that this app itself can access. "
            + "Backups can contain private app data and are exported only when you ask."
        notice.font = .preferredFont(forTextStyle: .footnote)
        notice.adjustsFontForContentSizeCategory = true
        notice.textColor = .secondaryLabel
        notice.textAlignment = .center
        notice.numberOfLines = 0
        notice.preferredMaxLayoutWidth = 320

        let stack = UIStackView(arrangedSubviews: [title, identity, backup, browse, close, notice])
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
        guard let home = openHome(for: "Browse") else { return }
        let browser = SKSandboxBrowserViewController(home: home) { home.close() }
        let navigation = UINavigationController(rootViewController: browser)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
        SKRuntimeDiagnostics.record("browse_opened")
    }

    @objc private func backupTapped() {
        guard let home = openHome(for: "Backup") else { return }
        let flow = SKBackupFlowViewController(home: home) { home.close() }
        let navigation = UINavigationController(rootViewController: flow)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    /// Opens the container the flow or the browser will read, or reports why it cannot.
    private func openHome(for action: String) -> SKAuthorizedRoot? {
        do {
            return try SKAuthorizedRoot.openHome(NSHomeDirectory())
        } catch let error as SKError {
            presentFailure(error.code.rawValue, for: action)
        } catch {
            presentFailure(SKErrorCode.filesystemUnreadable.rawValue, for: action)
        }
        return nil
    }

    private func presentFailure(_ code: String, for action: String) {
        let alert = UIAlertController(title: "\(action) unavailable",
                                      message: "This container could not be opened (\(code)).",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        SKRuntimeDiagnostics.record("\(action.lowercased())_open_failed;code=\(code)")
    }

    @objc private func closeTapped() {
        onClose?()
    }
}
