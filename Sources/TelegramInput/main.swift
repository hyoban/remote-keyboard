import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let telegram = TelegramBot()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpEditMenu()
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        telegram.onStatusChange = { [weak self] in self?.updateIcon() }
        telegram.start()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Filled icon when connected and paired, outlined otherwise.
    private func updateIcon() {
        let ready: Bool
        if case .connected = telegram.status { ready = true } else { ready = false }
        statusItem?.button?.image = NSImage(systemSymbolName: ready ? "paperplane.fill" : "paperplane",
                                            accessibilityDescription: "Telegram Input")
    }

    /// Menu bar apps have no Edit menu by default; without it ⌘V can't paste the token into the dialog.
    private func setUpEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusText: String
        switch telegram.status {
        case .notConfigured: statusText = telegram.enabled ? "Bot token not set" : "Off"
        case .connecting: statusText = "Connecting…"
        case .waitingForPairing: statusText = "Waiting to pair: send \(telegram.pairingCode) to @\(telegram.botUsername ?? "bot")"
        case .connected: statusText = "Connected as @\(telegram.botUsername ?? "bot")"
        case .error(let message): statusText = "Error: \(message)"
        }
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(item(telegram.isConfigured ? "Change Bot Token…" : "Set Bot Token…", #selector(configure)))
        if telegram.botUsername != nil {
            menu.addItem(item("Open Bot Chat", #selector(openBotChat)))
        }
        if case .waitingForPairing = telegram.status {
            menu.addItem(item("Copy Pairing Code", #selector(copyPairingCode)))
        }
        if telegram.isPaired {
            menu.addItem(item("Unpair", #selector(unpair)))
        }
        let enabled = item("Enabled", #selector(toggleEnabled))
        enabled.state = telegram.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = AppSupport.launchAtLogin ? .on : .off
        menu.addItem(login)

        if KeySender.hasPermission {
            let ok = NSMenuItem(title: "Accessibility Access: Granted", action: nil, keyEquivalent: "")
            ok.isEnabled = false
            menu.addItem(ok)
        } else {
            menu.addItem(item("Accessibility Access: Not Granted, Open Settings…", #selector(openAccessibilitySettings)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func configure() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set Up Telegram Bot"
        alert.informativeText = """
        1. In Telegram, message @BotFather and send /newbot to create a bot
        2. Paste the token it replies with below
        3. After saving, send the 6-digit pairing code from the menu to your bot
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = telegram.isConfigured ? "Already set; paste a new token to replace it" : "123456789:ABCdef..."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        telegram.setToken(token)
    }

    @objc private func openBotChat() {
        guard let name = telegram.botUsername, let url = URL(string: "https://t.me/\(name)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(telegram.pairingCode, forType: .string)
    }

    @objc private func unpair() {
        telegram.unpair()
    }

    @objc private func toggleEnabled() {
        telegram.enabled.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        AppSupport.toggleLaunchAtLogin()
    }

    @objc private func openAccessibilitySettings() {
        AppSupport.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
