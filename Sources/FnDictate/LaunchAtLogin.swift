import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items"
        case .notFound: return "Not registered"
        case .notRegistered: return "Off"
        @unknown default: return "Unknown"
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        Log.info("Launch at login: \(statusDescription)")
    }
}
