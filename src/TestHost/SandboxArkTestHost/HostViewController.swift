import UIKit

/// Root screen of the owned host. It exercises host interaction so that injection and
/// window-focus behavior can be observed on a real device.
final class HostViewController: UIViewController {
    private var tapCount = 0

    private let countLabel = UILabel()
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "SandboxArk TestHost"
        title.font = .preferredFont(forTextStyle: .title1)
        title.adjustsFontForContentSizeCategory = true

        countLabel.text = "TestHost taps: 0"
        countLabel.font = .preferredFont(forTextStyle: .body)

        let tapButton = UIButton(type: .system)
        tapButton.setTitle("Tap TestHost", for: .normal)
        tapButton.addTarget(self, action: #selector(tap), for: .touchUpInside)

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Copy Diagnostics", for: .normal)
        copyButton.addTarget(self, action: #selector(copyDiagnostics), for: .touchUpInside)

        statusLabel.text = "Then open SandboxArk with a three-finger long press."
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, countLabel, tapButton, copyButton, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func tap() {
        tapCount += 1
        countLabel.text = "TestHost taps: \(tapCount)"
        SKTestHostDiagnostics.record("host_tapped")
    }

    @objc private func copyDiagnostics() {
        UIPasteboard.general.string = SKTestHostDiagnostics.report(hostTapCount: tapCount)
        statusLabel.text = "Diagnostics copied. Paste them into the chat."
        SKTestHostDiagnostics.record("diagnostics_copied")
    }
}
