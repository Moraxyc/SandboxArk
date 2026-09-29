#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Local, redacted diagnostics only. No analytics, telemetry, remote endpoints or
/// automatic upload; export is a user-initiated Share Sheet action.
enum SKLocalLogger {
    enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    struct ExportMetadata: Sendable {
        let startDate: Date?
        let endDate: Date?
        let totalBytes: Int64
        let fileCount: Int

        var dateRangeDescription: String {
            guard let startDate, let endDate else { return "—" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            let start = formatter.string(from: startDate)
            let end = formatter.string(from: endDate)
            return start == end ? start : "\(start) – \(end)"
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }

        var hasLogs: Bool {
            fileCount > 0 && totalBytes > 0
        }
    }

    /// Single log file budget: <= 2 MiB.
    static let maxFileSize: Int64 = 2 * 1024 * 1024
    /// Total log directory budget: <= 10 MiB.
    static let maxTotalSize: Int64 = 10 * 1024 * 1024
    /// Retain logs up to 7 days.
    static let retentionDays: Int = 7

    private static let queue = DispatchQueue(label: "com.moraxyc.sandboxark.logger")

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let exportTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static var logsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(SKReservedPaths.applicationSupport)
            .appendingPathComponent("Logs")
    }

    static var diagnosticsStagingDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(SKReservedPaths.stagingRoot)
            .appendingPathComponent("diagnostics")
    }

    /// Redacts a file path into its high-level logical root classification.
    /// Never emits filenames, full subpaths, hashes, or credentials.
    static func redact(path: String) -> String {
        var clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = NSHomeDirectory()
        if clean.hasPrefix(home) {
            clean = String(clean.dropFirst(home.count))
        }
        while clean.hasPrefix("/") {
            clean = String(clean.dropFirst())
        }
        while clean.hasSuffix("/") {
            clean = String(clean.dropLast())
        }
        guard !clean.isEmpty else { return "<root>" }

        let standardPrefixes = [
            "Library/Application Support/SandboxArk",
            "Library/Application Support",
            "Library/Preferences",
            "Library/Caches",
            "Library/Logs",
            "Library/WebKit",
            "Library/Cookies",
            "Library",
            "Documents",
            "tmp",
            "SystemData"
        ]

        for prefix in standardPrefixes {
            if clean == prefix {
                return prefix
            }
            if clean.hasPrefix(prefix + "/") {
                return "\(prefix)/<redacted>"
            }
        }

        let components = clean.split(separator: "/")
        if components.count > 1 {
            return "\(components[0])/<redacted>"
        } else {
            return "<redacted>"
        }
    }

    /// Logs an event with category, level, and optional structured details.
    static func log(event: String,
                    category: String = "general",
                    level: Level = .info,
                    details: [String: String]? = nil) {
        let now = Date()
        let timestamp = iso8601Formatter.string(from: now)
        var formattedLine = "[\(timestamp)] [\(level.rawValue)] [\(category)] \(event)"
        if let details, !details.isEmpty {
            let sorted = details.sorted(by: { $0.key < $1.key })
            let pairs = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            formattedLine += " \(pairs)"
        }
        formattedLine += "\n"
        let line = formattedLine

        queue.async {
            writeEntry(line, at: now)
        }
    }

    /// Logs a structured SKError with redacted path.
    static func log(error: SKError, stage: String? = nil) {
        var details: [String: String] = [
            "code": error.code.rawValue,
            "category": error.code.category.rawValue,
            "stage": error.stage ?? stage ?? "unknown",
            "retryable": String(error.retryable)
        ]
        if let underlying = error.underlyingCode {
            details["underlyingCode"] = String(underlying)
        }
        if let path = error.relativePath {
            details["path"] = redact(path: path)
        }
        if let recovery = error.recoveryState {
            details["recoveryState"] = recovery
        }
        log(event: "error_occurred",
            category: error.code.category.rawValue,
            level: .error,
            details: details)
    }

    private static func writeEntry(_ line: String, at date: Date) {
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        let dir = logsDirectory
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        pruneOldLogsIfNeeded()

        let today = dayFormatter.string(from: date)
        let fileURL = activeLogFileURL(for: today, incomingBytes: data.count)

        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: data)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func activeLogFileURL(for dateString: String, incomingBytes: Int) -> URL {
        let baseName = "sandboxark-\(dateString)"
        var index = 0
        let fm = FileManager.default
        while true {
            let fileName = index == 0 ? "\(baseName).log" : "\(baseName).\(index).log"
            let url = logsDirectory.appendingPathComponent(fileName)
            guard fm.fileExists(atPath: url.path) else {
                return url
            }
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                if size + Int64(incomingBytes) <= maxFileSize {
                    return url
                }
            }
            index += 1
        }
    }

    private static func pruneOldLogsIfNeeded() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: logsDirectory,
                                                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return
        }

        let now = Date()
        var validLogs: [(url: URL, size: Int64, modDate: Date)] = []

        for file in entries where file.lastPathComponent.hasPrefix("sandboxark-") && file.lastPathComponent.hasSuffix(".log") {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modDate = values.contentModificationDate else {
                continue
            }
            if now.timeIntervalSince(modDate) > Double(retentionDays) * 86400 {
                try? fm.removeItem(at: file)
            } else {
                validLogs.append((url: file, size: Int64(size), modDate: modDate))
            }
        }

        var totalSize: Int64 = validLogs.reduce(0) { $0 + $1.size }
        if totalSize > maxTotalSize {
            validLogs.sort(by: { $0.modDate < $1.modDate })
            for log in validLogs {
                if totalSize <= maxTotalSize { break }
                try? fm.removeItem(at: log.url)
                totalSize -= log.size
            }
        }
    }

    /// Returns current log directory metadata synchronously.
    static func exportMetadata() -> ExportMetadata {
        queue.sync {
            currentMetadataInternal()
        }
    }

    private static func currentMetadataInternal() -> ExportMetadata {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logsDirectory,
                                                      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return ExportMetadata(startDate: nil, endDate: nil, totalBytes: 0, fileCount: 0)
        }
        let logFiles = files.filter { $0.lastPathComponent.hasPrefix("sandboxark-") && $0.lastPathComponent.hasSuffix(".log") }
        guard !logFiles.isEmpty else {
            return ExportMetadata(startDate: nil, endDate: nil, totalBytes: 0, fileCount: 0)
        }

        var totalBytes: Int64 = 0
        var earliestDate: Date?
        var latestDate: Date?

        for file in logFiles {
            if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                totalBytes += Int64(attrs.fileSize ?? 0)
                if let date = attrs.contentModificationDate {
                    if earliestDate == nil || date < earliestDate! { earliestDate = date }
                    if latestDate == nil || date > latestDate! { latestDate = date }
                }
            }
        }

        return ExportMetadata(startDate: earliestDate,
                              endDate: latestDate,
                              totalBytes: totalBytes,
                              fileCount: logFiles.count)
    }

    /// Prepares an exportable diagnostic package in staging and returns the file URL and metadata.
    static func prepareExportPackage() throws -> (url: URL, metadata: ExportMetadata) {
        try queue.sync {
            let fm = FileManager.default
            try fm.createDirectory(at: diagnosticsStagingDirectory, withIntermediateDirectories: true)
            if let existing = try? fm.contentsOfDirectory(at: diagnosticsStagingDirectory, includingPropertiesForKeys: nil) {
                for file in existing {
                    try? fm.removeItem(at: file)
                }
            }

            let metadata = currentMetadataInternal()
            guard metadata.hasLogs else {
                throw SKError(code: .filesystemUnreadable, stage: "export_diagnostics", reason: "no logs available")
            }

            let timestamp = exportTimestampFormatter.string(from: Date())
            let exportFileName = "sandboxark-diagnostics-\(timestamp).log"
            let exportURL = diagnosticsStagingDirectory.appendingPathComponent(exportFileName)

            let logFiles = try fm.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("sandboxark-") && $0.lastPathComponent.hasSuffix(".log") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            let info = Bundle.main.infoDictionary ?? [:]
            let systemVersion = systemVersionString()
            let deviceModel = deviceModelIdentifier()

            let headerLines = [
                "=== SandboxArk Diagnostic Package ===",
                "Export Time: \(iso8601Formatter.string(from: Date()))",
                "App Name: \(info["CFBundleName"] as? String ?? "Unknown")",
                "Bundle Identifier: \(Bundle.main.bundleIdentifier ?? "unknown")",
                "App Version: \(info["CFBundleShortVersionString"] as? String ?? "unknown") (\(info["CFBundleVersion"] as? String ?? "unknown"))",
                "System Version: \(systemVersion)",
                "Device Model: \(deviceModel)",
                "Redaction Policy: Strictly Redacted (no paths, hashes, tokens, or credentials)",
                "Retention Budget: \(retentionDays) days / \(maxTotalSize / (1024 * 1024)) MiB max",
                "Files Included: \(logFiles.count)",
                "Log Size: \(metadata.formattedSize)",
                "Date Range: \(metadata.dateRangeDescription)",
                "=====================================",
                ""
            ]

            var exportData = Data(headerLines.joined(separator: "\n").utf8)

            for logURL in logFiles {
                let sectionHeader = "\n--- File: \(logURL.lastPathComponent) ---\n"
                if let headerData = sectionHeader.data(using: .utf8) {
                    exportData.append(headerData)
                }
                if let contentData = try? Data(contentsOf: logURL) {
                    exportData.append(contentData)
                }
            }

            try exportData.write(to: exportURL, options: .atomic)
            return (exportURL, metadata)
        }
    }

    /// Cleans up a temporary export package when sharing completes or is dismissed.
    static func cleanupExportPackage(at url: URL) {
        queue.async {
            let stagingPath = diagnosticsStagingDirectory.standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            guard filePath.hasPrefix(stagingPath) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func systemVersionString() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.patchVersion == 0 {
            return "\(os.majorVersion).\(os.minorVersion)"
        } else {
            return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        }
    }

    private static func deviceModelIdentifier() -> String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "Generic Device" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "Generic Device" }
        let value = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? "Generic Device" : value
        #else
        return "Generic Device"
        #endif
    }
}
