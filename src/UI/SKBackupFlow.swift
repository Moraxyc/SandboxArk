import Darwin
import UIKit

/// Backup confirmation, progress, cancellation and export handoff. The engine runs off the
/// main thread and reports through its request, so every report reaches this screen on the
/// main actor, and the screen owns the root descriptor until the worker has stopped.
final class SKBackupFlowViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    /// The scope notice, the measured preflight and the running transaction are separate
    /// steps, so the user never confirms an estimate SandboxArk has not measured.
    private enum Phase {
        case scope
        case scanning
        case preflight(Preflight)
        case running
        case verified(SKBackupCoordinator.Outcome)
        case failed(SKError)
    }

    /// Worst-case estimate plus the verdict that decides whether the start action is live.
    private struct Preflight {
        var report: SKScanReport
        var estimate: SKBackupPreflight.Estimate
        var availableBytes: Int64
        var blocked: SKError?
    }

    private let home: SKAuthorizedRoot
    /// Only this screen owns the descriptor, and only this screen closes it.
    private let onClose: (@MainActor () -> Void)?
    private let cancellation = SKScanCancellation()
    private var request: SKBackupCoordinator.Request?

    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let messageLabel = UILabel()
    private let summaryStack = UIStackView()
    private let detailsButton = UIButton(type: .system)
    private let detailsLabel = UILabel()
    private var showingDetails = false
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let primaryButton = UIButton(type: .system)
    private lazy var cancelItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                  target: self, action: #selector(closeTapped))
    private lazy var closeItem = UIBarButtonItem(barButtonSystemItem: .close,
                                                 target: self, action: #selector(closeTapped))

    private var phase: Phase = .scope
    private var runningState: SKBackupCoordinator.State?
    private var runningCounters: SKBackupCoordinator.Progress?
    private var announcedState: SKBackupCoordinator.State?
    private var isWorking = false
    private var isDismissed = false
    private var hasReleasedHome = false

    init(home: SKAuthorizedRoot, onClose: (@MainActor () -> Void)? = nil) {
        self.home = home
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SKBackupFlowViewController is created in code only")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Create Backup", bundle: .sandboxark)
        view.backgroundColor = .systemBackground
        configureLayout()
        request = makeRequest()
        if request == nil {
            phase = .failed(SKError(code: .integrityManifestInvalid,
                                    stage: "backupRequest",
                                    reason: "the system clock is outside the archive's timestamp range"))
        }
        render()
        SKRuntimeDiagnostics.record("backup_opened")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory,
           case .preflight = phase {
            render()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        isDismissed = true
        cancellation.cancel()
        if !isWorking { releaseHome() }
    }

    // MARK: - Layout

    private func configureLayout() {
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityTraits.insert(.header)

        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .label
        detailLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0

        progressView.progress = 0
        progressView.accessibilityLabel = String(localized: "Create Backup", bundle: .sandboxark)
        spinner.isAccessibilityElement = false

        var configuration = UIButton.Configuration.filled()
        configuration.buttonSize = .large
        configuration.titleLineBreakMode = .byWordWrapping
        primaryButton.configuration = configuration
        primaryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        let minimumHeight = primaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        minimumHeight.priority = .defaultHigh
        minimumHeight.isActive = true

        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)

        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center

        detailsLabel.font = .preferredFont(forTextStyle: .footnote)
        detailsLabel.adjustsFontForContentSizeCategory = true
        detailsLabel.textColor = .secondaryLabel
        detailsLabel.numberOfLines = 0

        summaryStack.axis = .vertical
        summaryStack.backgroundColor = .secondarySystemGroupedBackground
        summaryStack.layer.cornerRadius = 12
        summaryStack.layer.cornerCurve = .continuous
        summaryStack.clipsToBounds = true

        var detailsConfiguration = UIButton.Configuration.plain()
        detailsConfiguration.title = String(localized: "Show Details", bundle: .sandboxark)
        detailsConfiguration.buttonSize = .large
        detailsConfiguration.titleLineBreakMode = .byWordWrapping
        detailsButton.configuration = detailsConfiguration
        detailsButton.titleLabel?.adjustsFontForContentSizeCategory = true
        let detailsMinimumHeight = detailsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        detailsMinimumHeight.priority = .defaultHigh
        detailsMinimumHeight.isActive = true
        detailsButton.addTarget(self, action: #selector(detailsTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusRow, progressView, summaryStack, detailLabel,
                                                  messageLabel, primaryButton, detailsButton, detailsLabel])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
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

    /// One place decides which actions a phase offers, so a button can never stay live for a
    /// step that has already finished.
    private func setPrimaryButton(_ title: String?) {
        primaryButton.configuration?.title = title
        primaryButton.isHidden = title == nil
    }

    // MARK: - Rendering

    private func render() {
        summaryStack.isHidden = true
        detailLabel.isHidden = false
        detailsButton.isHidden = true
        detailsLabel.isHidden = true
        view.backgroundColor = .systemBackground
        switch phase {
        case .scope, .scanning, .preflight, .running:
            navigationItem.leftBarButtonItem = cancelItem
            navigationItem.rightBarButtonItem = nil
        case .verified, .failed:
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItem = closeItem
        }
        cancelItem.isEnabled = !(isWorking && cancellation.isCancelled)
        switch phase {
        case .scope: renderScope()
        case .scanning: renderScanning()
        case .preflight(let preflight): renderPreflight(preflight)
        case .running: renderRunning()
        case .verified(let outcome): renderVerified(outcome)
        case .failed(let error): renderFailure(error)
        }
        if isWorking && cancellation.isCancelled {
            statusLabel.text = String(localized: "Cancelling…", bundle: .sandboxark)
            progressView.isHidden = true
            spinner.startAnimating()
        }
    }

    private func renderScope() {
        statusLabel.text = String(localized: "Create Backup", bundle: .sandboxark)
        detailLabel.text = String(
            localized: "Included folders: \(SKScanner.standardRootPaths.joined(separator: ", ")).",
            bundle: .sandboxark)
        messageLabel.text = String(localized: """
        SandboxArk can read every file this app can access, so a backup can contain private \
        app data. The archive is built and kept in this app's temporary storage until you \
        export it, and SandboxArk never uploads anything.
        """, bundle: .sandboxark)
        spinner.stopAnimating()
        progressView.isHidden = true
        setPrimaryButton(String(localized: "Scan Sandbox", bundle: .sandboxark))
    }

    private func renderScanning() {
        statusLabel.text = SKBackupFlowViewController.status(for: .scanning)
        detailLabel.text = String(
            localized: "Counting the files to back up. Nothing is copied yet.",
            bundle: .sandboxark)
        messageLabel.text = String(
            localized: "The scan only reads; stopping it leaves the sandbox unchanged.",
            bundle: .sandboxark)
        spinner.startAnimating()
        progressView.isHidden = true
        setPrimaryButton(nil)
    }

    private func renderPreflight(_ preflight: Preflight) {
        let estimate = preflight.estimate
        statusLabel.text = preflight.blocked != nil
            ? String(localized: "Not Enough Space", bundle: .sandboxark)
            : String(localized: "Ready to back up", bundle: .sandboxark)
        view.backgroundColor = .systemGroupedBackground
        summaryStack.isHidden = false
        detailLabel.isHidden = true
        for row in summaryStack.arrangedSubviews {
            summaryStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        addSummaryRow(String(localized: "Files", bundle: .sandboxark), estimate.includedFiles.formatted())
        if estimate.directoryMembers > 0 {
            addSummaryRow(String(localized: "Folders", bundle: .sandboxark), estimate.directoryMembers.formatted())
        }
        addSummaryRow(String(localized: "Source Data", bundle: .sandboxark), Self.format(estimate.sourceBytes))
        addSummaryRow(String(localized: "Space Needed", bundle: .sandboxark), Self.format(estimate.requiredBytes))
        addSummaryRow(String(localized: "Space Available", bundle: .sandboxark), Self.format(preflight.availableBytes))
        detailsLabel.text = String(localized: """
        Space needed: \(Self.format(estimate.requiredBytes)), \
        including a \(Self.format(estimate.reserveBytes)) reserve
        """, bundle: .sandboxark) + "\n\n" + String(localized: """
        These numbers assume the worst case, including one uncompressed copy of the \
        files while the archive is built. Every file is checked again as it is copied.
        """, bundle: .sandboxark)
        detailsButton.isHidden = false
        detailsLabel.isHidden = !showingDetails
        detailsButton.configuration?.title = String(localized: showingDetails ? "Hide Details" : "Show Details",
                                                    bundle: .sandboxark)

        if preflight.blocked != nil {
            messageLabel.text = String(localized: """
            This backup cannot start, because this device does not have room for the archive. \
            Free up space, then scan again.
            """, bundle: .sandboxark)
        } else if preflight.report.isComplete {
            messageLabel.text = String(localized: "The scan is complete. You can start the backup.",
                                       bundle: .sandboxark)
        } else {
            messageLabel.text = incompleteReason(preflight.report)
                + " " + String(localized: """
                The archive will be marked partial, and every folder that could not be read \
                completely is listed inside it.
                """, bundle: .sandboxark)
        }
        spinner.stopAnimating()
        progressView.isHidden = true
        let partial = !preflight.report.isComplete
        if preflight.blocked != nil {
            setPrimaryButton(String(localized: "Scan Again", bundle: .sandboxark))
        } else {
            setPrimaryButton(String(localized: partial ? "Create Partial Backup" : "Start Backup",
                                    bundle: .sandboxark))
        }
    }

    private func addSummaryRow(_ title: String, _ value: String) {
        var configuration: UIListContentConfiguration = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            ? .subtitleCell() : .valueCell()
        configuration.text = title
        configuration.secondaryText = value
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.numberOfLines = 0
        summaryStack.addArrangedSubview(UIListContentView(configuration: configuration))
    }

    @objc private func detailsTapped() {
        showingDetails.toggle()
        detailsLabel.isHidden = !showingDetails
        detailsButton.configuration?.title = String(localized: showingDetails ? "Hide Details" : "Show Details",
                                                    bundle: .sandboxark)
        UIAccessibility.post(notification: .layoutChanged, argument: detailsButton)
    }

    private func renderRunning() {
        let state = runningState ?? runningCounters?.state ?? .prepared
        statusLabel.text = SKBackupFlowViewController.status(for: state)
        progressView.accessibilityLabel = statusLabel.text
        if state != .verifying, let counters = runningCounters,
           counters.state == state, counters.totalBytes > 0 || counters.totalItems > 0 {
            let fraction = counters.totalBytes > 0
                ? Double(counters.completedBytes) / Double(counters.totalBytes)
                : Double(counters.completedItems) / Double(counters.totalItems)
            progressView.progress = Float(min(1, max(0, fraction)))
            progressView.isHidden = false
            spinner.stopAnimating()
            detailLabel.text = SKBackupFlowViewController.counters(counters)
        } else {
            progressView.isHidden = true
            spinner.startAnimating()
            detailLabel.text = state == .verifying
                ? String(localized: "Reading the archive back and checking every file against its checksum.",
                         bundle: .sandboxark)
                : SKBackupFlowViewController.status(for: state)
        }
        messageLabel.text = String(localized: """
        Cancel stops the backup and removes this transaction's temporary files. Only a fully \
        verified archive can be exported.
        """, bundle: .sandboxark)
        setPrimaryButton(nil)
        if !cancellation.isCancelled { announce(state) }
    }

    private func renderVerified(_ outcome: SKBackupCoordinator.Outcome) {
        let manifest = outcome.manifest
        statusLabel.text = manifest.backup.completeness == .complete
            ? String(localized: "Backup Verified", bundle: .sandboxark)
            : String(localized: "Partial Backup Verified", bundle: .sandboxark)
        var lines = [
            String(localized: """
            Files: \(manifest.backup.totalFiles.formatted()) · \
            \(SKBackupFlowViewController.format(manifest.backup.totalBytes))
            """, bundle: .sandboxark),
        ]
        let incomplete = manifest.roots.filter { !$0.complete }
        if !incomplete.isEmpty {
            let described = incomplete.map {
                String(localized: "\($0.relativeRoot) (\($0.unreadableCount.formatted()) unreadable)",
                       bundle: .sandboxark)
            }
            lines.append(String(localized: "Incomplete Folders: \(described.joined(separator: ", "))",
                                bundle: .sandboxark))
        }
        detailLabel.text = lines.joined(separator: "\n")

        messageLabel.text = String(localized: """
        Export and keep a copy of your backup. The copy in this app is temporary: the system \
        may remove it, and your next backup replaces it.
        """, bundle: .sandboxark)
        spinner.stopAnimating()
        progressView.isHidden = true
        setPrimaryButton(String(localized: "Export…", bundle: .sandboxark))
    }

    private func renderFailure(_ error: SKError) {
        let cancelled = error.code == .cancelled
        statusLabel.text = cancelled
            ? String(localized: "Backup Cancelled", bundle: .sandboxark)
            : String(localized: "Backup Failed", bundle: .sandboxark)
        detailLabel.text = SKBackupFlowViewController.failureExplanation(for: error)
        messageLabel.text = stagingState(for: error)
        spinner.stopAnimating()
        progressView.isHidden = true
        setPrimaryButton(cancelled ? nil : String(localized: "Try Again", bundle: .sandboxark))
    }

    /// One sentence the user can act on. The code, stage and reason stay in the diagnostics
    /// record, so a report can still be traced without reading as technical text on screen.
    private static func failureExplanation(for error: SKError) -> String {
        switch error.code {
        case .cancelled:
            String(localized: "The backup was cancelled before it finished.", bundle: .sandboxark)
        case .storageInsufficientSpace:
            String(localized: "This device ran out of room for the archive, so the backup stopped.",
                   bundle: .sandboxark)
        case .storageDurabilityFailure:
            String(localized: "SandboxArk could not save the archive to this device's storage.",
                   bundle: .sandboxark)
        case .filesystemUnreadable, .filesystemChangedDuringRead,
             .filesystemSymlinkEscape, .filesystemReservedPathConflict:
            String(localized: "SandboxArk could not read part of the sandbox, so the backup stopped.",
                   bundle: .sandboxark)
        case .permissionScopeExpired, .permissionEntitlementMismatch:
            String(localized: "SandboxArk's access to the sandbox ended, so the backup stopped.",
                   bundle: .sandboxark)
        case .archiveCorrupt, .archivePathTraversal, .archiveLimitExceeded:
            String(localized: "The archive could not be written, so the backup stopped.",
                   bundle: .sandboxark)
        case .integrityHashMismatch, .integrityManifestInvalid:
            String(localized: "The archive did not match its checksums, so it was not kept.",
                   bundle: .sandboxark)
        case .sqliteOpenFailed, .sqliteBusy, .sqliteIntegrityCheckFailed, .sqliteVerificationTimedOut:
            String(localized: "A database inside the sandbox could not be checked.",
                   bundle: .sandboxark)
        case .manifestUnsupportedVersion, .manifestMigrationFailed:
            String(localized: "The archive's index could not be read back.", bundle: .sandboxark)
        case .compatibilityBundleIdentifierMismatch, .compatibilityVersionRisk:
            String(localized: "The archive was not made for this app.", bundle: .sandboxark)
        case .restoreQuiescenceUnavailable, .restoreSnapshotFailed, .restorePlanStale,
             .restoreConflict, .restoreRollbackRequired, .restoreJournalCorrupt:
            String(localized: "The archive could not be prepared for restoring.", bundle: .sandboxark)
        }
    }

    /// VoiceOver hears each stage once; the counters would otherwise repeat on every chunk.
    private func announce(_ state: SKBackupCoordinator.State) {
        guard announcedState != state else { return }
        announcedState = state
        UIAccessibility.post(notification: .announcement,
                             argument: SKBackupFlowViewController.status(for: state))
    }

    // MARK: - Steps

    private func startScan() {
        guard let request, !isWorking else { return }
        showingDetails = false
        phase = .scanning
        runningState = nil
        runningCounters = nil
        render()
        let home = self.home
        runOffMain({ try SKBackupCoordinator.scan(home: home, request: request) }) { result in
            if self.cancellation.isCancelled {
                self.fail(SKError(code: .cancelled))
                return
            }
            switch result {
            case .success(let report): self.showPreflight(for: report)
            case .failure(let error): self.fail(error)
            }
        }
    }

    /// Keep the measured estimate visible when space is insufficient so the user can free space and rescan.
    private func showPreflight(for report: SKScanReport) {
        let estimate = SKBackupPreflight.estimate(report: report)
        let available: Int64
        do {
            available = try SKBackupPreflight.availableBytes(home: home)
        } catch let error as SKError {
            fail(error)
            return
        } catch {
            fail(SKError(code: .filesystemUnreadable,
                         stage: "preflight",
                         reason: "free space could not be read"))
            return
        }
        let blocked: SKError?
        switch SKBackupPreflight.decide(estimate, availableBytes: available) {
        case .proceed: blocked = nil
        case .blocked(_, let error): blocked = error
        }
        phase = .preflight(Preflight(report: report,
                                     estimate: estimate,
                                     availableBytes: available,
                                     blocked: blocked))
        render()
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
    }

    private func startRun(_ preflight: Preflight) {
        guard var request, !isWorking else { return }
        // The start action is labelled "Create Partial Backup" for an incomplete scan, so the
        // flag is the user's explicit acceptance, not a default.
        request.allowsPartialBackup = !preflight.report.isComplete
        phase = .running
        runningState = .prepared
        runningCounters = nil
        announcedState = nil
        render()
        let home = self.home
        let report = preflight.report
        let runRequest = request
        runOffMain({ try SKBackupCoordinator.run(home: home, request: runRequest, report: report) }) { result in
            self.finishRun(result)
        }
    }

    private func finishRun(_ result: Result<SKBackupCoordinator.Outcome, SKError>) {
        runningCounters = nil
        switch result {
        case .success(let outcome):
            phase = .verified(outcome)
            SKRuntimeDiagnostics.record("backup_verified;members=\(outcome.verifiedMembers);"
                + "completeness=\(outcome.manifest.backup.completeness.rawValue)")
            // Nothing else in this flow reads the root: the archive is already on disk.
            releaseHome()
        case .failure(let error):
            fail(error)
            return
        }
        render()
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
    }

    private func fail(_ error: SKError) {
        phase = .failed(error)
        runningCounters = nil
        SKRuntimeDiagnostics.record("backup_failed;code=\(error.code.rawValue);"
            + "stage=\(error.stage ?? "backup")")
        render()
        UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
    }

    /// Runs one engine step off the main thread. The step captures only sendable values, so
    /// nothing on this screen is touched until its result is delivered back here.
    private func runOffMain<Value: Sendable>(_ step: @escaping @Sendable () throws -> Value,
                                             then: @escaping @MainActor (Result<Value, SKError>) -> Void) {
        isWorking = true
        navigationController?.isModalInPresentation = true
        cancellation.reset()
        let deliver: @MainActor (Result<Value, SKError>) -> Void = { result in
            self.isWorking = false
            self.navigationController?.isModalInPresentation = false
            if self.isDismissed { self.releaseHome() }
            then(result)
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<Value, SKError>
            do {
                outcome = .success(try step())
            } catch let error as SKError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(SKError(code: .archiveCorrupt,
                                           stage: "backup",
                                           reason: "the transaction failed"))
            }
            Task { @MainActor in deliver(outcome) }
        }
    }

    /// The descriptor outlives the screen only until the worker has stopped, so a cancelled
    /// or finished run never reads through a closed descriptor.
    private func releaseHome() {
        guard !hasReleasedHome else { return }
        hasReleasedHome = true
        onClose?()
    }

    // MARK: - Engine reports

    /// Reports arrive on a worker thread, and they only replace the running screen, so a
    /// report that lands after the transaction ended is ignored.
    private func apply(state: SKBackupCoordinator.State) {
        guard case .running = phase else { return }
        if runningState != state { runningCounters = nil }
        runningState = state
        render()
    }

    private func apply(progress: SKBackupCoordinator.Progress) {
        guard case .running = phase else { return }
        runningCounters = progress
        runningState = progress.state
        render()
    }

    // MARK: - Export

    /// The share sheet is the only handoff. SandboxArk never uploads, and the provider the
    /// user picks decides where the file lands.
    private func export(_ outcome: SKBackupCoordinator.Outcome) {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(outcome.archivePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail(SKError(code: .archiveCorrupt,
                         stage: "export",
                         userAction: "Run the backup again.",
                         reason: "the verified archive is no longer in the container"))
            return
        }
        let deliver: @MainActor (Bool) -> Void = { [weak self] completed in
            self?.exportFinished(completed: completed)
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = primaryButton
        sheet.popoverPresentationController?.sourceRect = primaryButton.bounds
        sheet.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in deliver(completed) }
        }
        present(sheet, animated: true)
        SKRuntimeDiagnostics.record("backup_export_presented")
    }

    private func exportFinished(completed: Bool) {
        SKRuntimeDiagnostics.record(completed ? "backup_export_completed" : "backup_export_dismissed")
        messageLabel.text = completed
            ? String(localized: """
              Exported. Keep the exported copy: SandboxArk's own copy is temporary and your \
              next backup replaces it.
              """, bundle: .sandboxark)
            : String(localized: """
              The archive was not exported. It still sits in SandboxArk's temporary storage \
              and can be exported again.
              """, bundle: .sandboxark)
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch phase {
        case .scope: startScan()
        case .preflight(let preflight):
            if preflight.blocked != nil {
                startScan()
            } else {
                startRun(preflight)
            }
        case .verified(let outcome): export(outcome)
        case .failed: startScan()
        case .scanning, .running: break
        }
    }

    @objc private func closeTapped() {
        if isWorking {
            cancellation.cancel()
            render()
            UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
            return
        }
        cancellation.cancel()
        dismiss(animated: true)
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard isWorking, !cancellation.isCancelled, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: String(localized: "Cancel This Task?", bundle: .sandboxark),
            message: String(localized: "Cancelling stops the current task and removes its temporary files. Wait for cleanup to finish before closing.", bundle: .sandboxark),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Keep Working", bundle: .sandboxark), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Cancel Task", bundle: .sandboxark), style: .destructive) { [weak self] _ in
            guard let self, self.isWorking else { return }
            self.closeTapped()
        })
        present(alert, animated: true)
    }

    // MARK: - Request

    /// Built once: the scope the preflight describes and the transaction that runs are the
    /// same request, so the archive cannot quietly cover a different root set.
    private func makeRequest() -> SKBackupCoordinator.Request? {
        guard let createdAt = SKRFC3339.text(seconds: Int64(Date().timeIntervalSince1970)) else {
            return nil
        }
        let deliverState: @MainActor (SKBackupCoordinator.State) -> Void = { [weak self] state in
            self?.apply(state: state)
        }
        let deliverProgress: @MainActor (SKBackupCoordinator.Progress) -> Void = { [weak self] progress in
            self?.apply(progress: progress)
        }
        var request = SKBackupCoordinator.Request(
            app: SKHostManifest.app(),
            environment: SKHostManifest.environment(),
            outputName: SKBackupFlowViewController.outputName(
                identifier: Bundle.main.bundleIdentifier ?? "app"),
            createdAt: createdAt)
        request.isCancelled = { [cancellation] in cancellation.isCancelled }
        request.onStateChange = { state in Task { @MainActor in deliverState(state) } }
        request.onProgress = { progress in Task { @MainActor in deliverProgress(progress) } }
        return request
    }

    // MARK: - Text

    private static func status(for state: SKBackupCoordinator.State) -> String {
        switch state {
        case .prepared: String(localized: "Starting the backup.", bundle: .sandboxark)
        case .scanning: String(localized: "Scanning the sandbox…", bundle: .sandboxark)
        case .staging: String(localized: "Copying files…", bundle: .sandboxark)
        case .archiving: String(localized: "Writing the archive…", bundle: .sandboxark)
        case .verifying: String(localized: "Verifying the archive…", bundle: .sandboxark)
        case .readyToShare: String(localized: "Backup Verified", bundle: .sandboxark)
        case .cancelled: String(localized: "Backup Cancelled", bundle: .sandboxark)
        case .failed: String(localized: "Backup Failed", bundle: .sandboxark)
        case .cleanupRequired: String(localized: "Cleanup Required", bundle: .sandboxark)
        }
    }

    private static func counters(_ counters: SKBackupCoordinator.Progress) -> String {
        let completed = counters.completedItems.formatted()
        let total = counters.totalItems.formatted()
        var text: String
        switch counters.state {
        case .archiving:
            text = String(localized: "Wrote \(completed) of \(total) archive entries", bundle: .sandboxark)
        default:
            text = String(localized: "Copied \(completed) of \(total) files", bundle: .sandboxark)
        }
        if counters.totalBytes > 0 {
            text += String(localized: " · \(format(counters.completedBytes)) of \(format(counters.totalBytes))",
                           bundle: .sandboxark)
        }
        return text
    }

    /// Incomplete-backup reasons in the format's own vocabulary: counts by reason code, never
    /// the name of a file that failed.
    private func incompleteReason(_ report: SKScanReport) -> String {
        var parts: [String] = []
        switch report.status {
        case .complete: break
        case .cancelled:
            parts.append(String(localized: "The scan stopped before it finished.", bundle: .sandboxark))
        case .entryLimitExceeded:
            parts.append(String(localized: "The scan stopped at the entry limit.", bundle: .sandboxark))
        case .depthExceeded:
            parts.append(String(localized: "The scan stopped at the depth limit.", bundle: .sandboxark))
        }
        if report.unreadableCount > 0 {
            parts.append(String(localized: "\(report.unreadableCount.formatted()) items could not be read.",
                                bundle: .sandboxark))
        }
        let excluded = report.excludedCounts
            .filter { $0.value > 0 }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\(SKExclusionLabel.text($0.key)) (\($0.value.formatted()))" }
        if !excluded.isEmpty {
            parts.append(String(localized: "Excluded by policy: \(excluded.joined(separator: ", ")).",
                                bundle: .sandboxark))
        }
        return parts.isEmpty
            ? String(localized: "Some folders could not be scanned completely.", bundle: .sandboxark)
            : parts.joined(separator: " ")
    }

    /// What the failure did to the data, in the engine's recovery vocabulary.
    private func stagingState(for error: SKError) -> String {
        switch error.recoveryState ?? "" {
        case SKBackupCoordinator.State.cleanupRequired.rawValue:
            String(localized: """
            No archive was created, and this transaction's temporary files could not be removed. \
            They are marked for cleanup.
            """, bundle: .sandboxark)
        case SKBackupCoordinator.State.readyToShare.rawValue:
            String(localized: "The verified archive was kept.", bundle: .sandboxark)
        default:
            String(localized: "No archive was created, and this transaction's temporary files were removed.",
                   bundle: .sandboxark)
        }
    }

    private static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    private static let archiveNameCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    /// The archive name is not part of the format, and the slot holds one file, so the name
    /// is fixed per host app: a name that changed per run would add an archive instead of
    /// replacing the previous one. The creation time lives in the manifest.
    private static func outputName(identifier: String) -> String {
        var slug = ""
        for character in identifier {
            slug.append(archiveNameCharacters.contains(character) ? character : "-")
        }
        return "SandboxArk-\(slug.prefix(80)).sandboxark"
    }
}

/// Public host metadata for the manifest. Only Bundle and OS values are read, so no UDID,
/// Team ID, serial or install ID can reach the archive, and a value longer than the format's
/// field cap is dropped rather than truncated into something the reader would reject.
@MainActor
private enum SKHostManifest {
    static func app() -> SKManifestDocument.App {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
        return SKManifestDocument.App(
            bundleIdentifier: bounded(Bundle.main.bundleIdentifier, maxBytes: 255) ?? "unknown",
            displayName: bounded(name, maxBytes: 255),
            shortVersion: bounded(info["CFBundleShortVersionString"] as? String, maxBytes: 128),
            bundleVersion: bounded(info["CFBundleVersion"] as? String, maxBytes: 128))
    }

    static func environment() -> SKManifestDocument.Environment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SKManifestDocument.Environment(
            platform: UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            deviceModel: deviceModel())
    }

    /// The platform's public model identifier, for example `iPhone17,2`, or `unknown`.
    private static func deviceModel() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        let value = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? "unknown" : value
    }

    private static func bounded(_ text: String?, maxBytes: Int) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= maxBytes else { return nil }
        return text
    }
}
