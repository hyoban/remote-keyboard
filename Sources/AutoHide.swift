import AppKit
import ApplicationServices

/// 自动收起/展开键盘：
/// - 跟随输入框：焦点进入输入框时展开，离开时收起（只在焦点变化的那一刻动作，不会和手动操作打架）。
/// - 闲置收起：一段时间没有点键盘就收起成小圆点。
final class AutoHide {
    private let controller: KeyboardController
    private let defaults = UserDefaults.standard
    private let systemWide = AXUIElementCreateSystemWide()
    private var timer: Timer?
    private var lastTextFocused: Bool?
    private var lastActivity = Date()
    private var lastFrontmostPID: pid_t?

    var followFocus: Bool {
        get { defaults.object(forKey: "followFocus") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "followFocus")
            lastTextFocused = nil
        }
    }

    /// 0 表示不因闲置收起。
    var idleSeconds: Int {
        get { defaults.integer(forKey: "idleSeconds") }
        set {
            defaults.set(newValue, forKey: "idleSeconds")
            lastActivity = Date()
        }
    }

    init(controller: KeyboardController) {
        self.controller = controller
        // 目标 App 卡住时，别让辅助功能查询阻塞键盘。
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func noteActivity() {
        lastActivity = Date()
    }

    private func tick() {
        guard controller.isVisible else { return }
        if controller.collapsed { lastActivity = Date() }

        if followFocus, AXIsProcessTrusted() {
            let focused = isTextInputFocused()
            if let last = lastTextFocused, focused != last {
                focused ? controller.expand() : controller.collapse()
            }
            lastTextFocused = focused
        }

        if idleSeconds > 0, !controller.collapsed,
           Date().timeIntervalSince(lastActivity) > TimeInterval(idleSeconds) {
            controller.collapse()
        }
    }

    private func isTextInputFocused() -> Bool {
        enableAccessibilityForFrontmostApp()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return false }
        let element = value as! AXUIElement

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if let role = role as? String, textRoles.contains(role) { return true }

        // 网页里的 contenteditable 等：能设置选区的一般就是可编辑文本。
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success {
            return settable.boolValue
        }
        return false
    }

    /// Electron 类 App（VS Code、Slack 等）默认不暴露辅助功能信息，需要显式打开一次。
    private func enableAccessibilityForFrontmostApp() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != lastFrontmostPID
        else { return }
        lastFrontmostPID = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
