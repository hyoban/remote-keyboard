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

    // MARK: 菜单栏

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// 已连接并配对时显示实心图标，其他状态显示空心图标。
    private func updateIcon() {
        let ready: Bool
        if case .connected = telegram.status { ready = true } else { ready = false }
        statusItem?.button?.image = NSImage(systemSymbolName: ready ? "paperplane.fill" : "paperplane",
                                            accessibilityDescription: "Telegram 输入")
    }

    /// 菜单栏 App 默认没有“编辑”菜单，加上它，设置对话框里才能用 ⌘V 粘贴 token。
    private func setUpEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let statusText: String
        switch telegram.status {
        case .notConfigured: statusText = telegram.enabled ? "未设置 bot token" : "已关闭"
        case .connecting: statusText = "连接中…"
        case .waitingForPairing: statusText = "等待配对：给 @\(telegram.botUsername ?? "bot") 发送 \(telegram.pairingCode)"
        case .connected: statusText = "已连接 @\(telegram.botUsername ?? "bot")"
        case .error(let message): statusText = "错误：\(message)"
        }
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(item(telegram.isConfigured ? "更换 bot token…" : "设置 bot token…", #selector(configure)))
        if telegram.botUsername != nil {
            menu.addItem(item("打开机器人对话", #selector(openBotChat)))
        }
        if case .waitingForPairing = telegram.status {
            menu.addItem(item("拷贝配对码", #selector(copyPairingCode)))
        }
        if telegram.isPaired {
            menu.addItem(item("解除配对", #selector(unpair)))
        }
        let enabled = item("启用", #selector(toggleEnabled))
        enabled.state = telegram.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        let login = item("开机自动启动", #selector(toggleLaunchAtLogin))
        login.state = AppSupport.launchAtLogin ? .on : .off
        menu.addItem(login)

        if KeySender.hasPermission {
            let ok = NSMenuItem(title: "辅助功能权限：已授权", action: nil, keyEquivalent: "")
            ok.isEnabled = false
            menu.addItem(ok)
        } else {
            menu.addItem(item("辅助功能权限：未授权，点击去设置…", #selector(openAccessibilitySettings)))
        }

        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func configure() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "设置 Telegram 机器人"
        alert.informativeText = """
        1. 在 Telegram 里找 @BotFather，发送 /newbot 创建一个机器人
        2. 把它回复的 token 粘贴到下面
        3. 保存后，把菜单里显示的 6 位配对码发给你的机器人
        """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = telegram.isConfigured ? "已设置，粘贴新的 token 可替换" : "123456789:ABCdef..."
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
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
