import AppKit

/// A floating panel that never becomes key, so clicking it doesn't take focus from the app being typed into.
final class KeyboardPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        // transient: shown on every Space and hidden while Mission Control is open.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
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
    /// Where the user placed the keyboard ("home"). Avoidance only moves it temporarily and never changes this.
    private var expandedFrame: NSRect
    /// Temporary frame while avoiding a text input; nil when at home.
    private(set) var avoidFrame: NSRect?
    /// True while the code moves the window, so the move isn't saved as the user's new position.
    private var movingProgrammatically = false
    private let defaults = UserDefaults.standard
    /// The aspect ratio changed with the 68-key layout; a new key discards old window sizes.
    private let frameKey = "frame.68"

    var isVisible: Bool { panel.isVisible }

    /// Whether a Quartz global point (origin at the top left of the main screen) is on the keyboard.
    func contains(quartzPoint p: CGPoint) -> Bool {
        guard panel.isVisible, let primary = NSScreen.screens.first else { return false }
        return panel.frame.contains(NSPoint(x: p.x, y: primary.frame.height - p.y))
    }

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
        if avoidFrame == nil { expandedFrame = panel.frame }
        avoidFrame = nil
        collapsed = true
        let s = Self.bubbleSize
        panel.contentView = bubble
        panel.setFrame(NSRect(x: expandedFrame.maxX - s, y: expandedFrame.minY, width: s, height: s), display: true)
        defaults.set(true, forKey: "collapsed")
    }

    func expand() {
        guard collapsed else { return }
        // Align the keyboard's bottom right corner with the bubble.
        let b = panel.frame
        var f = expandedFrame
        f.origin = NSPoint(x: b.maxX - f.width, y: b.minY)
        collapsed = false
        panel.contentView = keyboardView
        panel.setFrame(clamped(f), display: true)
        defaults.set(false, forKey: "collapsed")
    }

    /// Sizes the keyboard to a fraction of the screen width, keeping the bottom center fixed.
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

    /// Keeps the keyboard clear of target (Cocoa coordinates): moves to the other half of the screen when it
    /// overlaps, and back home when it no longer does.
    func avoid(_ target: NSRect?) {
        guard !collapsed, panel.isVisible else { return }
        let home = expandedFrame
        let margin: CGFloat = 12
        guard let target, home.insetBy(dx: -margin, dy: -margin).intersects(target) else {
            if avoidFrame != nil {
                avoidFrame = nil
                move(to: home)
            }
            return
        }
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame ?? home
        var alternate = home
        alternate.origin.y = home.midY < vf.midY ? vf.maxY - home.height - 8 : vf.minY + 8
        alternate = clamped(alternate)
        func overlap(_ r: NSRect) -> CGFloat {
            let i = r.intersection(target)
            return i.isNull ? 0 : i.width * i.height
        }
        // Only move if the other position overlaps less.
        let best = overlap(alternate) < overlap(home) ? alternate : home
        if best == home {
            if avoidFrame != nil {
                avoidFrame = nil
                move(to: home)
            }
        } else if avoidFrame != best {
            avoidFrame = best
            move(to: best)
        }
    }

    private func move(to frame: NSRect) {
        movingProgrammatically = true
        panel.setFrame(frame, display: true, animate: true)
        movingProgrammatically = false
    }

    private func saveFrame() {
        guard !collapsed, !movingProgrammatically else { return }
        // The user dragged or resized the keyboard: this is the new home, and we're no longer avoiding.
        avoidFrame = nil
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
