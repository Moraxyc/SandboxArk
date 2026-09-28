import UIKit

/// Shared with the TestHost report, which does not link this target.
enum SKBrowseDiagnostics {
    static let summaryKey = "com.moraxyc.SandboxArk.browse.summary"
}

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
        if relativePath == nil {
            title = "Browse Sandbox"
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                                target: self,
                                                                action: #selector(doneTapped))
            startScan()
        } else {
            title = relativePath.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "Home"
        }
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
        setRescanItem(isScanning: true)
        tableView.reloadData()

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
        setRescanItem(isScanning: false)
        recordSummary(report)
        cachedSections = nil
        tableView.reloadData()
        if isClosing { closeRoot() }
    }

    private func setRescanItem(isScanning: Bool) {
        guard relativePath == nil else { return }
        if isScanning {
            let item = UIBarButtonItem(title: "Stop", style: .plain, target: self, action: #selector(stopTapped))
            navigationItem.leftBarButtonItem = item
        } else {
            let item = UIBarButtonItem(title: "Rescan", style: .plain, target: self, action: #selector(rescanTapped))
            navigationItem.leftBarButtonItem = item
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
        UserDefaults.standard.set(summary, forKey: SKBrowseDiagnostics.summaryKey)
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
        guard let report else {
            return [Section(title: nil, items: [.message("Scanning the standard roots…")])]
        }
        var summary: [Item] = [
            .detail(title: "Status", value: statusText(report.status)),
            .detail(title: "Files", value: "\(report.includedFiles)"),
            .detail(title: "Size", value: Self.byteText(report.includedBytes)),
            .detail(title: "Unreadable", value: "\(report.unreadableCount)"),
        ]
        if !report.isComplete {
            summary.append(.message("The scan is incomplete: unreadable or unrepresented items are excluded from a backup."))
        }
        let excluded = report.excludedCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { Item.detail(title: Self.reasonText($0.key), value: "\($0.value)") }
        return [
            Section(title: "Scan", items: summary),
            Section(title: "Excluded", items: excluded.isEmpty ? [.message("Nothing was excluded.")] : excluded),
            Section(title: "Roots", items: report.roots.map { Item.root($0) }),
        ]
    }

    private func directorySection(_ relativePath: String) -> Section {
        let listing = SKScanner.listDirectory(relativePath, under: home)
        if let error = listing.error {
            return Section(title: relativePath, items: [.message("\(error.code.rawValue) in \(error.stage ?? "access")")])
        }
        let entries = listing.entries.sorted { left, right in
            if (left.kind == .directory) != (right.kind == .directory) { return left.kind == .directory }
            return left.relativePath < right.relativePath
        }
        var items: [Item] = []
        if listing.status != .complete {
            items.append(.message("The listing stopped early: \(statusText(listing.status))."))
        }
        items.append(contentsOf: entries.map { Item.child($0) })
        if entries.isEmpty { items.append(.message("This directory is empty.")) }
        return Section(title: relativePath, items: items)
    }

    private func statusText(_ status: SKScanStatus) -> String {
        switch status {
        case .complete: "complete"
        case .cancelled: "cancelled"
        case .entryLimitExceeded: "stopped at the entry limit"
        case .depthExceeded: "stopped at the depth limit"
        }
    }

    private static func reasonText(_ reason: SKExclusionReason) -> String {
        switch reason {
        case .cache: "Cache"
        case .tmp: "Temporary"
        case .logs: "Log"
        case .sandboxArkPrivate: "SandboxArk private state"
        case .keychain: "Keychain"
        case .credentialStore: "Credential store"
        case .symlink: "Symbolic link"
        case .specialFile: "Special file"
        case .userOptOut: "Opt-in category (off)"
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
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
        configuration.secondaryTextProperties.numberOfLines = 2

        switch sections[indexPath.section].items[indexPath.row] {
        case .detail(let title, let value):
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
            configuration.secondaryText = "\(root.includedFiles) files · \(Self.byteText(root.includedBytes))"
                + " · \(root.isComplete ? "complete" : "partial")"
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
        if let error = entry.error {
            return "\(error.code.rawValue)\(error.underlyingCode.map { " (errno \($0))" } ?? "")"
        }
        if let reason = entry.excludedReason {
            return "Excluded: \(Self.reasonText(reason))"
        }
        let kind = entry.kind == .directory ? "Folder" : (entry.kind == .regular ? Self.byteText(entry.size) : entry.kind.rawValue)
        return "\(kind) · \(Self.dateText(entry.modifiedAt))"
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
        cancellation.cancel()
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
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
            return "Not previewable here. SandboxArk previews text, JSON and plist only."
        }
        do {
            let opened = try SKPathResolver.openRegularFile(atPath: relativePath, under: home)
            defer { SKPathResolver.closeDescriptor(opened.descriptor) }
            let read = try SKStreamingIO.read(from: opened.descriptor, upTo: SKResourceLimits.maxPreviewBytes)
            guard let text = String(bytes: read.bytes, encoding: .utf8) else {
                return "Not previewable here: the file is not UTF-8 text."
            }
            return read.truncated
                ? text + "\n\n— preview truncated at \(SKResourceLimits.maxPreviewBytes) bytes —"
                : text
        } catch let error as SKError {
            return "\(error.code.rawValue)\(error.relativePath.map { " at \($0)" } ?? "")"
        } catch {
            return "The file could not be read."
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
