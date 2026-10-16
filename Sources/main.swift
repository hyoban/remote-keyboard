import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: KeyboardController!
    private var autoHide: AutoHide!
    private let remoteDetector = RemoteDetector()
    private let telegram = TelegramBot()
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = KeyboardController()
        controller.keyboardView.onPermissionTap = { [weak self] in self?.openAccessibilitySettings() }
        autoHide = AutoHide(controller: controller)
        controller.keyboardView.onActivity = { [weak self] in self?.autoHide.noteActivity() }
        controller.show()
        setUpStatusItem()
        setUpEditMenu()
        telegram.start()

        updatePermission(prompt: true)
        remoteDetector.onChange = { [weak self] remote in
            guard let self, self.remoteOnly else { return }
            remote ? self.controller.show() : self.controller.hide()
        }
        remoteDetector.onClick = { [weak self] point in self?.autoHide.noteClick(at: point) }
        remoteDetector.start()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updatePermission(prompt: false)
        }

        // 输入法变化时刷新“中/EN”键。
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.controller.keyboardView.needsDisplay = true }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return false
    }

    /// 仅在远程控制时显示：远程输入时显示键盘，本地真实键鼠操作时隐藏。
    private var remoteOnly: Bool {
        get { UserDefaults.standard.object(forKey: "remoteOnly") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "remoteOnly") }
    }

    private func updatePermission(prompt: Bool) {
        let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        controller.keyboardView.hasPermission = granted
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: 菜单栏

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "屏幕键盘")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
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

    private func telegramMenu() -> NSMenu {
        let menu = NSMenu()
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

        menu.addItem(item(telegram.isConfigured ? "更换 bot token…" : "设置 bot token…", #selector(configureTelegram)))
        if telegram.botUsername != nil {
            menu.addItem(item("打开机器人对话", #selector(openBotChat)))
        }
        if case .waitingForPairing = telegram.status {
            menu.addItem(item("拷贝配对码", #selector(copyPairingCode)))
        }
        if telegram.isPaired {
            menu.addItem(item("解除配对", #selector(unpairTelegram)))
        }
        let enabled = item("启用", #selector(toggleTelegram))
        enabled.state = telegram.enabled ? .on : .off
        menu.addItem(enabled)
        return menu
    }

    @objc private func configureTelegram() {
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

    @objc private func unpairTelegram() {
        telegram.unpair()
    }

    @objc private func toggleTelegram() {
        telegram.enabled.toggle()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item(controller.isVisible ? "隐藏键盘" : "显示键盘", #selector(toggleVisible)))
        menu.addItem(item(controller.collapsed ? "展开键盘" : "收起成小圆点", #selector(toggleCollapsed)))
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for (title, fraction) in [("小（屏宽 50%）", 0.5), ("中（屏宽 70%）", 0.7), ("大（屏宽 85%）", 0.85), ("全宽", 1.0)] {
            let i = item(title, #selector(setSize(_:)))
            i.representedObject = fraction
            sizeMenu.addItem(i)
        }
        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let opacityMenu = NSMenu()
        for value in [1.0, 0.85, 0.7, 0.55] {
            let i = item("\(Int(value * 100))%", #selector(setOpacity(_:)))
            i.representedObject = value
            i.state = abs(Double(controller.opacity) - value) < 0.01 ? .on : .off
            opacityMenu.addItem(i)
        }
        let opacityItem = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(item("重置位置", #selector(resetPosition)))
        menu.addItem(.separator())

        let remote = item("仅在远程控制时显示", #selector(toggleRemoteOnly))
        remote.state = remoteOnly ? .on : .off
        menu.addItem(remote)

        let follow = item("进入输入框时展开，离开时收起", #selector(toggleFollowFocus))
        follow.state = autoHide.followFocus ? .on : .off
        menu.addItem(follow)

        let idleMenu = NSMenu()
        for seconds in [0, 15, 30, 60] {
            let i = item(seconds == 0 ? "从不" : "\(seconds) 秒", #selector(setIdle(_:)))
            i.representedObject = seconds
            i.state = autoHide.idleSeconds == seconds ? .on : .off
            idleMenu.addItem(i)
        }
        let idleItem = NSMenuItem(title: "闲置后收起", action: nil, keyEquivalent: "")
        idleItem.submenu = idleMenu
        menu.addItem(idleItem)
        menu.addItem(.separator())

        let tgItem = NSMenuItem(title: "Telegram 机器人", action: nil, keyEquivalent: "")
        tgItem.submenu = telegramMenu()
        menu.addItem(tgItem)
        menu.addItem(.separator())

        let login = item("开机自动启动", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
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

    @objc private func toggleVisible() {
        controller.isVisible ? controller.hide() : controller.show()
    }

    @objc private func toggleCollapsed() {
        controller.show()
        controller.collapsed ? controller.expand() : controller.collapse()
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let fraction = sender.representedObject as? Double else { return }
        controller.show()
        controller.setWidth(fraction: CGFloat(fraction))
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        controller.opacity = CGFloat(value)
    }

    @objc private func resetPosition() {
        controller.show()
        controller.resetPosition()
    }

    @objc private func toggleRemoteOnly() {
        remoteOnly.toggle()
        if remoteOnly, remoteDetector.isRemote == false { controller.hide() }
        if !remoteOnly { controller.show() }
    }

    @objc private func toggleFollowFocus() {
        autoHide.followFocus.toggle()
    }

    @objc private func setIdle(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        autoHide.idleSeconds = seconds
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置开机启动失败"
            alert.informativeText = "\(error.localizedDescription)\n请先把 App 拖到“应用程序”文件夹再试。"
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// 把键盘的默认、Shift、fn 三种状态渲染成 PNG（用于 README 截图和检查布局），不显示任何窗口。
func renderSnapshots(to dir: String) {
    let url = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let width: CGFloat = 1200
    for (name, modifier) in [("keyboard", nil), ("keyboard-shift", Modifier.shift), ("keyboard-fn", .fn)] {
        let view = KeyboardView(frame: NSRect(x: 0, y: 0, width: width, height: width * KeyboardController.aspect))
        if let modifier { view.mods.tap(modifier) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("\(name).png"))
    }
    print("截图已保存到 \(dir)")
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    renderSnapshots(to: args[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
