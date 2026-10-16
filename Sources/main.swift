import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: KeyboardController!
    private var autoHide: AutoHide!
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = KeyboardController()
        controller.keyboardView.onPermissionTap = { [weak self] in self?.openAccessibilitySettings() }
        autoHide = AutoHide(controller: controller)
        controller.keyboardView.onActivity = { [weak self] in self?.autoHide.noteActivity() }
        controller.show()
        setUpStatusItem()

        updatePermission(prompt: true)
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

    private func updatePermission(prompt: Bool) {
        var granted = KeySender.hasPermission
        if !granted, prompt { granted = CGRequestPostEventAccess() }
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item(controller.isVisible ? "隐藏键盘" : "显示键盘", #selector(toggleVisible)))
        menu.addItem(item(controller.collapsed ? "展开键盘" : "收起成小圆点", #selector(toggleCollapsed)))
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for (title, fraction) in [("小（屏宽 40%）", 0.4), ("中（屏宽 60%）", 0.6), ("大（屏宽 80%）", 0.8), ("全宽", 1.0)] {
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

/// 把四个面板渲染成 PNG（用于 README 截图和检查布局），不显示任何窗口。
func renderSnapshots(to dir: String) {
    let url = URL(fileURLWithPath: dir)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let width: CGFloat = 1000
    let view = KeyboardView(frame: NSRect(x: 0, y: 0, width: width, height: width * KeyboardController.aspect))
    for (name, panel) in [("letters", PanelID.letters), ("symbols", .symbols), ("symbols2", .symbols2), ("fn", .fn)] {
        view.panel = panel
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
