import AppKit

/// 不会成为焦点窗口的悬浮面板：点它的时候，正在打字的 App 不会失去焦点。
final class KeyboardPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class KeyboardController {
    static let aspect: CGFloat = 0.34
    static let bubbleSize: CGFloat = 56

    let keyboardView = KeyboardView()
    private let bubble = BubbleView()
    private let panel: KeyboardPanel
    private(set) var collapsed = false
    private var expandedFrame: NSRect
    private let defaults = UserDefaults.standard
    /// 布局改成 68 配列后宽高比变了，换个 key 让旧的窗口尺寸失效。
    private let frameKey = "frame.68"

    var isVisible: Bool { panel.isVisible }

    var opacity: CGFloat {
        get { panel.alphaValue }
        set {
            panel.alphaValue = newValue
            defaults.set(Double(newValue), forKey: "opacity")
        }
    }

    init() {
        let saved = defaults.string(forKey: frameKey).map(NSRectFromString)
        expandedFrame = saved.flatMap { $0.width > 0 ? $0 : nil } ?? Self.defaultFrame()
        panel = KeyboardPanel(contentRect: expandedFrame)
        panel.contentView = keyboardView
        let savedOpacity = defaults.double(forKey: "opacity")
        panel.alphaValue = savedOpacity > 0 ? savedOpacity : 1

        keyboardView.onCollapse = { [weak self] in self?.collapse() }
        bubble.onTap = { [weak self] in self?.expand() }

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel,
                                               queue: .main) { [weak self] _ in self?.saveFrame() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel,
                                               queue: .main) { [weak self] _ in self?.saveFrame() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.collapsed else { return }
            self.panel.setFrame(self.clamped(self.panel.frame), display: true)
        }

        expandedFrame = clamped(expandedFrame)
        panel.setFrame(expandedFrame, display: false)
        if defaults.bool(forKey: "collapsed") { collapse() }
    }

    static func defaultFrame() -> NSRect {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(vf.width * 0.7, 1200)
        let h = w * aspect
        return NSRect(x: vf.midX - w / 2, y: vf.minY + 8, width: w, height: h)
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    func collapse() {
        guard !collapsed else { return }
        expandedFrame = panel.frame
        collapsed = true
        let s = Self.bubbleSize
        panel.contentView = bubble
        panel.setFrame(NSRect(x: expandedFrame.maxX - s, y: expandedFrame.minY, width: s, height: s), display: true)
        defaults.set(true, forKey: "collapsed")
    }

    func expand() {
        guard collapsed else { return }
        // 键盘右下角对齐到小圆点当前的位置。
        let b = panel.frame
        var f = expandedFrame
        f.origin = NSPoint(x: b.maxX - f.width, y: b.minY)
        collapsed = false
        panel.contentView = keyboardView
        panel.setFrame(clamped(f), display: true)
        defaults.set(false, forKey: "collapsed")
    }

    /// 按屏幕宽度的比例设置大小，保持底边中点不动。
    func setWidth(fraction: CGFloat) {
        if collapsed { expand() }
        let vf = panel.screen?.visibleFrame ?? Self.defaultFrame()
        let w = vf.width * fraction
        let old = panel.frame
        let f = NSRect(x: old.midX - w / 2, y: old.minY, width: w, height: w * Self.aspect)
        panel.setFrame(clamped(f), display: true)
    }

    func resetPosition() {
        if collapsed { expand() }
        panel.setFrame(Self.defaultFrame(), display: true)
    }

    private func saveFrame() {
        guard !collapsed else { return }
        expandedFrame = panel.frame
        defaults.set(NSStringFromRect(expandedFrame), forKey: frameKey)
    }

    private func clamped(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return frame }
        var f = frame
        if f.width > vf.width {
            f.size = NSSize(width: vf.width, height: vf.width * Self.aspect)
        }
        f.origin.x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        return f
    }
}
