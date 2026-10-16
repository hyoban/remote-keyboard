import AppKit
import os

private let keyLog = Logger(subsystem: "dev.hyoban.remote-keyboard", category: "keyboard")

/// 修饰键状态：点一下只作用于下一个键，快速点两下锁定，再点一下解除。
final class ModifierState {
    enum Level { case off, once, locked }

    private var levels: [Modifier: Level] = [:]
    private var lastTap: [Modifier: Date] = [:]
    private var onceSince: [Modifier: Date] = [:]

    func level(_ m: Modifier) -> Level { levels[m] ?? .off }

    func tap(_ m: Modifier) {
        let now = Date()
        let quick = now.timeIntervalSince(lastTap[m] ?? .distantPast) < 0.35
        switch level(m) {
        case .off:
            levels[m] = .once
            onceSince[m] = now
        case .once: levels[m] = quick ? .locked : .off
        case .locked: levels[m] = .off
        }
        lastTap[m] = now
    }

    var flags: CGEventFlags {
        Modifier.allCases.reduce(into: CGEventFlags()) { if level($1) != .off { $0.insert($1.flag) } }
    }

    func toggleLock(_ m: Modifier) {
        levels[m] = level(m) == .locked ? .off : .locked
    }

    /// 误触点亮的一次性修饰键超过一段时间没用掉就取消，免得下一次按键意外变成快捷键。
    /// 返回是否有修饰键被取消。
    func expireOnce(olderThan seconds: TimeInterval) -> Bool {
        var changed = false
        for (m, l) in levels where l == .once {
            if Date().timeIntervalSince(onceSince[m] ?? .distantPast) >= seconds {
                levels[m] = .off
                changed = true
            }
        }
        return changed
    }

    func consumeOnce() {
        for (m, l) in levels where l == .once { levels[m] = .off }
    }
}

private enum Palette {
    static let background = NSColor(white: 0.06, alpha: 0.94)
    static let key = NSColor(white: 0.36, alpha: 1)
    static let functionKey = NSColor(white: 0.2, alpha: 1)
    static let pressed = NSColor(white: 0.58, alpha: 1)
    static let accent = NSColor.systemBlue
    static let text = NSColor.white
    static let muted = NSColor(white: 1, alpha: 0.45)
    static let secondaryText = NSColor(white: 1, alpha: 0.55)
    static let warning = NSColor.systemOrange
}

final class KeyboardView: NSView {
    var hasPermission = true { didSet { if oldValue != hasPermission { needsDisplay = true } } }

    var onCollapse: (() -> Void)?
    var onPermissionTap: (() -> Void)?
    var onActivity: (() -> Void)?
    var minWidth: CGFloat = 560

    let mods = ModifierState()

    private var pressed: (row: Int, col: Int)?
    private var repeatDelay: Timer?
    private var repeatTimer: Timer?
    /// 当前这次按压：按下的位置和时间、是否已经开始连发。
    private var touch: (start: NSPoint, time: Date, repeating: Bool)?
    private var lastRelease: (point: NSPoint, time: Date)?
    private var modifierExpiry: Timer?
    private var resizeStart: (mouse: NSPoint, frame: NSRect)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 布局

    private struct Metrics {
        var pad: CGFloat
        var topHeight: CGFloat
        var rowHeight: CGFloat
        var unit: CGFloat
        var gap: CGFloat
    }

    private var metrics: Metrics {
        let w = bounds.width, h = bounds.height
        let pad = max(4, w * 0.008)
        let topHeight = max(20, h * 0.1)
        let rowHeight = (h - topHeight - pad) / CGFloat(Layouts.rowCount)
        let unit = (w - pad * 2) / Layouts.columns
        return Metrics(pad: pad, topHeight: topHeight, rowHeight: rowHeight, unit: unit, gap: max(3, unit * 0.09))
    }

    private func keyFrames() -> [(row: Int, col: Int, def: KeyDef, rect: NSRect)] {
        let m = metrics
        var result: [(Int, Int, KeyDef, NSRect)] = []
        for (r, row) in Layouts.rows.enumerated() {
            var x = m.pad
            let y = m.topHeight + CGFloat(r) * m.rowHeight
            for (c, def) in row.enumerated() {
                let w = def.width * m.unit
                let rect = NSRect(x: x, y: y, width: w, height: m.rowHeight).insetBy(dx: m.gap / 2, dy: m.gap / 2)
                result.append((r, c, def, rect))
                x += w
            }
        }
        return result
    }

    private var collapseRect: NSRect {
        let t = metrics.topHeight
        return NSRect(x: bounds.width - t * 1.8 - metrics.pad, y: 0, width: t * 1.8, height: t)
    }

    private var resizeRect: NSRect {
        let t = metrics.topHeight
        return NSRect(x: metrics.pad, y: 0, width: t * 1.8, height: t)
    }

    private var warningRect: NSRect {
        let r = resizeRect
        return NSRect(x: r.maxX + 6, y: 0, width: bounds.width * 0.3, height: r.height)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        drawTopBar()
        for k in keyFrames() {
            drawKey(k.def, in: k.rect, isPressed: pressed.map { $0 == (k.row, k.col) } ?? false)
        }
    }

    private func drawTopBar() {
        let m = metrics
        let t = m.topHeight

        // 中间的拖动条
        Palette.muted.setFill()
        let grip = NSRect(x: bounds.midX - t * 1.2, y: t * 0.42, width: t * 2.4, height: max(3, t * 0.16))
        NSBezierPath(roundedRect: grip, xRadius: grip.height / 2, yRadius: grip.height / 2).fill()

        drawText("⤡", in: resizeRect, size: t * 0.62, color: Palette.muted)
        drawText("—", in: collapseRect, size: t * 0.55, color: Palette.muted)

        if !hasPermission {
            drawText("⚠︎ 未授权辅助功能，点这里", in: warningRect, size: t * 0.45,
                     color: Palette.warning, alignment: .left)
        }
    }

    private func drawKey(_ def: KeyDef, in rect: NSRect, isPressed: Bool) {
        var fill = def.style == .function ? Palette.functionKey : Palette.key
        var locked = false
        switch def.action {
        case .modifier(let m):
            switch mods.level(m) {
            case .once: fill = Palette.accent
            case .locked: fill = Palette.accent; locked = true
            case .off: break
            }
        case .capsLock where mods.level(.shift) == .locked:
            fill = Palette.accent
            locked = true
        default:
            break
        }
        let fnActive = mods.level(.fn) != .off
        if fnActive, def.fnLabel != nil { fill = Palette.accent.withAlphaComponent(0.55) }
        if isPressed { fill = Palette.pressed }
        fill.setFill()
        let radius = min(rect.height, rect.width) * 0.16
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        if locked {
            Palette.text.setFill()
            let bar = NSRect(x: rect.midX - rect.width * 0.18, y: rect.maxY - rect.height * 0.16,
                             width: rect.width * 0.36, height: max(2, rect.height * 0.05))
            NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
        }

        let shiftActive = mods.level(.shift) != .off
        var label = def.label
        var secondary: String?
        if case .inputSource = def.action { label = InputSources.shortLabel() }
        if def.isLetter, shiftActive { label = label.uppercased() }
        if let shifted = def.shiftedLabel {
            label = shiftActive ? shifted : def.label
            secondary = shiftActive ? def.label : shifted
        }
        if fnActive, let fnLabel = def.fnLabel {
            label = fnLabel
            secondary = nil
        }

        let base = metrics.rowHeight * 0.4
        let size: CGFloat
        switch label.count {
        case 0...1: size = base
        case 2: size = base * 0.75
        default: size = base * 0.56
        }
        if let secondary {
            // 像实体键帽一样：上方小字，下方主字符。
            let top = NSRect(x: rect.minX, y: rect.minY + rect.height * 0.08, width: rect.width, height: rect.height * 0.38)
            let bottom = NSRect(x: rect.minX, y: rect.minY + rect.height * 0.4, width: rect.width, height: rect.height * 0.5)
            drawText(secondary, in: top, size: base * 0.55, color: Palette.secondaryText)
            drawText(label, in: bottom, size: base * 0.85, color: Palette.text)
        } else {
            drawText(label, in: rect, size: size, color: Palette.text)
        }
    }

    private func drawText(_ s: String, in rect: NSRect, size: CGFloat, color: NSColor,
                          alignment: NSTextAlignment = .center) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = str.size().height
        str.draw(in: NSRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h))
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        onActivity?()
        let p = convert(event.locationInWindow, from: nil)
        if p.y < metrics.topHeight {
            if collapseRect.contains(p) {
                onCollapse?()
            } else if resizeRect.contains(p), let window {
                resizeStart = (NSEvent.mouseLocation, window.frame)
            } else if !hasPermission, warningRect.contains(p) {
                onPermissionTap?()
            } else {
                window?.performDrag(with: event)
            }
            return
        }
        // 远控软件偶尔会重复发送同一次点击，同一位置 60ms 内的第二次按下直接忽略。
        if let last = lastRelease, Date().timeIntervalSince(last.time) < 0.06,
           hypot(p.x - last.point.x, p.y - last.point.y) < 4 {
            keyLog.notice("ignored duplicate press")
            return
        }
        guard let hit = key(at: p) else { return }
        // 按下时只高亮，松手时才确认（可以滑到正确的键再松手）。
        pressed = (hit.row, hit.col)
        touch = (p, Date(), false)
        if hit.def.repeats {
            repeatDelay = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                self?.startRepeating()
            }
            RunLoop.current.add(repeatDelay!, forMode: .common)
        }
        needsDisplay = true
    }

    /// 按住可连发的键超过 0.6 秒：先触发一次，然后每 60ms 重复。
    private func startRepeating() {
        guard var t = touch, let pressed,
              let k = keyFrames().first(where: { $0.row == pressed.row && $0.col == pressed.col }),
              let fire = activate(k.def)
        else { return }
        t.repeating = true
        touch = t
        keyLog.notice("repeat \(k.def.label, privacy: .public)")
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in fire() }
        RunLoop.current.add(repeatTimer!, forMode: .common)
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = resizeStart, let window {
            // 拖左上角缩放，右下角固定，保持宽高比。
            let dx = NSEvent.mouseLocation.x - start.mouse.x
            let maxWidth = window.screen?.visibleFrame.width ?? 3000
            let width = min(max(start.frame.width - dx, minWidth), maxWidth)
            let height = width * start.frame.height / start.frame.width
            let frame = NSRect(x: start.frame.maxX - width, y: start.frame.minY, width: width, height: height)
            window.setFrame(frame, display: true)
            return
        }
        guard let t = touch, !t.repeating else { return }
        // 手指滑动时，高亮跟着走到手指下面的键；滑得太远就当作手势，取消高亮。
        let p = convert(event.locationInWindow, from: nil)
        let next = moved(from: t.start, to: p) ? nil : key(at: p).map { ($0.row, $0.col) }
        if next?.0 != pressed?.row || next?.1 != pressed?.col {
            pressed = next
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        resizeStart = nil
        repeatDelay?.invalidate()
        repeatTimer?.invalidate()
        defer {
            touch = nil
            if pressed != nil {
                pressed = nil
                needsDisplay = true
            }
        }
        guard let t = touch else { return }
        let p = convert(event.locationInWindow, from: nil)
        lastRelease = (p, Date())
        let ms = Int(Date().timeIntervalSince(t.time) * 1000)
        let distance = Int(hypot(p.x - t.start.x, p.y - t.start.y))
        if t.repeating { return }
        guard !moved(from: t.start, to: p), let hit = key(at: p) else {
            keyLog.notice("cancelled press: held \(ms)ms, moved \(distance)pt")
            return
        }
        keyLog.notice("tap \(hit.def.label, privacy: .public): held \(ms)ms, moved \(distance)pt")
        _ = activate(hit.def)
        if case .modifier = hit.def.action { scheduleModifierExpiry() }
        needsDisplay = true
    }

    /// 从按下到松手移动超过 1.5 个键宽，就是滑动手势而不是按键。
    private func moved(from a: NSPoint, to b: NSPoint) -> Bool {
        hypot(b.x - a.x, b.y - a.y) > metrics.unit * 1.5
    }

    /// 按整格判断点中了哪个键（键之间的空隙也算），点在两个键中间就算离它最近的那个。
    private func key(at p: NSPoint) -> (row: Int, col: Int, def: KeyDef, rect: NSRect)? {
        guard p.y >= metrics.topHeight else { return nil }
        let gap = metrics.gap
        return keyFrames().first { $0.rect.insetBy(dx: -gap / 2, dy: -gap / 2).contains(p) }
    }

    private func scheduleModifierExpiry() {
        modifierExpiry?.invalidate()
        modifierExpiry = Timer.scheduledTimer(withTimeInterval: 5.05, repeats: false) { [weak self] _ in
            guard let self, self.mods.expireOnce(olderThan: 5) else { return }
            keyLog.notice("one-shot modifier expired")
            self.needsDisplay = true
        }
    }

    /// 执行按键，返回用于长按连发的闭包（连发时沿用第一次按下时的修饰键）。
    private func activate(_ def: KeyDef) -> (() -> Void)? {
        let action = mods.level(.fn) != .off ? def.fnAction ?? def.action : def.action
        switch action {
        case .char(let code):
            let f = mods.flags
            mods.consumeOnce()
            let fire = { KeySender.press(code, flags: f) }
            fire()
            return fire
        case .key(let code, let flags):
            let f = flags.union(mods.flags)
            mods.consumeOnce()
            let fire = { KeySender.press(code, flags: f) }
            fire()
            return fire
        case .modifier(let m):
            mods.tap(m)
        case .capsLock:
            mods.toggleLock(.shift)
        case .inputSource:
            InputSources.selectNext()
        }
        return nil
    }
}

/// 收起后的小圆点：点击展开，拖动移动位置。
final class BubbleView: NSView {
    var onTap: (() -> Void)?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        let config = NSImage.SymbolConfiguration(pointSize: bounds.width * 0.38, weight: .regular)
            .applying(.init(paletteColors: [Palette.text]))
        if let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "展开键盘")?
            .withSymbolConfiguration(config) {
            let s = img.size
            img.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2,
                                width: s.width, height: s.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.mouse.x, dy = now.y - start.mouse.y
        if !dragged, hypot(dx, dy) < 4 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onTap?() }
        dragStart = nil
    }
}
