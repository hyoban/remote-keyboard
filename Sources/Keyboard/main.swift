import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: KeyboardController!
    private var autoHide: AutoHide!
    private let remoteDetector = RemoteDetector()
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
        remoteDetector.onChange = { [weak self] remote in
            guard let self, self.remoteOnly else { return }
            remote ? self.controller.show() : self.controller.hide()
        }
        remoteDetector.onClick = { [weak self] point in self?.autoHide.noteClick(at: point) }
        remoteDetector.start()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updatePermission(prompt: false)
        }

        // Refresh the input source key when the input source changes.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.controller.keyboardView.needsDisplay = true }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.show()
        return false
    }

    /// Show only during remote control: show on remote input, hide on local hardware input.
    private var remoteOnly: Bool {
        get { UserDefaults.standard.object(forKey: "remoteOnly") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "remoteOnly") }
    }

    private func updatePermission(prompt: Bool) {
        let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        controller.keyboardView.hasPermission = granted
    }

    @objc private func openAccessibilitySettings() {
        AppSupport.openAccessibilitySettings()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Remote Keyboard")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item(controller.isVisible ? "Hide Keyboard" : "Show Keyboard", #selector(toggleVisible)))
        menu.addItem(item(controller.collapsed ? "Expand Keyboard" : "Collapse to Bubble", #selector(toggleCollapsed)))
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for (title, fraction) in [("Small (50% of screen width)", 0.5), ("Medium (70%)", 0.7), ("Large (85%)", 0.85), ("Full Width", 1.0)] {
            let i = item(title, #selector(setSize(_:)))
            i.representedObject = fraction
            sizeMenu.addItem(i)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let opacityMenu = NSMenu()
        for value in [1.0, 0.85, 0.7, 0.55] {
            let i = item("\(Int(value * 100))%", #selector(setOpacity(_:)))
            i.representedObject = value
            i.state = abs(Double(controller.opacity) - value) < 0.01 ? .on : .off
            opacityMenu.addItem(i)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(item("Reset Position", #selector(resetPosition)))
        menu.addItem(.separator())

        let remote = item("Show Only During Remote Control", #selector(toggleRemoteOnly))
        remote.state = remoteOnly ? .on : .off
        menu.addItem(remote)

        let follow = item("Expand in Text Inputs, Collapse Elsewhere", #selector(toggleFollowFocus))
        follow.state = autoHide.followFocus ? .on : .off
        menu.addItem(follow)

        let avoid = item("Move Away from Text Input", #selector(toggleAvoidInput))
        avoid.state = autoHide.avoidInput ? .on : .off
        menu.addItem(avoid)

        let idleMenu = NSMenu()
        for seconds in [0, 15, 30, 60] {
            let i = item(seconds == 0 ? "Never" : "After \(seconds) Seconds", #selector(setIdle(_:)))
            i.representedObject = seconds
            i.state = autoHide.idleSeconds == seconds ? .on : .off
            idleMenu.addItem(i)
        }
        let idleItem = NSMenuItem(title: "Collapse When Idle", action: nil, keyEquivalent: "")
        idleItem.submenu = idleMenu
        menu.addItem(idleItem)
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

    @objc private func toggleAvoidInput() {
        autoHide.avoidInput.toggle()
    }

    @objc private func toggleFollowFocus() {
        autoHide.followFocus.toggle()
    }

    @objc private func setIdle(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        autoHide.idleSeconds = seconds
    }

    @objc private func toggleLaunchAtLogin() {
        AppSupport.toggleLaunchAtLogin()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Renders the default, Shift and fn states to PNGs (for README screenshots and layout checks) without showing a window.
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
    print("Saved screenshots to \(dir)")
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
