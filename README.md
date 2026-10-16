# Remote Keyboard

When you control a Mac from a car head unit (or any other device) through a remote desktop app like UU Remote, the device's own on-screen keyboard covers most of the remote view, and many head units can't pair a Bluetooth keyboard. This repository contains two independent Mac menu bar apps; install either one or both:

| App | Best for | How it works |
|---|---|---|
| **Remote Keyboard** (`RemoteKeyboard.app`) | Short edits, shortcuts, terminals | A keyboard shown on the Mac's screen that you tap through the remote view |
| **Telegram Input** (`TelegramInput.app`) | Long sentences, phone dictation | Message a Telegram bot from your phone and the text is typed on the Mac |

Each app has its own menu bar icon, Accessibility permission and launch-at-login setting; neither depends on the other.

## Remote Keyboard

Puts a keyboard on the Mac's screen so you can type by tapping keys in the remote view.

![68-key layout](docs/keyboard.png)

- **Never steals focus**: the keyboard is a floating panel that never becomes the key window, so the app you're typing into keeps focus.
- **Works with input methods**: it sends real key events, so the Mac's own input methods (Pinyin and others) handle composition and you pick candidates on screen. The `EN`/`IME` key switches the Mac's input source directly, independent of your switching shortcut.
- **68-key layout**: the common 65% mechanical keyboard layout with Mac modifiers; number row, arrows and navigation keys all on one panel.
- **Large, adjustable keys**: drag to move, drag the ⤡ corner to resize, change opacity, or tap — to collapse it into a small bubble.
- **No phone, network or pairing**: all it needs is a remote desktop app that shows the Mac's screen and sends clicks.
- Pure Swift with no third-party dependencies.

## Building and installing

```bash
./build.sh
```

This builds both `build/RemoteKeyboard.app` and `build/TelegramInput.app`. To build only one, run `./build.sh keyboard` or `./build.sh telegram`.

```bash
open build/RemoteKeyboard.app
```

```bash
open build/TelegramInput.app
```

To launch at login, move the app to the Applications folder first, then enable **Launch at Login** from its menu bar icon.

### Accessibility permission

Both apps need Accessibility access to type on the Mac, and **each must be granted separately**. On first launch macOS asks for it: open **System Settings → Privacy & Security → Accessibility** and turn on the app. While Remote Keyboard lacks access, a notice at the top of the keyboard links to that settings page.

> `build.sh` signs the apps with a bundle-id requirement, so rebuilding keeps the permission. If you granted access to an earlier build, remove the old entry with "−" and add the app again; turning the switch on is not enough.
>
> Logs help with troubleshooting: `/usr/bin/log stream --predicate 'subsystem == "dev.hyoban.remote-keyboard"'`
> Every key press is logged with its hold time and finger movement (category `keyboard`), which is useful for tracking down accidental presses.

## Usage

```
esc 1 2 3 4 5 6 7 8 9 0 - =  ⌫⌫   `
tab  q w e r t y u i o p [ ] \    ⌦
caps  a s d f g h j k l ; ' ⏎⏎⏎   PgUp
⇧⇧⇧   z x c v b n m , . / ⇧⇧  ↑  PgDn
⌃  ⌥  ⌘  ━━━━ space ━━━━ ⌘ fn IME ← ↓ →
```

- **Symbols**: number and symbol keys show both legends like a physical keycap; with ⇧ active you get the upper one.
- **fn layer**: the number row becomes F1–F12 and PgUp/PgDn become Home/End.

![fn layer](docs/keyboard-fn.png)

- **caps** locks Shift. It does not send a real Caps Lock, which macOS often uses to switch input sources.
- **EN/IME**: the key next to the arrows switches the Mac's input source and shows whether a keyboard layout (`EN`) or an input method (`IME`) is active.
- **Modifiers** ⇧ ⌘ ⌥ ⌃ fn: one tap applies to the next key, a quick double tap locks it (a bar appears on the key), and another tap releases it. They combine into any shortcut, e.g. ⌘ → ⇧ → 4 takes a screenshot.
- **Commit on release**: pressing only highlights a key and releasing sends it, so a near miss can slide to the right key before letting go. Moving more than 1.5 key widths between press and release counts as a swipe and types nothing. Gaps between keys belong to the nearest key.
- **Modifiers expire**: a one-tap ⌘ ⌥ ⌃ fn that isn't used within 5 seconds is cancelled, so a stray tap doesn't turn the next key into a shortcut.
- **Auto-repeat**: ⌫, ⌦ and the arrows repeat after being held for 0.6 seconds.
- **Show only during remote control** (on by default): the app listens to input events read-only and uses each event's source process to tell remote from local input. Taps through UU Remote (as well as ToDesk, Sunlogin, AnyDesk, TeamViewer, RustDesk, Parsec and Screen Sharing) show the keyboard; using the Mac's real mouse or keyboard hides it. It only acts when the source changes. Scroll events are ignored to avoid conflicts with tools like Mac Mouse Fix. macOS may ask for Input Monitoring access the first time.
- **Automatic behavior** (in the menu bar):
  - **Expand in text inputs, collapse elsewhere** (on by default): watches the frontmost app's focus through the Accessibility API, expanding as soon as focus enters a text input and collapsing 0.6 seconds after it leaves (to filter out flicker). It only acts on focus changes, so manual expanding or collapsing isn't immediately undone. Within one app, focus moving from an input to a container such as `AXGroup` without a click in the surrounding second (common when Electron apps re-render) doesn't count as leaving; a click outside the keyboard does. To see inputs in Electron apps like VS Code and Slack and in Chrome, it turns on accessibility support in those apps (Chrome needs `AXEnhancedUserInterface`, which can affect animations in some window managers).
  - **Move away from text input** (on by default): when the keyboard covers the focused input, it animates to the other half of the screen (top if it was at the bottom, and vice versa) and returns once it no longer overlaps or focus leaves the input. Short inputs are judged by their whole frame; tall ones like editors and documents only by the lines around the caret. Caret moves and line wraps trigger a re-check. The temporary position is never saved as the keyboard's position; only dragging it yourself changes that.
  - **Collapse when idle**: collapses to the bubble after 15, 30 or 60 seconds without taps. Off by default.
- **Menu bar icon**: show/hide, collapse/expand, size (50%/70%/85%/full screen width), opacity, reset position, show only during remote control, the automatic behaviors above, launch at login and permission status.

## Telegram Input

For long text or phone dictation, send the text to a Telegram bot and it's typed at the Mac's cursor. The Mac only makes outgoing requests to Telegram's servers, so there are no ports to open and no VPN to set up. It's a standalone app and doesn't need Remote Keyboard running.

1. In Telegram, message [@BotFather](https://t.me/BotFather) and send `/newbot` to create a bot and get its token.
2. Click the paper plane icon in the menu bar → **Set Bot Token…** and paste the token. It's stored in the Keychain.
3. The menu shows a 6-digit pairing code; send it to your bot. Once paired, the bot only responds to your account.

Usage:
- **Text** is typed at the cursor. Single lines are typed directly; multi-line text is pasted so newlines don't act as Return and send early.
- **Buttons** below the chat field send ⏎ ⌫ Esc Tab, the arrows, ⌘C ⌘V ⌘Z ⌘A ⌘Tab ⌘W ⌃C and 🌐 Input (switch input source).
- **Auto Return** presses Return after each message, handy for chats and terminals.
- The bot reacts with 👍 once the text is typed. Messages older than 2 minutes are ignored, so reconnecting doesn't suddenly type a backlog.
- The menu bar icon turns solid once connected and paired.
- Bot chats aren't end-to-end encrypted, so don't use it for passwords.
- Logs help with troubleshooting: `/usr/bin/log stream --predicate 'subsystem == "dev.hyoban.telegram-input"'`

## Screenshots

The images in `docs/` are rendered with this command, which doesn't open any window:

```bash
build/RemoteKeyboard.app/Contents/MacOS/RemoteKeyboard --snapshot docs
```
