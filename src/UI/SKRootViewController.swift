import UIKit

/// Entry screen hosted by `SKUtilityWindow`: it identifies the host app, opens the read-only
/// browser or the backup flow, and closes the window. Host files are only read after the user
/// starts one of those; presenting this screen alone scans nothing.
final class SKRootViewController: UIViewController {
    var onClose: (@MainActor () -> Void)?

    /// Keeps the identifier a diagnostics report records separate from the text the user reads,
    /// so translating this screen never renames an event.
    private enum Action {
        case browse
        case backup

        var diagnosticID: String {
            switch self {
            case .browse: "browse"
            case .backup: "backup"
            }
        }

        /// The alert title names the action the user picked, because "unavailable" alone does
        /// not say which of the two was refused.
        var failureTitle: String {
            switch self {
            case .browse: String(localized: "Cannot Browse This Sandbox", bundle: .sandboxark)
            case .backup: String(localized: "Cannot Back Up This Sandbox", bundle: .sandboxark)
            }
        }

        var failureMessage: String {
            switch self {
            case .browse:
                String(localized: """
                SandboxArk could not open this app's home directory, so nothing was read.
                """, bundle: .sandboxark)
            case .backup:
                String(localized: """
                SandboxArk could not open this app's home directory, so no archive was created.
                """, bundle: .sandboxark)
            }
        }
    }

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
        backup.setTitle(String(localized: "Create Backup", bundle: .sandboxark), for: .normal)
        backup.addTarget(self, action: #selector(backupTapped), for: .touchUpInside)

        let browse = UIButton(type: .system)
        browse.setTitle(String(localized: "Browse Sandbox", bundle: .sandboxark), for: .normal)
        browse.addTarget(self, action: #selector(browseTapped), for: .touchUpInside)

        let close = UIButton(type: .system)
        close.setTitle(String(localized: "Close", bundle: .sandboxark), for: .normal)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let notice = UILabel()
        notice.text = String(localized: """
        SandboxArk may access all files that this app itself can access. Backups can contain \
        private app data and are exported only when you ask.
        """, bundle: .sandboxark)
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
        let name = info["CFBundleName"] as? String ?? String(localized: "Unknown App", bundle: .sandboxark)
        let identifier = Bundle.main.bundleIdentifier ?? "unknown"
        return "\(name)\n\(identifier)"
    }

    @objc private func browseTapped() {
        guard let home = openHome(for: .browse) else { return }
        let browser = SKSandboxBrowserViewController(home: home) { home.close() }
        let navigation = UINavigationController(rootViewController: browser)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
        SKRuntimeDiagnostics.record("browse_opened")
    }

    @objc private func backupTapped() {
        guard let home = openHome(for: .backup) else { return }
        let flow = SKBackupFlowViewController(home: home) { home.close() }
        let navigation = UINavigationController(rootViewController: flow)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    /// Opens the container the flow or the browser will read, or reports why it cannot.
    private func openHome(for action: Action) -> SKAuthorizedRoot? {
        do {
            return try SKAuthorizedRoot.openHome(NSHomeDirectory())
        } catch let error as SKError {
            presentFailure(error.code.rawValue, for: action)
        } catch {
            presentFailure(SKErrorCode.filesystemUnreadable.rawValue, for: action)
        }
        return nil
    }

    private func presentFailure(_ code: String, for action: Action) {
        let alert = UIAlertController(title: action.failureTitle,
                                      message: action.failureMessage,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK", bundle: .sandboxark), style: .default))
        present(alert, animated: true)
        SKRuntimeDiagnostics.record("\(action.diagnosticID)_open_failed;code=\(code)")
    }

    @objc private func closeTapped() {
        onClose?()
    }
}
