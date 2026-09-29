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
        title.numberOfLines = 0
        title.accessibilityTraits.insert(.header)

        countLabel.text = "TestHost taps: 0"
        countLabel.font = .preferredFont(forTextStyle: .body)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.numberOfLines = 0

        let tapButton = UIButton(type: .system)
        tapButton.setTitle("Tap TestHost", for: .normal)
        tapButton.addTarget(self, action: #selector(tap), for: .touchUpInside)

        let fixtureButton = UIButton(type: .system)
        fixtureButton.setTitle("Create Test Fixture", for: .normal)
        fixtureButton.addTarget(self, action: #selector(createFixture), for: .touchUpInside)

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Copy Diagnostics", for: .normal)
        copyButton.addTarget(self, action: #selector(copyDiagnostics), for: .touchUpInside)

        for button in [tapButton, fixtureButton, copyButton] {
            var configuration = UIButton.Configuration.bordered()
            configuration.title = button.title(for: .normal)
            configuration.buttonSize = .large
            configuration.titleLineBreakMode = .byWordWrapping
            button.configuration = configuration
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

        statusLabel.text = "Then open SandboxArk with a three-finger long press."
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, countLabel, tapButton, fixtureButton, copyButton, statusLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 20
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
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            scrollView.contentLayoutGuide.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: scrollView.contentLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(equalTo: view.readableContentGuide.widthAnchor),
        ])
    }

    @objc private func tap() {
        tapCount += 1
        countLabel.text = "TestHost taps: \(tapCount)"
        SKTestHostDiagnostics.record("host_tapped")
    }

    @objc private func createFixture() {
        let report = SKTestHostBrowseFixture.create(in: URL(fileURLWithPath: NSHomeDirectory()))
        SKTestHostDiagnostics.record(report.summary)
        statusLabel.text = report.failures.isEmpty
            ? "Fixture created: \(report.directories) folders, \(report.files) files, \(report.links) links."
            : "Fixture created with \(report.failures.count) failures."
    }

    @objc private func copyDiagnostics() {
        UIPasteboard.general.string = SKTestHostDiagnostics.report(hostTapCount: tapCount)
        statusLabel.text = "Diagnostics copied. Paste them into the chat."
        SKTestHostDiagnostics.record("diagnostics_copied")
    }
}
