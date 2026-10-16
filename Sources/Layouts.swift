import AppKit

enum Modifier: CaseIterable {
    case shift, cmd, alt, ctrl

    var flag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .cmd: return .maskCommand
        case .alt: return .maskAlternate
        case .ctrl: return .maskControl
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .cmd: return "⌘"
        case .alt: return "⌥"
        case .ctrl: return "⌃"
        }
    }
}

enum PanelID {
    case letters, symbols, symbols2, fn
}

enum KeyAction {
    /// 普通字符键；shift 表示该符号本身需要 Shift（如 "!"）。
    case char(code: CGKeyCode, shift: Bool)
    /// 固定组合键，如 Esc、方向键、⌘C。
    case key(code: CGKeyCode, flags: CGEventFlags)
    case modifier(Modifier)
    case panel(PanelID)
    case inputSource
    case spacer
}

enum KeyStyle {
    case normal, function
}

struct KeyDef {
    var label: String
    var action: KeyAction
    var width: CGFloat = 1
    var repeats = false
    var style: KeyStyle = .normal
    var isLetter = false
}

private func flags(_ mods: [Modifier]) -> CGEventFlags {
    mods.reduce(into: CGEventFlags()) { $0.insert($1.flag) }
}

private func letter(_ c: Character) -> KeyDef {
    let s = String(c)
    return KeyDef(label: s, action: .char(code: keyCodes[s]!, shift: false), isLetter: true)
}

private func symbol(_ s: String) -> KeyDef {
    if let base = shiftedSymbols[s] {
        return KeyDef(label: s, action: .char(code: keyCodes[base]!, shift: true))
    }
    return KeyDef(label: s, action: .char(code: keyCodes[s]!, shift: false))
}

private func key(_ label: String, _ name: String, _ mods: [Modifier] = [],
                 width: CGFloat = 1, repeats: Bool = false, style: KeyStyle = .function) -> KeyDef {
    KeyDef(label: label, action: .key(code: keyCodes[name]!, flags: flags(mods)),
           width: width, repeats: repeats, style: style)
}

private func mod(_ m: Modifier, width: CGFloat = 1) -> KeyDef {
    KeyDef(label: m.symbol, action: .modifier(m), width: width, style: .function)
}

private func panel(_ label: String, _ p: PanelID, width: CGFloat) -> KeyDef {
    KeyDef(label: label, action: .panel(p), width: width, style: .function)
}

private func spacer(_ width: CGFloat) -> KeyDef {
    KeyDef(label: "", action: .spacer, width: width)
}

private let backspace = key("⌫", "backspace", repeats: true)

/// 每行宽度合计 11 个单位，四个面板的最后一行结构相同，切换时手感一致。
enum Layouts {
    static let columns: CGFloat = 11
    static let rowCount = 4

    static func rows(for id: PanelID) -> [[KeyDef]] {
        switch id {
        case .letters:
            return [
                "qwertyuiop".map(letter) + [backspace],
                [spacer(0.5)] + "asdfghjkl".map(letter) + [key("⏎", "return", width: 1.5)],
                [mod(.shift, width: 2)] + "zxcvbnm".map(letter) + [symbol(","), symbol(".")],
                bottom(left: ("123", .symbols), right: ("Fn", .fn)),
            ]
        case .symbols:
            return [
                "1234567890".map { symbol(String($0)) } + [backspace],
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map(symbol) + [key("⏎", "return")],
                [panel("#+=", .symbols2, width: 2)] + [".", ",", "?", "!", "'", "*", "+", "=", "%"].map(symbol),
                bottom(left: ("ABC", .letters), right: ("Fn", .fn)),
            ]
        case .symbols2:
            return [
                ["[", "]", "{", "}", "#", "^", "_", "\\", "|", "~"].map(symbol) + [backspace],
                ["<", ">", "`", "-", "/", ":", ";", "(", ")", "\""].map(symbol) + [key("⏎", "return")],
                [panel("123", .symbols, width: 2)] + [".", ",", "?", "!", "'", "*", "+", "=", "%"].map(symbol),
                bottom(left: ("ABC", .letters), right: ("Fn", .fn)),
            ]
        case .fn:
            return [
                [
                    key("Esc", "escape"), key("Tab", "tab"),
                    key("⌘Z", "z", [.cmd]), key("⇧⌘Z", "z", [.cmd, .shift]),
                    key("⌘X", "x", [.cmd]), key("⌘C", "c", [.cmd]), key("⌘V", "v", [.cmd]),
                    key("⌘A", "a", [.cmd]), key("⌘F", "f", [.cmd]), key("⌘S", "s", [.cmd]),
                    backspace,
                ],
                [
                    key("⌘Tab", "tab", [.cmd]), key("⌘`", "`", [.cmd]),
                    key("⌘W", "w", [.cmd]), key("⌘T", "t", [.cmd]), key("⌘N", "n", [.cmd]),
                    key("⌘L", "l", [.cmd]), key("⌃C", "c", [.ctrl]),
                    key("Home", "home"), key("End", "end"),
                    key("↑", "up", repeats: true), key("⏎", "return"),
                ],
                [
                    mod(.shift, width: 2),
                    key("⌘←", "left", [.cmd]), key("⌘→", "right", [.cmd]),
                    key("⌥←", "left", [.alt], repeats: true), key("⌥→", "right", [.alt], repeats: true),
                    key("PgUp", "pageup"), key("PgDn", "pagedown"),
                    key("←", "left", repeats: true), key("↓", "down", repeats: true),
                    key("→", "right", repeats: true),
                ],
                bottom(left: ("ABC", .letters), right: ("123", .symbols)),
            ]
        }
    }

    private static func bottom(left: (String, PanelID), right: (String, PanelID)) -> [KeyDef] {
        [
            panel(left.0, left.1, width: 1.5),
            mod(.cmd), mod(.alt), mod(.ctrl),
            key("空格", "space", width: 4.5, style: .normal),
            KeyDef(label: "", action: .inputSource, style: .function),
            panel(right.0, right.1, width: 1),
        ]
    }
}
