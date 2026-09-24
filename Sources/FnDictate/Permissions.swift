import Foundation
import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and adds the app to the Accessibility list.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    enum Pane {
        case accessibility, inputMonitoring, microphone, keyboard, loginItems

        var url: URL {
            switch self {
            case .accessibility: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .inputMonitoring: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            case .microphone: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .keyboard: return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
            case .loginItems: return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
            }
        }
    }

    static func open(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }

    /// Best-effort hint from an undocumented macOS preference. Zero has represented
    /// Do Nothing; missing or other values require the user to check Keyboard settings.
    /// This is guidance only, never proof that the physical shortcut works.
    static var systemFnAction: Int? {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
    }

    static var systemFnActionIsNothing: Bool { systemFnAction == 0 }

    static var summary: String {
        var parts: [String] = []
        if microphoneStatus != .authorized { parts.append("Microphone") }
        if !accessibilityGranted { parts.append("Accessibility") }
        return parts.isEmpty ? "All permissions granted" : "Missing: " + parts.joined(separator: ", ")
    }
}
