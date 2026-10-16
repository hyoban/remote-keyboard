import AppKit

enum Modifier: CaseIterable {
    case shift, cmd, alt, ctrl, fn

    /// fn 只切换键盘层，不附加到发出的按键事件上。
    var flag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .cmd: return .maskCommand
        case .alt: return .maskAlternate
        case .ctrl: return .maskControl
        case .fn: return []
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .cmd: return "⌘"
        case .alt: return "⌥"
        case .ctrl: return "⌃"
        case .fn: return "fn"
        }
    }
}

enum KeyAction {
    case char(code: CGKeyCode)
    /// 固定按键或组合键，如 Esc、方向键、F1。
    case key(code: CGKeyCode, flags: CGEventFlags)
    case modifier(Modifier)
    /// 锁定 Shift。不发送真正的 Caps Lock，因为在 Mac 上它常被用来切换中英文。
    case capsLock
    case inputSource
}

enum KeyStyle {
    case normal, function
}

struct KeyDef {
    var label: String
    /// 数字和符号键上方的字符，如 "1" 上的 "!"。
    var shiftedLabel: String? = nil
    var action: KeyAction
    var width: CGFloat = 1
    var repeats = false
    var style: KeyStyle = .normal
    var isLetter = false
    /// fn 层的替代按键。
    var fnLabel: String? = nil
    var fnAction: KeyAction? = nil
}

private func letter(_ c: Character) -> KeyDef {
    let s = String(c)
    return KeyDef(label: s, action: .char(code: keyCodes[s]!), isLetter: true)
}

private func pair(_ base: String, _ shifted: String, width: CGFloat = 1) -> KeyDef {
    KeyDef(label: base, shiftedLabel: shifted, action: .char(code: keyCodes[base]!), width: width)
}

private func key(_ label: String, _ name: String, width: CGFloat = 1, repeats: Bool = false,
                 style: KeyStyle = .function) -> KeyDef {
    KeyDef(label: label, action: .key(code: keyCodes[name]!, flags: []),
           width: width, repeats: repeats, style: style)
}

private func mod(_ m: Modifier, width: CGFloat = 1) -> KeyDef {
    KeyDef(label: m.symbol, action: .modifier(m), width: width, style: .function)
}

private func withFn(_ def: KeyDef, _ label: String, _ name: String) -> KeyDef {
    var d = def
    d.fnLabel = label
    d.fnAction = .key(code: keyCodes[name]!, flags: [])
    return d
}

/// 68 配列（65%），Mac 键位。每行合计 16 个单位。
enum Layouts {
    static let columns: CGFloat = 16
    static let rowCount = 5

    static let rows: [[KeyDef]] = {
        let numberRow = zip("1234567890-=".map(String.init), "!@#$%^&*()_+".map(String.init))
            .enumerated()
            .map { i, p in withFn(pair(p.0, p.1), "F\(i + 1)", "f\(i + 1)") }
        return [
            [key("esc", "escape")] + numberRow
                + [key("⌫", "backspace", width: 2, repeats: true), pair("`", "~")],
            [key("tab", "tab", width: 1.5)] + "qwertyuiop".map(letter)
                + [pair("[", "{"), pair("]", "}"), pair("\\", "|", width: 1.5),
                   key("⌦", "forwarddelete", repeats: true)],
            [KeyDef(label: "caps", action: .capsLock, width: 1.75, style: .function)] + "asdfghjkl".map(letter)
                + [pair(";", ":"), pair("'", "\""), key("⏎", "return", width: 2.25),
                   withFn(key("PgUp", "pageup"), "Home", "home")],
            [mod(.shift, width: 2.25)] + "zxcvbnm".map(letter)
                + [pair(",", "<"), pair(".", ">"), pair("/", "?"), mod(.shift, width: 1.75),
                   key("↑", "up", repeats: true), withFn(key("PgDn", "pagedown"), "End", "end")],
            [
                mod(.ctrl, width: 1.25), mod(.alt, width: 1.25), mod(.cmd, width: 1.25),
                key("空格", "space", width: 6.25, style: .normal),
                mod(.cmd), mod(.fn),
                KeyDef(label: "", action: .inputSource, style: .function),
                key("←", "left", repeats: true), key("↓", "down", repeats: true), key("→", "right", repeats: true),
            ],
        ]
    }()
}
