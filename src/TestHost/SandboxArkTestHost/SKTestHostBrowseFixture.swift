import Darwin
import Foundation

/// Synthetic tree for the owned TestHost. Creating it is the host's own action inside
/// this app's container; the injected dylib only ever reads, and every path here exists
/// to exercise one scan rule (T-17).
enum SKTestHostBrowseFixture {
    struct Report {
        var directories = 0
        var files = 0
        var links = 0
        var specials = 0
        var failures: [String] = []

        var summary: String {
            "fixture;directories=\(directories);files=\(files);links=\(links)"
                + ";special=\(specials);failures=\(failures.count)"
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
        ("Library/Application Support/app.sqlite", Data("SQLite format 3\u{0}".utf8)),
        ("Library/Application Support/SandboxArk/ownership-marker", Data("reserved-fixture\n".utf8)),
        ("Library/Application Support/.ssh/id_ed25519", Data("fixture-credential\n".utf8)),
        ("Library/Preferences/com.moraxyc.SandboxArk.Fixture.plist", plist),
        ("Library/Caches/rebuildable.cache", Data(repeating: 0x42, count: 2048)),
        ("Library/Logs/sandboxark-testhost.log", Data("fixture log line\n".utf8)),
        ("Library/WebKit/session-state", Data("fixture webkit state\n".utf8)),
        ("Library/Cookies/Cookies.binarycookies", Data("fixture cookies\n".utf8)),
        ("tmp/scratch", Data("fixture temporary\n".utf8)),
    ]

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
}
