import Darwin
import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Synthetic tree for the owned TestHost. Creating it is the host's own action inside
/// this app's container; the injected dylib only ever reads, and every path here exists
/// to exercise one scan rule (T-17).
enum SKTestHostBrowseFixture {
    struct Report {
        var directories = 0
        var files = 0
        var links = 0
        var specials = 0
        var databases = 0
        var failures: [String] = []

        var summary: String {
            "fixture;directories=\(directories);files=\(files);links=\(links)"
                + ";special=\(specials);databases=\(databases);failures=\(failures.count)"
        }
    }

    private static let directories = [
        "Documents/nested/deep",
        "Library/Application Support/SandboxArk",
        "Library/Application Support/.ssh",
        "Library/Preferences",
        "Library/Caches",
        "Library/Logs",
        "Library/WebKit",
        "Library/Cookies",
        "tmp",
    ]

    private static let files: [(path: String, contents: Data)] = [
        ("Documents/notes.txt", Data("SandboxArk TestHost fixture notes.\n".utf8)),
        ("Documents/nested/deep/payload.bin", Data(repeating: 0x41, count: 4096)),
        ("Library/Application Support/SandboxArk/ownership-marker", Data("reserved-fixture\n".utf8)),
        ("Library/Application Support/.ssh/id_ed25519", Data("fixture-credential\n".utf8)),
        ("Library/Preferences/com.moraxyc.SandboxArk.Fixture.plist", plist),
        ("Library/Caches/rebuildable.cache", Data(repeating: 0x42, count: 2048)),
        ("Library/Logs/sandboxark-testhost.log", Data("fixture log line\n".utf8)),
        ("Library/WebKit/session-state", Data("fixture webkit state\n".utf8)),
        ("Library/Cookies/Cookies.binarycookies", Data("fixture cookies\n".utf8)),
        ("tmp/scratch", Data("fixture temporary\n".utf8)),
    ]

    /// The one fixture file that cannot be a byte literal: the SQLite check needs a database
    /// that really opens, and its WAL only exists while a connection stays open (T-18, T-19).
    private static let databasePath = "Library/Application Support/app.sqlite"

    /// `/etc/hosts` is outside the container and must never be followed; the dangling
    /// link proves a broken target is still reported rather than skipped silently.
    private static let links: [(path: String, target: String)] = [
        ("Documents/escape-link", "/etc/hosts"),
        ("Documents/dangling-link", "missing-target"),
        ("Documents/caches-link", "../Library/Caches"),
    ]

    private static let plist: Data = {
        let value: [String: Any] = ["fixture": true, "purpose": "browse-preview"]
        return (try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0))
            ?? Data("<plist><dict/></plist>".utf8)
    }()

    @MainActor
    static func create(in home: URL) -> Report {
        let manager = FileManager.default
        var report = Report()

        for directory in directories {
            do {
                try manager.createDirectory(at: home.appendingPathComponent(directory),
                                            withIntermediateDirectories: true)
                report.directories += 1
            } catch {
                report.failures.append(directory)
            }
        }

        for file in files {
            do {
                try file.contents.write(to: home.appendingPathComponent(file.path))
                report.files += 1
            } catch {
                report.failures.append(file.path)
            }
        }

        if createDatabase(at: home.appendingPathComponent(databasePath)) {
            report.databases += 1
        } else {
            report.failures.append(databasePath)
        }

        for link in links {
            let location = home.appendingPathComponent(link.path).path
            let created = link.target.withCString { target in
                location.withCString { path in symlink(target, path) }
            }
            if created == 0 || errno == EEXIST {
                report.links += 1
            } else {
                report.failures.append(link.path)
            }
        }

        let pipe = home.appendingPathComponent("Documents/pipe").path
        if pipe.withCString({ mkfifo($0, 0o644) }) == 0 || errno == EEXIST {
            report.specials += 1
        } else {
            report.failures.append("Documents/pipe")
        }

        return report
    }

    // MARK: - SQLite fixture

    #if canImport(SQLite3)
    /// Kept open for the lifetime of the process: SQLite removes `-wal` and `-shm` when the
    /// last connection closes, and a checkpoint would move the committed rows into the main
    /// file, so the sidecars the backup has to carry would not exist when it runs.
    @MainActor
    private static var database: OpaquePointer?

    @MainActor
    private static func createDatabase(at url: URL) -> Bool {
        if let database { return insertRow(into: database) }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &handle,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard opened == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            return false
        }
        let seeded = run(handle, "PRAGMA journal_mode=WAL")
            && run(handle, "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
            && insertRow(into: handle)
        guard seeded else {
            sqlite3_close_v2(handle)
            return false
        }
        database = handle
        return true
    }

    private static func insertRow(into handle: OpaquePointer) -> Bool {
        run(handle, "INSERT INTO notes (body) VALUES ('fixture row')")
    }

    private static func run(_ handle: OpaquePointer, _ statement: String) -> Bool {
        sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK
    }
    #else
    /// Without a SQLite module the file is only the header every SQLite file starts with:
    /// the scanner still groups it, and the Level 2 check reports unsupported instead of ok.
    private static func createDatabase(at url: URL) -> Bool {
        (try? Data("SQLite format 3\u{0}".utf8).write(to: url)) != nil
    }
    #endif
}
