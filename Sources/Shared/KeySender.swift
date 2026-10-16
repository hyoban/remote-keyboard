import AppKit
import Carbon

/// Virtual key codes for the ANSI layout.
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

/// Posts keys as system keyboard events to the focused app.
/// It sends key codes rather than characters, so the Mac's own input methods keep working.
enum KeySender {
    private static let source = CGEventSource(stateID: .hidSystemState)

    /// Accessibility trust is the only permission needed: it covers both posting keys and reading the focused element.
    static var hasPermission: Bool { AXIsProcessTrusted() }

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

    /// Types a whole piece of text at the cursor (used for Telegram messages).
    /// Single lines are injected as Unicode; multi-line text is pasted so newlines don't act as Return and send early.
    static func type(_ text: String) {
        if text.contains("\n") {
            paste(text)
        } else {
            InputSources.withKeyboardLayout { typeUnicode(text) }
        }
    }

    private static func typeUnicode(_ s: String) {
        let units = Array(s.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[i..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(4000)
            i = end
        }
    }

    private static var savedPasteboard: [NSPasteboardItem]?
    private static var restoreWork: DispatchWorkItem?

    /// Clipboard + ⌘V, restoring the previous clipboard contents afterwards.
    private static func paste(_ text: String) {
        let pb = NSPasteboard.general
        if savedPasteboard == nil {
            savedPasteboard = (pb.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for t in item.types {
                    if let d = item.data(forType: t) { copy.setData(d, forType: t) }
                }
                return copy
            }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        usleep(20_000)
        press(keyCodes["v"]!, flags: .maskCommand)
        restoreWork?.cancel()
        let work = DispatchWorkItem {
            guard let items = savedPasteboard else { return }
            pb.clearContents()
            if !items.isEmpty { pb.writeObjects(items) }
            savedPasteboard = nil
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

/// Switches the Mac's input source without relying on the user's switching shortcut.
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

    /// When an input method (e.g. Pinyin) is active, temporarily switch to an ASCII layout so it can't intercept injected characters.
    static func withKeyboardLayout(_ body: () -> Void) {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              property(current, kTISPropertyInputSourceType) != (kTISTypeKeyboardLayout as String),
              let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        else {
            body()
            return
        }
        TISSelectInputSource(ascii)
        usleep(40_000)
        body()
        usleep(40_000)
        TISSelectInputSource(current)
    }

    /// Short label for the current input source: "EN" for a keyboard layout, "IME" for an input method.
    static func shortLabel() -> String {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "EN" }
        let type = property(current, kTISPropertyInputSourceType) ?? ""
        return type == (kTISTypeKeyboardLayout as String) ? "EN" : "IME"
    }
}
