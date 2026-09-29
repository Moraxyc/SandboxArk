import Foundation

@_silgen_name("SandboxArkLocalizationSection")
private func skLocalizationSection(_ size: UnsafeMutablePointer<UInt>) -> UnsafeRawPointer?

enum SKLocalization {
    static let bundle: Bundle = resolve()

    private static func resolve() -> Bundle {
        guard let bundleURL = materializeBundle(),
              let bundle = Bundle(url: bundleURL),
              carriesCatalog(bundle) else {
            return .main
        }
        return bundle
    }

    private static func materializeBundle() -> URL? {
        var sectionSize: UInt = 0
        guard let section = skLocalizationSection(&sectionSize),
              sectionSize > 0,
              sectionSize <= UInt(Int.max),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }

        let archive = Data(bytes: section, count: Int(sectionSize))
        let identifier = SKSHA256.digest(of: Array(archive)).hex
        let root = caches
            .appendingPathComponent("SandboxArk", isDirectory: true)
            .appendingPathComponent("Localization", isDirectory: true)
        let bundleURL = root.appendingPathComponent("\(identifier).bundle", isDirectory: true)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            if let bundle = Bundle(url: bundleURL), carriesCatalog(bundle) { return bundleURL }
            guard !fileManager.fileExists(atPath: bundleURL.path) else { return nil }

            let stagingURL = root.appendingPathComponent(".\(identifier)-\(UUID().uuidString).bundle", isDirectory: true)
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            do {
                try extract(archive, to: stagingURL)
                guard let bundle = Bundle(url: stagingURL), carriesCatalog(bundle) else {
                    throw LocalizationError.invalidArchive
                }
                try fileManager.moveItem(at: stagingURL, to: bundleURL)
            } catch {
                try? fileManager.removeItem(at: stagingURL)
                throw error
            }
            return bundleURL
        } catch {
            return nil
        }
    }

    private static func carriesCatalog(_ bundle: Bundle) -> Bool {
        bundle.url(forResource: "Localizable", withExtension: "strings") != nil
            || bundle.url(forResource: "Localizable", withExtension: "stringsdict") != nil
    }

    private static func extract(_ archive: Data, to root: URL) throws {
        let bytes = Array(archive)
        let blockSize = 512
        var offset = 0
        var hasInfoPlist = false
        var hasCatalog = false

        while offset + blockSize <= bytes.count {
            let header = Array(bytes[offset ..< offset + blockSize])
            if header.allSatisfy({ $0 == 0 }) { break }

            let expectedChecksum = try octal(header, range: 148 ..< 156)
            let checksum = header.enumerated().reduce(into: 0) { total, item in
                total += (148 ..< 156).contains(item.offset) ? 32 : Int(item.element)
            }
            guard expectedChecksum == UInt64(checksum) else { throw LocalizationError.invalidArchive }

            let name = try string(header, range: 0 ..< 100)
            let prefix = try string(header, range: 345 ..< 500)
            var path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if path.hasSuffix("/") { path.removeLast() }

            let size = try octal(header, range: 124 ..< 136)
            guard size <= UInt64(bytes.count), size <= UInt64(Int.max) else {
                throw LocalizationError.invalidArchive
            }
            let contentStart = offset + blockSize
            let contentSize = Int(size)
            guard contentStart <= bytes.count, contentSize <= bytes.count - contentStart else {
                throw LocalizationError.invalidArchive
            }
            let contentEnd = contentStart + contentSize
            let contentBlocks = (contentSize + blockSize - 1) / blockSize
            guard contentBlocks <= (bytes.count - contentStart) / blockSize else {
                throw LocalizationError.invalidArchive
            }
            let nextOffset = contentStart + contentBlocks * blockSize
            let type = header[156]

            if type == 0 || type == 48 {
                if path == "Info.plist" {
                    hasInfoPlist = true
                } else {
                    let components = path.split(separator: "/")
                    guard components.count == 2,
                          let locale = components.first,
                          locale.hasSuffix(".lproj"),
                          validLocale(locale.dropLast(".lproj".count)),
                          components.last == "Localizable.strings" || components.last == "Localizable.stringsdict" else {
                        throw LocalizationError.invalidArchive
                    }
                    let localeURL = root.appendingPathComponent(String(locale), isDirectory: true)
                    try FileManager.default.createDirectory(at: localeURL, withIntermediateDirectories: true)
                    let destination = localeURL.appendingPathComponent(String(components[1]))
                    try Data(bytes[contentStart ..< contentEnd]).write(to: destination)
                    hasCatalog = true
                }
                if path == "Info.plist" {
                    try Data(bytes[contentStart ..< contentEnd]).write(to: root.appendingPathComponent("Info.plist"))
                }
            } else if type == 53 {
                guard !path.contains("/"), path.hasSuffix(".lproj"), validLocale(path.dropLast(".lproj".count)) else {
                    throw LocalizationError.invalidArchive
                }
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(path, isDirectory: true),
                    withIntermediateDirectories: true
                )
            } else {
                throw LocalizationError.invalidArchive
            }

            offset = nextOffset
        }

        guard hasInfoPlist, hasCatalog else { throw LocalizationError.invalidArchive }
    }

    private static func string(_ bytes: [UInt8], range: Range<Int>) throws -> String {
        let field = bytes[range]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        guard let value = String(bytes: field[..<end], encoding: .utf8) else {
            throw LocalizationError.invalidArchive
        }
        return value
    }

    private static func octal(_ bytes: [UInt8], range: Range<Int>) throws -> UInt64 {
        var value: UInt64 = 0
        var foundDigit = false
        for byte in bytes[range] {
            if byte == 0 || byte == 32 {
                if foundDigit { break }
                continue
            }
            guard (48 ... 55).contains(byte) else { throw LocalizationError.invalidArchive }
            let (multiplied, overflowedMultiply) = value.multipliedReportingOverflow(by: 8)
            let (result, overflowedAdd) = multiplied.addingReportingOverflow(UInt64(byte - 48))
            guard !overflowedMultiply, !overflowedAdd else { throw LocalizationError.invalidArchive }
            value = result
            foundDigit = true
        }
        return value
    }

    private static func validLocale<S: StringProtocol>(_ locale: S) -> Bool {
        !locale.isEmpty && locale.utf8.allSatisfy { byte in
            (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || (48 ... 57).contains(byte) || byte == 45
        }
    }

    private enum LocalizationError: Error {
        case invalidArchive
    }
}

extension Bundle {
    /// The bundle that owns SandboxArk's string catalog.
    static var sandboxark: Bundle { SKLocalization.bundle }
}
