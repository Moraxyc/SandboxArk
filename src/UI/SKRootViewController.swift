import UIKit

/// Entry screen hosted by `SKUtilityWindow`: it identifies the host app, opens the read-only
/// browser or the backup flow, and closes the window. Host files are only read after the user
/// starts one of those; presenting this screen alone scans nothing.
final class SKRootViewController: UIViewController {
    var onClose: (@MainActor () -> Void)?

    private weak var exportLogsButton: UIButton?

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
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close,
                                                            target: self, action: #selector(closeTapped))

        let title = UILabel()
        title.text = "SandboxArk"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.textAlignment = .center
        title.accessibilityTraits.insert(.header)

        let identity = UILabel()
        identity.text = hostIdentity
        identity.font = .preferredFont(forTextStyle: .subheadline)
        identity.adjustsFontForContentSizeCategory = true
        identity.textColor = .secondaryLabel
        identity.textAlignment = .center
        identity.numberOfLines = 0

        let backup = UIButton(type: .system)
        backup.setTitle(String(localized: "Create Backup", bundle: .sandboxark), for: .normal)
        backup.addTarget(self, action: #selector(backupTapped), for: .touchUpInside)

        let browse = UIButton(type: .system)
        browse.setTitle(String(localized: "Browse Sandbox", bundle: .sandboxark), for: .normal)
        browse.addTarget(self, action: #selector(browseTapped), for: .touchUpInside)

        let exportLogs = UIButton(type: .system)
        exportLogs.setTitle(String(localized: "Export Diagnostic Logs", bundle: .sandboxark), for: .normal)
        exportLogs.addTarget(self, action: #selector(exportLogsTapped), for: .touchUpInside)
        self.exportLogsButton = exportLogs

        for button in [backup, browse, exportLogs] {
            var configuration: UIButton.Configuration = button === backup ? .filled() : .plain()
            configuration.title = button.title(for: .normal)
            configuration.buttonSize = .large
            configuration.titleLineBreakMode = .byWordWrapping
            button.configuration = configuration
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

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

        let stack = UIStackView(arrangedSubviews: [title, identity, backup, browse, exportLogs, notice])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: scrollView.contentLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(equalTo: view.readableContentGuide.widthAnchor),
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

    @objc private func exportLogsTapped() {
        let metadata = SKLocalLogger.exportMetadata()
        guard metadata.hasLogs else {
            let alert = UIAlertController(
                title: String(localized: "No Diagnostic Logs", bundle: .sandboxark),
                message: String(localized: "There are no local diagnostic logs recorded yet.", bundle: .sandboxark),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "OK", bundle: .sandboxark), style: .default))
            present(alert, animated: true)
            SKRuntimeDiagnostics.record("diagnostics_export_empty")
            return
        }

        let confirmationTitle = String(localized: "Export Diagnostic Logs", bundle: .sandboxark)
        let coverage = String(localized: "Diagnostic logs cover \(metadata.dateRangeDescription) (\(metadata.formattedSize)).",
                              bundle: .sandboxark)
        let privacyNotice = String(localized: "All paths and sensitive data are redacted. Destination providers may sync diagnostics remotely.",
                                   bundle: .sandboxark)
        let confirmationMessage = "\(coverage)\n\n\(privacyNotice)"

        let alert = UIAlertController(title: confirmationTitle,
                                      message: confirmationMessage,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel", bundle: .sandboxark),
                                      style: .cancel) { _ in
            SKRuntimeDiagnostics.record("diagnostics_export_cancelled")
        })
        alert.addAction(UIAlertAction(title: String(localized: "Export", bundle: .sandboxark),
                                      style: .default) { [weak self] _ in
            self?.performExportLogs()
        })
        present(alert, animated: true)
        SKRuntimeDiagnostics.record("diagnostics_confirm_presented")
    }

    private func performExportLogs() {
        do {
            let package = try SKLocalLogger.prepareExportPackage()
            let sheet = UIActivityViewController(activityItems: [package.url], applicationActivities: nil)
            if let exportLogsButton {
                sheet.popoverPresentationController?.sourceView = exportLogsButton
                sheet.popoverPresentationController?.sourceRect = exportLogsButton.bounds
            } else {
                sheet.popoverPresentationController?.sourceView = view
                sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            }
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                SKLocalLogger.cleanupExportPackage(at: package.url)
                Task { @MainActor in
                    SKRuntimeDiagnostics.record("diagnostics_export_finished;completed=\(completed)")
                }
            }
            present(sheet, animated: true)
            SKRuntimeDiagnostics.record("diagnostics_export_presented")
        } catch {
            let alert = UIAlertController(
                title: String(localized: "Cannot Export Diagnostics", bundle: .sandboxark),
                message: String(localized: "SandboxArk could not prepare the diagnostic package.", bundle: .sandboxark),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "OK", bundle: .sandboxark), style: .default))
            present(alert, animated: true)
            SKRuntimeDiagnostics.record("diagnostics_export_failed")
        }
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
