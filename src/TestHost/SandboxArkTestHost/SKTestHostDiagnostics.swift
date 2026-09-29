import Foundation
import MachO
import UIKit

/// Minimal diagnostics for the owned TestHost. The report omits UDID, serial number,
/// device name, Team ID, credentials and absolute paths.
enum SKTestHostDiagnostics {
    static let eventsKey = "com.moraxyc.SandboxArkTestHost.events"

    static func record(_ event: String) {
        let defaults = UserDefaults.standard
        var events = defaults.stringArray(forKey: eventsKey) ?? []
        events.append("\(timestamp()): \(event)")
        if events.count > 100 {
            events.removeFirst(events.count - 100)
        }
        defaults.set(events, forKey: eventsKey)
    }

    @MainActor
    static func report(hostTapCount: Int) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let dylibPaths = sandboxArkDylibPaths()
        var lines = [
            "SandboxArk TestHost diagnostics",
            "capturedAtUTC: \(timestamp())",
            "privacy: UDID, serial number, device name, Team ID, credentials and absolute paths are omitted",
            "app.bundleIdentifier: \(Bundle.main.bundleIdentifier ?? "unavailable")",
            "app.version: \(info["CFBundleShortVersionString"] as? String ?? "unavailable") (\(info["CFBundleVersion"] as? String ?? "unavailable"))",
            "app.executable: \(info["CFBundleExecutable"] as? String ?? "unavailable")",
            "os.version: \(UIDevice.current.systemVersion)",
            "process.architecture: \(processArchitecture)",
            "injection.sandboxarkDylibLoaded: \(!dylibPaths.isEmpty)",
            "injection.dylibAppRelativePath: \(dylibPaths.isEmpty ? "none" : dylibPaths.joined(separator: ", "))",
            "runtime.sceneCount: \(scenes.count)",
        ]
        var summaries: [String] = []
        for scene in scenes {
            summaries.append(sceneSummary(scene))
        }
        lines.append(contentsOf: summaries.sorted())
        lines.append("host.tapCount: \(hostTapCount)")
        lines.append("events.newestFirst:")
        lines.append(contentsOf: (UserDefaults.standard.stringArray(forKey: eventsKey) ?? []).reversed())
        return lines.joined(separator: "\n")
    }

    @MainActor
    private static func sceneSummary(_ scene: UIWindowScene) -> String {
        let state: String
        switch scene.activationState {
        case .foregroundActive: state = "foregroundActive"
        case .foregroundInactive: state = "foregroundInactive"
        case .background: state = "background"
        case .unattached: state = "unattached"
        @unknown default: state = "unknown"
        }
        let windows = scene.windows
        let visibleWindows = windows.filter { !$0.isHidden }.count
        let hasKeyWindow = windows.contains { $0.isKeyWindow }
        return "runtime.scene: role=\(scene.session.role.rawValue),state=\(state),"
            + "windows=\(windows.count),visibleWindows=\(visibleWindows),keyWindow=\(hasKeyWindow)"
    }

    private static func sandboxArkDylibPaths() -> [String] {
        let bundlePath = Bundle.main.bundlePath
        var paths: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            guard path.hasSuffix("sandboxark.dylib") else { continue }
            if path.hasPrefix(bundlePath + "/") {
                paths.append(String(path.dropFirst(bundlePath.count + 1)))
            } else {
                paths.append((path as NSString).lastPathComponent)
            }
        }
        return paths.sorted()
    }

    private static var processArchitecture: String {
        #if arch(arm64e)
        "arm64e"
        #elseif arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
