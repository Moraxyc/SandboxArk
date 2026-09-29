import UIKit

/// Cooperative cancel flag: the scan polls it between items, and it is the only state
/// the scan thread and the main thread share.
final class SKScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}

/// The exclusion vocabulary the browser and the backup flow share, so one reason never reads
/// two ways. The reason code itself stays in the diagnostics record.
enum SKExclusionLabel {
    static func text(_ reason: SKExclusionReason) -> String {
        switch reason {
        case .cache: String(localized: "Cache", bundle: .sandboxark)
        case .tmp: String(localized: "Temporary Files", bundle: .sandboxark)
        case .logs: String(localized: "Logs", bundle: .sandboxark)
        case .sandboxArkPrivate: String(localized: "SandboxArk's Own Files", bundle: .sandboxark)
        case .keychain: String(localized: "Keychain", bundle: .sandboxark)
        case .credentialStore: String(localized: "Credential Store", bundle: .sandboxark)
        case .symlink: String(localized: "Symbolic Link", bundle: .sandboxark)
        case .specialFile: String(localized: "Unsupported File Type", bundle: .sandboxark)
        case .userOptOut: String(localized: "Category Not Enabled", bundle: .sandboxark)
        }
    }
}

/// Read-only browse of the roots the current process is authorized to read. Paths are shown
/// relative to their root, and listing and preview both go through `SKPathResolver`, so
/// nothing here reaches an object the scanner could not; previews read one bounded buffer.
final class SKSandboxBrowserViewController: UITableViewController {
    private let home: SKAuthorizedRoot
    /// Only the root of the browser stack owns the descriptor's lifetime; a pushed
    /// screen shares it and must never close it.
    private let onClose: (@MainActor () -> Void)?

    private let relativePath: String?
    private let cancellation = SKScanCancellation()
    private var report: SKScanReport?
    private var scanTask: Task<Void, Never>?
    private var isScanning = false
    private var isClosing = false
    private var hasClosedRoot = false
    private var cachedSections: [Section]?
    private let scanIndicator = UIActivityIndicatorView(style: .medium)

    init(home: SKAuthorizedRoot,
         relativePath: String? = nil,
         onClose: (@MainActor () -> Void)? = nil) {
        self.home = home
        self.relativePath = relativePath
        self.onClose = onClose
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("SKSandboxBrowserViewController is created in code only")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        registerContentSizeCategoryChanges()
        if relativePath == nil {
            title = String(localized: "Browse Sandbox", bundle: .sandboxark)
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close,
                                                                target: self,
                                                                action: #selector(doneTapped))
            startScan()
        } else {
            title = relativePath.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
                ?? String(localized: "Home", bundle: .sandboxark)
        }
    }

    private func registerContentSizeCategoryChanges() {
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self],
                                    action: #selector(contentSizeCategoryDidChange))
        } else {
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(contentSizeCategoryDidChange),
                                                   name: UIContentSizeCategory.didChangeNotification,
                                                   object: nil)
        }
    }

    @objc private func contentSizeCategoryDidChange() {
        tableView.reloadData()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let dismissed = isBeingDismissed || navigationController?.isBeingDismissed == true
        if dismissed { requestClose() }
    }

    // MARK: - Scan

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        cancellation.reset()
        cachedSections = nil
        scanIndicator.startAnimating()
        scanIndicator.isAccessibilityElement = false
        setRescanItem(isScanning: true)
        tableView.reloadData()
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "Scanning the sandbox…", bundle: .sandboxark))

        let home = self.home
        let cancellation = self.cancellation
        var scanOptions = SKScanner.Options.standard
        scanOptions.isCancelled = { cancellation.isCancelled }
        let options = scanOptions

        scanTask = Task { [weak self] in
            let report = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: SKScanner.scan(home: home, options: options))
                }
            }
            self?.finishScan(report)
        }
    }

    private func finishScan(_ report: SKScanReport) {
        self.report = report
        isScanning = false
        scanIndicator.stopAnimating()
        setRescanItem(isScanning: false)
        recordSummary(report)
        cachedSections = nil
        tableView.reloadData()
        if isClosing { closeRoot() }
        if !isClosing {
            UIAccessibility.post(notification: .announcement, argument: statusText(report.status))
        }
    }

    private func setRescanItem(isScanning: Bool) {
        guard relativePath == nil else { return }
        if isScanning {
            let item = UIBarButtonItem(title: String(localized: "Stop", bundle: .sandboxark),
                                       style: .plain, target: self, action: #selector(stopTapped))
            navigationItem.leftBarButtonItems = [item, UIBarButtonItem(customView: scanIndicator)]
        } else {
            let item = UIBarButtonItem(title: String(localized: "Rescan", bundle: .sandboxark),
                                       style: .plain, target: self, action: #selector(rescanTapped))
            navigationItem.leftBarButtonItems = [item]
        }
    }

    private func recordSummary(_ report: SKScanReport) {
        let excluded = report.excludedCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: ",")
        let summary = "browse_scan;status=\(report.status.rawValue);files=\(report.includedFiles)"
            + ";bytes=\(report.includedBytes);unreadable=\(report.unreadableCount);excluded=[\(excluded)]"
        SKRuntimeDiagnostics.record(summary)
    }

    // MARK: - Rows

    private enum Item {
        case detail(title: String, value: String)
        case root(SKScanRootResult)
        case child(SKScanEntry)
        case message(String)
    }

    private struct Section {
        let title: String?
        let items: [Item]
    }

    /// Built once per reload: listing a directory costs syscalls, and the table view
    /// asks for the model on every row.
    private var sections: [Section] {
        if let cachedSections { return cachedSections }
        let built = relativePath.map { [directorySection($0)] } ?? scanSections
        cachedSections = built
        return built
    }

    private var scanSections: [Section] {
        if isScanning {
            return [Section(title: nil, items: [.message(String(
                localized: cancellation.isCancelled ? "Stopping…" : "Scanning the sandbox…",
                bundle: .sandboxark))])]
        }
        guard let report else {
            return [Section(title: nil,
                            items: [.message(String(localized: "Scanning the sandbox…", bundle: .sandboxark))])]
        }
        var summary: [Item] = [
            .detail(title: String(localized: "Status", bundle: .sandboxark), value: statusText(report.status)),
            .detail(title: String(localized: "Files", bundle: .sandboxark),
                    value: report.includedFiles.formatted()),
            .detail(title: String(localized: "Size", bundle: .sandboxark),
                    value: Self.byteText(report.includedBytes)),
            .detail(title: String(localized: "Unreadable", bundle: .sandboxark),
                    value: report.unreadableCount.formatted()),
        ]
        if !report.isComplete {
            summary.append(.message(String(
                localized: "This scan is incomplete, so a backup of this sandbox would be partial.",
                bundle: .sandboxark)))
        }
        let excluded = report.excludedCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { Item.detail(title: SKExclusionLabel.text($0.key), value: $0.value.formatted()) }
        return [
            Section(title: String(localized: "Scan", bundle: .sandboxark), items: summary),
            Section(title: String(localized: "Excluded", bundle: .sandboxark),
                    items: excluded.isEmpty
                        ? [.message(String(localized: "Nothing was excluded.", bundle: .sandboxark))]
                        : excluded),
            Section(title: String(localized: "Scanned Folders", bundle: .sandboxark),
                    items: report.roots.map { Item.root($0) }),
        ]
    }

    private func directorySection(_ relativePath: String) -> Section {
        let listing = SKScanner.listDirectory(relativePath, under: home)
        if let error = listing.error {
            SKRuntimeDiagnostics.record("browse_listing_failed;code=\(error.code.rawValue);"
                + "stage=\(error.stage ?? "access")")
            return Section(title: relativePath,
                           items: [.message(String(localized: "This folder could not be listed.",
                                                   bundle: .sandboxark))])
        }
        let entries = listing.entries.sorted { left, right in
            if (left.kind == .directory) != (right.kind == .directory) { return left.kind == .directory }
            return left.relativePath < right.relativePath
        }
        var items: [Item] = []
        switch listing.status {
        case .complete:
            break
        case .cancelled:
            items.append(.message(String(localized: "The listing stopped before it finished.",
                                         bundle: .sandboxark)))
        case .entryLimitExceeded:
            items.append(.message(String(localized: "The listing stopped at the entry limit.",
                                         bundle: .sandboxark)))
        case .depthExceeded:
            items.append(.message(String(localized: "The listing stopped at the depth limit.",
                                         bundle: .sandboxark)))
        }
        items.append(contentsOf: entries.map { Item.child($0) })
        if entries.isEmpty {
            items.append(.message(String(localized: "This folder is empty.", bundle: .sandboxark)))
        }
        return Section(title: relativePath, items: items)
    }

    /// A status label rather than prose: it fills one row of the summary and never ends a
    /// sentence, so each value is capitalized like a heading.
    private func statusText(_ status: SKScanStatus) -> String {
        switch status {
        case .complete: String(localized: "Complete", bundle: .sandboxark)
        case .cancelled: String(localized: "Cancelled", bundle: .sandboxark)
        case .entryLimitExceeded: String(localized: "Stopped at the Entry Limit", bundle: .sandboxark)
        case .depthExceeded: String(localized: "Stopped at the Depth Limit", bundle: .sandboxark)
        }
    }

    /// The right-hand detail of a listed item, which is its size for a file and its type
    /// otherwise; the raw kind is never shown.
    private static func kindText(_ entry: SKScanEntry) -> String {
        switch entry.kind {
        case .directory: String(localized: "Folder", bundle: .sandboxark)
        case .regular: Self.byteText(entry.size)
        case .symlink: SKExclusionLabel.text(.symlink)
        case .special: SKExclusionLabel.text(.specialFile)
        case .unknown: String(localized: "Unknown Type", bundle: .sandboxark)
        }
    }

    fileprivate static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func dateText(_ timestamp: SKFileTimestamp) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp.seconds)
            + TimeInterval(timestamp.nanoseconds) / 1_000_000_000)
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Table view

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].items.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var configuration = cell.defaultContentConfiguration()
        configuration.textProperties.numberOfLines = 0
        configuration.secondaryTextProperties.numberOfLines = 0

        switch sections[indexPath.section].items[indexPath.row] {
        case .detail(let title, let value):
            configuration = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
                ? .subtitleCell() : .valueCell()
            configuration.textProperties.numberOfLines = 0
            configuration.secondaryTextProperties.numberOfLines = 0
            configuration.text = title
            configuration.secondaryText = value
            cell.selectionStyle = .none
            cell.accessoryType = .none
        case .message(let text):
            configuration.text = text
            configuration.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
            cell.accessoryType = .none
        case .root(let root):
            configuration.text = root.relativePath
            let completeness = String(localized: root.isComplete ? "Complete" : "Partial",
                                      bundle: .sandboxark)
            configuration.secondaryText = String(
                localized: """
                \(root.includedFiles.formatted()) files · \
                \(Self.byteText(root.includedBytes)) · \(completeness)
                """, bundle: .sandboxark)
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
        case .child(let entry):
            configuration.text = entry.relativePath.split(separator: "/").last.map(String.init) ?? entry.relativePath
            configuration.secondaryText = childDetail(entry)
            configuration.textProperties.color = entry.error != nil ? .systemRed
                : (entry.excludedReason != nil ? .secondaryLabel : .label)
            cell.selectionStyle = entry.error != nil || entry.excludedReason != nil ? .none : .default
            cell.accessoryType = entry.kind == .directory && entry.excludedReason == nil ? .disclosureIndicator : .none
        }
        cell.contentConfiguration = configuration
        return cell
    }

    private func childDetail(_ entry: SKScanEntry) -> String {
        if entry.error != nil {
            return String(localized: "Could Not Be Read", bundle: .sandboxark)
        }
        if let reason = entry.excludedReason {
            return String(localized: "Excluded: \(SKExclusionLabel.text(reason))", bundle: .sandboxark)
        }
        return String(localized: "\(Self.kindText(entry)) · \(Self.dateText(entry.modifiedAt))",
                      bundle: .sandboxark)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        switch sections[indexPath.section].items[indexPath.row] {
        case .root(let root):
            push(relativePath: root.relativePath)
        case .child(let entry) where entry.error == nil && entry.excludedReason == nil:
            if entry.kind == .directory {
                push(relativePath: entry.relativePath)
            } else if entry.kind == .regular {
                let preview = SKFilePreviewViewController(relativePath: entry.relativePath, home: home)
                navigationController?.pushViewController(preview, animated: true)
            }
        default:
            break
        }
    }

    private func push(relativePath: String) {
        let next = SKSandboxBrowserViewController(home: home, relativePath: relativePath)
        navigationController?.pushViewController(next, animated: true)
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        requestClose()
        dismiss(animated: true)
    }

    @objc private func rescanTapped() {
        startScan()
    }

    @objc private func stopTapped() {
        guard isScanning, !cancellation.isCancelled else { return }
        cancellation.cancel()
        let text = String(localized: "Stopping…", bundle: .sandboxark)
        navigationItem.leftBarButtonItems?.first?.title = text
        navigationItem.leftBarButtonItems?.first?.isEnabled = false
        cachedSections = nil
        tableView.reloadData()
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func requestClose() {
        isClosing = true
        if !isScanning { closeRoot() }
    }

    /// The descriptor outlives the screen until the last reader that derived from it has
    /// finished, so an in-flight scan never reads through a closed descriptor.
    private func closeRoot() {
        guard !hasClosedRoot else { return }
        hasClosedRoot = true
        scanTask = nil
        onClose?()
    }
}

/// Bounded preview of one file, re-opened through the descriptor-based access layer.
final class SKFilePreviewViewController: UIViewController {
    private let relativePath: String
    private let home: SKAuthorizedRoot
    private let textView = UITextView()

    init(relativePath: String, home: SKAuthorizedRoot) {
        self.relativePath = relativePath
        self.home = home
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("SKFilePreviewViewController is created in code only")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        view.backgroundColor = .systemBackground

        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityLabel = title
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        textView.text = previewText()
    }

    private func previewText() -> String {
        guard SKFilePreviewViewController.isPreviewable(relativePath) else {
            return String(localized: "SandboxArk can preview text, JSON, and plist files only.",
                          bundle: .sandboxark)
        }
        do {
            let opened = try SKPathResolver.openRegularFile(atPath: relativePath, under: home)
            defer { SKPathResolver.closeDescriptor(opened.descriptor) }
            let read = try SKStreamingIO.read(from: opened.descriptor, upTo: SKResourceLimits.maxPreviewBytes)
            guard let text = String(bytes: read.bytes, encoding: .utf8) else {
                return String(localized: "This file is not UTF-8 text, so SandboxArk cannot preview it.",
                              bundle: .sandboxark)
            }
            guard read.truncated else { return text }
            let limit = SKSandboxBrowserViewController.byteText(Int64(SKResourceLimits.maxPreviewBytes))
            return text + "\n\n" + String(localized: "Preview truncated at \(limit).", bundle: .sandboxark)
        } catch {
            if let error = error as? SKError {
                SKRuntimeDiagnostics.record("preview_failed;code=\(error.code.rawValue)")
            }
            return String(localized: "The file could not be read.", bundle: .sandboxark)
        }
    }

    private static let previewableExtensions: Set<String> = [
        "txt", "text", "json", "plist", "xml", "md", "markdown", "csv", "tsv", "log",
        "strings", "yaml", "yml", "ini", "conf", "cfg", "html", "htm", "js", "css",
        "swift", "m", "h", "c", "cpp", "sql", "sh", "entitlements", "pbxproj", "geojson",
    ]

    private static func isPreviewable(_ relativePath: String) -> Bool {
        guard let name = relativePath.split(separator: "/").last else { return false }
        guard let dot = name.lastIndex(of: ".") else { return false }
        return previewableExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}
