import AppKit
import Carbon

/// ANSI 键盘布局下的虚拟键码。
let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50,
    "return": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53,
    "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

private let arrowKeys: Set<CGKeyCode> = [123, 124, 125, 126]
private let navigationKeys: Set<CGKeyCode> = [115, 119, 116, 121, 117, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

/// 把按键作为系统键盘事件发给当前获得焦点的 App。
/// 发的是键码而不是字符，所以 Mac 自己的输入法（拼音等）会照常工作。
enum KeySender {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    static func press(_ code: CGKeyCode, flags: CGEventFlags) {
        var flags = flags
        if arrowKeys.contains(code) {
            flags.insert(.maskSecondaryFn)
            flags.insert(.maskNumericPad)
        } else if navigationKeys.contains(code) {
            flags.insert(.maskSecondaryFn)
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// 切换 Mac 的输入法（中/英），不依赖用户设置的切换快捷键。
enum InputSources {
    static func enabled() -> [TISInputSource] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return [] }
        return (0..<CFArrayGetCount(list)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(list, $0), to: TISInputSource.self)
        }
    }

    static func property(_ src: TISInputSource, _ key: CFString) -> String? {
        guard let ptr = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    static func selectNext() {
        let list = enabled()
        guard list.count > 1,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        else { return }
        let currentID = property(current, kTISPropertyInputSourceID)
        let index = list.firstIndex { property($0, kTISPropertyInputSourceID) == currentID } ?? -1
        TISSelectInputSource(list[(index + 1) % list.count])
    }

    /// 当前输入法的简短标识：键盘布局显示 "EN"，输入法显示 "中"。
    static func shortLabel() -> String {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "EN" }
        let type = property(current, kTISPropertyInputSourceType) ?? ""
        return type == (kTISTypeKeyboardLayout as String) ? "EN" : "中"
    }
}
