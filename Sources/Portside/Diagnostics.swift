import AppKit
import Darwin
import Foundation
import ServiceManagement

/// One-click support bundle: everything needed to debug a report like
/// "black boxes on my new MacBook" without asking the user for screenshots
/// and system details. Deliberately excludes environment variable VALUES —
/// only whether capture worked.
enum Diagnostics {

    @MainActor
    static func report(model: AppModel) -> String {
        [
            "Portside \(AppVersion.current)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Hardware \(hardwareModel()) (\(architecture()))",
            "Bundle \(Bundle.main.bundlePath)",
            "Chrome \(chromeDescription)",
            "Liquid Glass \(liquidGlassAvailable ? "available" : "unavailable")",
            "Servers \(model.servers.count) saved · \(model.ghostServers.count) ephemeral · \(model.liveCount) live",
            "Listening ports \(model.allServers.map { String($0.port) }.sorted().joined(separator: ", "))",
            "Env capture \(model.environmentCaptureSummary)",
            "Launch at login \(SMAppService.mainApp.status == .enabled ? "on" : "off")",
        ].joined(separator: "\n")
    }

    @MainActor
    static var chromeDescription: String {
        if MenuGlassBackground.classicChrome { return "classic (kill switch on)" }
        return MenuGlassBackground.usesChromeCorrections
            ? "glass" : "plain material (pre-macOS 26)"
    }

    static var liquidGlassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static func hardwareModel() -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        var size = buffer.count
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
