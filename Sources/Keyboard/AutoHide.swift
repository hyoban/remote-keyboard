import AppKit
import ApplicationServices
import os

let log = Logger(subsystem: "dev.hyoban.remote-keyboard", category: "autohide")

/// Automatically collapses and expands the keyboard:
/// - Follow focus: expand when focus enters a text input and collapse when it leaves. It only acts on
///   focus changes, so it never fights manual actions. Focus-change notifications from the frontmost
///   app make it immediate; polling every 0.5s is only a fallback.
/// - Idle: collapse to a bubble after a period without taps.
final class AutoHide {
    private let controller: KeyboardController
    private let defaults = UserDefaults.standard
    private let systemWide = AXUIElementCreateSystemWide()
    private var timer: Timer?
    private var lastTextFocused: Bool?
    /// A focus change must hold for a moment before acting, filtering out focus flicker in Electron and similar apps.
    private var pendingFocus: (value: Bool, since: Date)?
    private var lastActivity = Date()
    private var lastFrontmostPID: pid_t?
    private var lastLogged = ""
    private var enhancedPIDs: Set<pid_t> = []
    /// The app that last had a focused text input.
    private var lastTextPID: pid_t?
    /// Time of the last click outside the keyboard, to tell "the user clicked away" from focus flicker caused by re-rendering.
    private var lastOutsideClick = Date.distantPast
    private var observer: AXObserver?
    private var observedPID: pid_t?
    /// The focused text input, or nil when focus is elsewhere.
    private var focusedTextElement: AXUIElement?
    /// When avoidance stopped being needed. The keyboard moves back only after 0.6s, so clicking a nearby button doesn't make it bounce.
    private var restorePendingSince: Date?

    var followFocus: Bool {
        get { defaults.object(forKey: "followFocus") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "followFocus")
            lastTextFocused = nil
            pendingFocus = nil
        }
    }

    /// Avoid the input: when the keyboard covers the focused input or the caret line, move it to the other half of the screen.
    var avoidInput: Bool {
        get { defaults.object(forKey: "avoidInput") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "avoidInput")
            if !newValue { controller.avoid(nil) }
        }
    }

    /// 0 means never collapse when idle.
    var idleSeconds: Int {
        get { defaults.integer(forKey: "idleSeconds") }
        set {
            defaults.set(newValue, forKey: "idleSeconds")
            lastActivity = Date()
        }
    }

    init(controller: KeyboardController) {
        self.controller = controller
        // Don't let accessibility queries block the keyboard when the target app hangs.
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.observeFrontmostApp()
            self?.evaluateFocus()
        }
    }

    func noteClick(at point: CGPoint) {
        guard !controller.contains(quartzPoint: point) else { return }
        lastOutsideClick = Date()
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
        guard controller.isVisible, followFocus || avoidInput else { return }
        guard AXIsProcessTrusted() else {
            logOnce("not trusted, focus detection disabled")
            return
        }
        // nil means the query failed (timeout, no focused element, ...) and doesn't count as a focus change.
        if let focused = isTextInputFocused(), followFocus {
            handleFocus(focused)
        }
        updateAvoidance()
    }

    private func updateAvoidance() {
        guard avoidInput else { return }
        let wasAvoiding = controller.avoidFrame != nil
        let target = focusedTextElement.flatMap(avoidanceTarget)
        if target == nil, wasAvoiding {
            let since = restorePendingSince ?? Date()
            if restorePendingSince == nil {
                restorePendingSince = since
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { [weak self] in self?.evaluateFocus() }
            }
            guard Date().timeIntervalSince(since) >= 0.6 else { return }
        }
        restorePendingSince = nil
        controller.avoid(target)
        let avoiding = controller.avoidFrame != nil
        if avoiding != wasAvoiding {
            log.notice("\(avoiding ? "moved aside to avoid the text input" : "moved back", privacy: .public)")
        }
    }

    /// The area to keep clear (Cocoa coordinates): the whole field for short inputs; for tall ones (editors,
    /// documents) only the lines around the caret.
    private func avoidanceTarget(_ element: AXUIElement) -> NSRect? {
        if let frame = Self.frame(of: element), frame.height <= 200 {
            return Self.cocoaRect(frame)
        }
        if let caret = Self.caretBounds(of: element) {
            return Self.cocoaRect(caret.insetBy(dx: -20, dy: -60))
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var pos = CGPoint.zero, size = CGSize.zero
        guard let posValue = axValue(element, kAXPositionAttribute),
              let sizeValue = axValue(element, kAXSizeAttribute),
              AXValueGetValue(posValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private static func caretBounds(of element: AXUIElement) -> CGRect? {
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range
        else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
            let bounds, CFGetTypeID(bounds) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }

    /// The Accessibility API uses Quartz coordinates (origin top left of the main screen); windows use Cocoa (origin bottom left).
    private static func cocoaRect(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Subscribes to the frontmost app's focus notifications so changes are checked immediately.
    private func observeFrontmostApp() {
        guard followFocus || avoidInput, AXIsProcessTrusted(),
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
        // Re-check avoidance when the caret moves or the text wraps to a new line.
        AXObserverAddNotification(created, app, kAXSelectedTextChangedNotification as CFString,
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
        // Expand immediately; collapse only after focus has been stable for 0.6s to filter flicker.
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
            // Browsers like Chrome only expose the focused element once AXEnhancedUserInterface is on.
            // It can affect window animations, so only enable it once for apps that report no focus.
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
            // contenteditable on web pages and the like: a settable selection usually means editable text.
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success {
                isText = settable.boolValue
            }
        }
        if isText {
            focusedTextElement = element
            lastTextPID = app.processIdentifier
        } else if app.processIdentifier == lastTextPID, Self.containerRoles.contains(role),
                  Date().timeIntervalSince(lastOutsideClick) > 1 {
            // Focus moved from an input to a container in the same app without a click: most likely an Electron
            // re-render, so it doesn't count as leaving the input.
            logOnce("\(appName): focused \(role) without click, ignored")
            return nil
        }
        if !isText { focusedTextElement = nil }
        logOnce("\(appName): focused \(role) text=\(isText)")
        return isText
    }

    private static let containerRoles: Set<String> = ["AXGroup", "AXWebArea", "AXScrollArea", "AXUnknown"]

    /// Logs each distinct state once instead of every 0.5s.
    private func logOnce(_ message: String) {
        guard message != lastLogged else { return }
        lastLogged = message
        log.notice("\(message, privacy: .public)")
    }

    /// Electron apps (VS Code, Slack, ...) don't expose accessibility info until asked once explicitly.
    private func enableAccessibility(for pid: pid_t) {
        guard pid != lastFrontmostPID else { return }
        lastFrontmostPID = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
