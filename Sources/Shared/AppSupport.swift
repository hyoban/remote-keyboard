import AppKit
import ServiceManagement

/// Small system helpers shared by both apps.
enum AppSupport {
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change launch at login"
            alert.informativeText = "\(error.localizedDescription)\nMove the app to the Applications folder and try again."
            alert.runModal()
        }
    }
}
