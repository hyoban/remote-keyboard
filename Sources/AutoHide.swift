import AppKit
import ApplicationServices
import os

let log = Logger(subsystem: "dev.hyoban.remote-keyboard", category: "autohide")

/// 自动收起/展开键盘：
/// - 跟随输入框：焦点进入输入框时展开，离开时收起（只在焦点变化的那一刻动作，不会和手动操作打架）。
///   主要靠前台 App 的焦点变化通知即时响应，每 0.5 秒的轮询只作兜底。
/// - 闲置收起：一段时间没有点键盘就收起成小圆点。
final class AutoHide {
    private let controller: KeyboardController
    private let defaults = UserDefaults.standard
    private let systemWide = AXUIElementCreateSystemWide()
    private var timer: Timer?
    private var lastTextFocused: Bool?
    /// 焦点状态变化后要稳定一段时间才动作，过滤 Electron 等 App 里焦点的瞬间闪动。
    private var pendingFocus: (value: Bool, since: Date)?
    private var lastActivity = Date()
    private var lastFrontmostPID: pid_t?
    private var lastLogged = ""
    private var enhancedPIDs: Set<pid_t> = []
    /// 最近一次聚焦在输入框时所在的 App。
    private var lastTextPID: pid_t?
    private var observer: AXObserver?
    private var observedPID: pid_t?

    var followFocus: Bool {
        get { defaults.object(forKey: "followFocus") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "followFocus")
            lastTextFocused = nil
            pendingFocus = nil
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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.observeFrontmostApp()
            self?.evaluateFocus()
        }
    }

    func noteActivity() {
        lastActivity = Date()
    }

    private func tick() {
        guard controller.isVisible else { return }
        if controller.collapsed { lastActivity = Date() }

        observeFrontmostApp()
        evaluateFocus()

        if idleSeconds > 0, !controller.collapsed,
           Date().timeIntervalSince(lastActivity) > TimeInterval(idleSeconds) {
            controller.collapse()
        }
    }

    private func evaluateFocus() {
        guard controller.isVisible, followFocus else { return }
        guard AXIsProcessTrusted() else {
            logOnce("not trusted, focus detection disabled")
            return
        }
        // nil 表示这次没查到（超时、没有焦点元素等），不当作焦点变化。
        if let focused = isTextInputFocused() {
            handleFocus(focused)
        }
    }

    /// 订阅前台 App 的焦点变化通知，焦点一变就立刻检查。
    private func observeFrontmostApp() {
        guard followFocus, AXIsProcessTrusted(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != observedPID
        else { return }
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
            observer = nil
        }
        observedPID = pid
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<AutoHide>.fromOpaque(refcon).takeUnretainedValue().evaluateFocus()
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(created, app, kAXFocusedUIElementChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func handleFocus(_ focused: Bool) {
        guard let last = lastTextFocused else {
            lastTextFocused = focused
            return
        }
        if focused == last {
            pendingFocus = nil
            return
        }
        let now = Date()
        if pendingFocus?.value != focused { pendingFocus = (focused, now) }
        // 展开立即生效；收起等焦点稳定 0.6 秒，过滤闪动。
        let delay: TimeInterval = focused ? 0 : 0.6
        guard let pending = pendingFocus else { return }
        let waited = now.timeIntervalSince(pending.since)
        if waited < delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - waited + 0.02) { [weak self] in
                self?.evaluateFocus()
            }
            return
        }
        log.notice("focus \(last ? "text" : "other", privacy: .public) -> \(focused ? "text" : "other", privacy: .public), \(focused ? "expand" : "collapse", privacy: .public)")
        focused ? controller.expand() : controller.collapse()
        lastTextFocused = focused
        pendingFocus = nil
    }

    private func isTextInputFocused() -> Bool? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        enableAccessibility(for: app.processIdentifier)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)

        var value: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
        if err != .success {
            err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        }
        let appName = app.bundleIdentifier ?? app.localizedName ?? "?"
        if err == .noValue, !enhancedPIDs.contains(app.processIdentifier) {
            // Chrome 等浏览器只有在打开 AXEnhancedUserInterface 后才暴露焦点元素。
            // 这个开关可能影响窗口动画，所以只对查不到焦点的 App 打开一次。
            enhancedPIDs.insert(app.processIdentifier)
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            log.notice("\(appName, privacy: .public): enabled AXEnhancedUserInterface")
        }
        guard err == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            logOnce("\(appName): no focused element (AXError \(err.rawValue))")
            return nil
        }
        let element = value as! AXUIElement

        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? "?"
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
        var isText = textRoles.contains(role)
        if !isText {
            // 网页里的 contenteditable 等：能设置选区的一般就是可编辑文本。
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success {
                isText = settable.boolValue
            }
        }
        if isText {
            lastTextPID = app.processIdentifier
        } else if app.processIdentifier == lastTextPID, Self.containerRoles.contains(role) {
            // Electron 等 App 重新渲染时，焦点会在同一个 App 里从输入框短暂落到容器上，不算离开输入框。
            logOnce("\(appName): focused \(role), ignored (container in same app)")
            return nil
        }
        logOnce("\(appName): focused \(role) text=\(isText)")
        return isText
    }

    private static let containerRoles: Set<String> = ["AXGroup", "AXWebArea", "AXScrollArea", "AXUnknown"]

    /// 同样的状态只记一次，避免每 0.5 秒刷屏。
    private func logOnce(_ message: String) {
        guard message != lastLogged else { return }
        lastLogged = message
        log.notice("\(message, privacy: .public)")
    }

    /// Electron 类 App（VS Code、Slack 等）默认不暴露辅助功能信息，需要显式打开一次。
    private func enableAccessibility(for pid: pid_t) {
        guard pid != lastFrontmostPID else { return }
        lastFrontmostPID = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
