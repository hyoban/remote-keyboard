import AppKit
import ServiceManagement

/// 两个 App 共用的系统相关小功能。
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
            alert.messageText = "设置开机启动失败"
            alert.informativeText = "\(error.localizedDescription)\n请先把 App 拖到“应用程序”文件夹再试。"
            alert.runModal()
        }
    }
}
