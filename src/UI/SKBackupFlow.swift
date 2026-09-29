import Darwin
import UIKit

/// Backup confirmation, progress, cancellation and export handoff. The engine runs off the
/// main thread and reports through its request, so every report reaches this screen on the
/// main actor, and the screen owns the root descriptor until the worker has stopped.
final class SKBackupFlowViewController: UIViewController {
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
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)

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
        title = "Create Backup"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close,
                                                            target: self,
                                                            action: #selector(closeTapped))
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

        detailLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .label
        detailLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .footnote)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0

        progressView.progress = 0

        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        secondaryButton.addTarget(self, action: #selector(secondaryTapped), for: .touchUpInside)

        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center

        let buttons = UIStackView(arrangedSubviews: [primaryButton, secondaryButton])
        buttons.axis = .vertical
        buttons.spacing = 12
        buttons.alignment = .fill

        let stack = UIStackView(arrangedSubviews: [statusRow, progressView, detailLabel, messageLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    /// One place decides which actions a phase offers, so a button can never stay live for a
    /// step that has already finished.
    private func setButtons(primary: String?, primaryEnabled: Bool = true, secondary: String?) {
        primaryButton.setTitle(primary, for: .normal)
        primaryButton.isHidden = primary == nil
        primaryButton.isEnabled = primaryEnabled
        secondaryButton.setTitle(secondary, for: .normal)
        secondaryButton.isHidden = secondary == nil
    }

    // MARK: - Rendering

    private func render() {
        switch phase {
        case .scope: renderScope()
        case .scanning: renderScanning()
        case .preflight(let preflight): renderPreflight(preflight)
        case .running: renderRunning()
        case .verified(let outcome): renderVerified(outcome)
        case .failed(let error): renderFailure(error)
        }
    }

    private func renderScope() {
        statusLabel.text = "Create Backup"
        detailLabel.text = "Scope: standard — \(SKScanner.standardRootPaths.joined(separator: ", "))."
        messageLabel.text = """
        SandboxArk may access all files that this app itself can access. A backup of this \
        sandbox can contain private app data. It is written into this app's own container as \
        a SandboxArk/\(SKManifest.formatVersion) .sandboxark archive and only leaves it when \
        you export it, which is the only time SandboxArk asks another app to read it. \
        SandboxArk never uploads anything, never reads Keychain items, and never reaches \
        another app's container.
        """
        spinner.stopAnimating()
        progressView.isHidden = true
        setButtons(primary: "Scan Sandbox", secondary: "Cancel")
    }

    private func renderScanning() {
        statusLabel.text = SKBackupFlowViewController.status(for: .scanning)
        detailLabel.text = "Counting the files the standard scope covers. Nothing is copied yet."
        messageLabel.text = "The scan only reads; stopping it leaves the sandbox unchanged."
        spinner.startAnimating()
        progressView.isHidden = true
        setButtons(primary: nil, secondary: "Cancel")
    }

    private func renderPreflight(_ preflight: Preflight) {
        let estimate = preflight.estimate
        statusLabel.text = "Ready to back up"
        var lines = [
            "Files: \(estimate.includedFiles)",
            "Source data: \(SKBackupFlowViewController.format(estimate.sourceBytes))",
            "Worst case during the backup: \(SKBackupFlowViewController.format(estimate.totalBytes))"
                + " (uncompressed staging copy plus archive and index)",
            "Free space needed: \(SKBackupFlowViewController.format(estimate.requiredBytes)),"
                + " including a \(SKBackupFlowViewController.format(estimate.reserveBytes)) reserve",
            "Free space now: \(SKBackupFlowViewController.format(preflight.availableBytes))",
        ]
        if estimate.directoryMembers > 0 {
            lines.insert("Directories: \(estimate.directoryMembers)", at: 1)
        }
        detailLabel.text = lines.joined(separator: "\n")

        if let blocked = preflight.blocked {
            messageLabel.text = "This backup cannot start. \(blocked.reason ?? "")"
                + " \(blocked.userAction ?? "")"
        } else if preflight.report.isComplete {
            messageLabel.text = "The estimate is a worst case: it reserves one uncompressed "
                + "staging copy and a ZIP64 archive. The scan is a candidate list, so every file "
                + "is re-opened and re-checked while it is copied."
        } else {
            messageLabel.text = incompleteReason(preflight.report)
                + " The archive will be marked partial (manifest.backup.completeness = partial) "
                + "and every root that could not be read completely is listed in the manifest."
        }
        spinner.stopAnimating()
        progressView.isHidden = true
        let partial = !preflight.report.isComplete
        setButtons(primary: partial ? "Create Partial Backup" : "Start Backup",
                   primaryEnabled: preflight.blocked == nil,
                   secondary: "Cancel")
    }

    private func renderRunning() {
        let state = runningState ?? runningCounters?.state ?? .prepared
        statusLabel.text = SKBackupFlowViewController.status(for: state)
        if let counters = runningCounters, counters.totalItems > 0 {
            progressView.progress = Float(Double(counters.completedItems) / Double(counters.totalItems))
            progressView.isHidden = false
            spinner.stopAnimating()
            detailLabel.text = SKBackupFlowViewController.counters(counters)
        } else {
            progressView.isHidden = true
            spinner.startAnimating()
            detailLabel.text = state == .verifying
                ? "Re-reading every member and comparing its CRC and SHA-256."
                : "Preparing the transaction."
        }
        messageLabel.text = "Cancel stops the backup at the next chunk boundary and removes "
            + "this transaction's temporary files. Only a fully verified archive becomes shareable."
        setButtons(primary: nil, secondary: "Cancel Backup")
        announce(state)
    }

    private func renderVerified(_ outcome: SKBackupCoordinator.Outcome) {
        let manifest = outcome.manifest
        statusLabel.text = manifest.backup.completeness == .complete
            ? "Backup verified"
            : "Partial backup verified"
        var lines = [
            "Files: \(manifest.backup.totalFiles) · \(SKBackupFlowViewController.format(manifest.backup.totalBytes))",
            "Archive members: \(outcome.verifiedMembers) · CRC and SHA-256 matched for every one",
            "Format: \(SKManifest.format)/\(SKManifest.formatVersion)",
            "Completeness: \(manifest.backup.completeness.rawValue)",
            "Preferences: \(manifest.backup.preferencesConsistency)"
                + " · SQLite groups recorded: \(manifest.sqliteGroups.count)",
        ]
        if manifest.backup.warningCount > 0 {
            lines.append("Warnings: \(manifest.backup.warningCount)")
        }
        let incomplete = manifest.roots.filter { !$0.complete }
        if !incomplete.isEmpty {
            let described = incomplete.map { "\($0.relativeRoot) (\($0.unreadableCount) unreadable)" }
            lines.append("Incomplete roots: \(described.joined(separator: ", "))")
        }
        detailLabel.text = lines.joined(separator: "\n")

        messageLabel.text = "Export hands the archive to the share sheet: Files or another "
            + "provider decides where it lands, and SandboxArk cannot tell whether that export "
            + "finished. A copy left inside this app's container is deleted with the app."
        spinner.stopAnimating()
        progressView.isHidden = true
        setButtons(primary: "Export…", secondary: "Done")
    }

    private func renderFailure(_ error: SKError) {
        let cancelled = error.code == .cancelled
        statusLabel.text = cancelled ? "Backup cancelled" : "Backup failed"
        var lines = ["Code: \(error.code.rawValue)"]
        if let stage = error.stage { lines.append("Stage: \(stage)") }
        if let reason = error.reason { lines.append(reason) }
        if let action = error.userAction { lines.append("Next: \(action)") }
        detailLabel.text = lines.joined(separator: "\n")
        messageLabel.text = stagingState(for: error)
        spinner.stopAnimating()
        progressView.isHidden = true
        setButtons(primary: cancelled ? nil : "Try Again", secondary: "Close")
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
        phase = .scanning
        runningState = nil
        runningCounters = nil
        render()
        let home = self.home
        runOffMain({ try SKBackupCoordinator.scan(home: home, request: request) }) { result in
            switch result {
            case .success(let report): self.showPreflight(for: report)
            case .failure(let error): self.fail(error)
            }
        }
    }

    /// The measured estimate the user confirms. When free space is short the numbers stay
    /// visible and only the start action closes, so the refusal is not a mystery.
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
        }
        render()
    }

    private func fail(_ error: SKError) {
        phase = .failed(error)
        runningCounters = nil
        SKRuntimeDiagnostics.record("backup_failed;code=\(error.code.rawValue);"
            + "stage=\(error.stage ?? "backup")")
        render()
    }

    /// Runs one engine step off the main thread. The step captures only sendable values, so
    /// nothing on this screen is touched until its result is delivered back here.
    private func runOffMain<Value: Sendable>(_ step: @escaping @Sendable () throws -> Value,
                                             then: @escaping @MainActor (Result<Value, SKError>) -> Void) {
        isWorking = true
        cancellation.reset()
        let deliver: @MainActor (Result<Value, SKError>) -> Void = { result in
            self.isWorking = false
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
            ? "Exported. The staged copy stays in this app's container until it is cleaned up, "
                + "and it is deleted with the app."
            : "Export dismissed. The verified archive stays in this container and can be "
                + "exported again."
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch phase {
        case .scope: startScan()
        case .preflight(let preflight): startRun(preflight)
        case .verified(let outcome): export(outcome)
        case .failed: startScan()
        case .scanning, .running: break
        }
    }

    @objc private func secondaryTapped() {
        cancellation.cancel()
        dismiss(animated: true)
    }

    @objc private func closeTapped() {
        secondaryTapped()
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
                createdAt: createdAt,
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
        case .prepared, .scanning: "Scanning the sandbox…"
        case .staging: "Copying files into staging…"
        case .archiving: "Writing the archive…"
        case .verifying: "Verifying the archive…"
        case .readyToShare: "Backup verified"
        case .cancelled: "Backup cancelled"
        case .failed: "Backup failed"
        case .cleanupRequired: "Cleanup required"
        }
    }

    private static func counters(_ counters: SKBackupCoordinator.Progress) -> String {
        var text: String
        switch counters.state {
        case .archiving:
            text = "\(counters.completedItems) of \(counters.totalItems) archive members"
        default:
            text = "\(counters.completedItems) of \(counters.totalItems) files"
        }
        if counters.totalBytes > 0 {
            text += " · \(format(counters.completedBytes)) of \(format(counters.totalBytes))"
        }
        return text
    }

    /// Incomplete-backup reasons in the format's own vocabulary: counts by reason code, never
    /// the name of a file that failed.
    private func incompleteReason(_ report: SKScanReport) -> String {
        var parts: [String] = []
        switch report.status {
        case .complete: break
        case .cancelled: parts.append("The scan stopped before it finished.")
        case .entryLimitExceeded: parts.append("The scan stopped at the entry limit.")
        case .depthExceeded: parts.append("The scan stopped at the depth limit.")
        }
        if report.unreadableCount > 0 {
            parts.append("\(report.unreadableCount) items could not be read.")
        }
        let excluded = report.excludedCounts
            .filter { $0.value > 0 }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value)×\($0.key.rawValue)" }
        if !excluded.isEmpty {
            parts.append("Excluded by policy: \(excluded.joined(separator: ", ")).")
        }
        return parts.isEmpty ? "Some roots are not complete." : parts.joined(separator: " ")
    }

    /// What the failure did to the data, in the engine's recovery vocabulary.
    private func stagingState(for error: SKError) -> String {
        switch error.recoveryState ?? "" {
        case SKBackupCoordinator.State.cleanupRequired.rawValue:
            "No archive was created, and this transaction's temporary files could not be removed."
                + " They are marked for cleanup."
        case SKBackupCoordinator.State.readyToShare.rawValue:
            "The verified archive was kept."
        default:
            "No archive was created; this transaction's staging files were removed."
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

    /// The archive name is not part of the format: the transaction directory already
    /// separates runs, so the name only has to be a plain file name a Files app can show.
    private static func outputName(createdAt: String, identifier: String) -> String {
        let stamp = createdAt.filter { $0.isNumber || $0 == "T" || $0 == "Z" }
        var slug = ""
        for character in identifier {
            slug.append(archiveNameCharacters.contains(character) ? character : "-")
        }
        return "SandboxArk-\(slug.prefix(80))-\(stamp).sandboxark"
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
