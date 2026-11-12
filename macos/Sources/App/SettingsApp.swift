// 设置窗口：同一个安装包，另起一个进程（WowType --settings [页面]），像 Linux 上单独的 wowtype-config。
//
// 不放在输入法进程里开窗口：输入法自己进程里的输入框用不了自己（加自定义词要打中文），
// 窗口出了问题也不会带倒输入法。设置窗口只写 wowtype.conf / custom.tsv，输入法下一次按键时自己重新读。

import AppKit
import SwiftUI

enum SettingsApp {
    /// 设置窗口已经开着时，输入法让它切到某一页、到前面来
    static let showNotification = Notification.Name("io.github.gloridust.inputmethod.WowType.ShowSettings")

    /// 输入法菜单里调：打开设置窗口；已经开着就切过去。
    static func open(page: SettingsPage? = nil) {
        let bundleID = Bundle.main.bundleIdentifier ?? Installer.bundleID
        let me = ProcessInfo.processInfo.processIdentifier
        // 设置窗口进程是 .regular（在程序坞里），输入法进程是 .accessory：别把另一份输入法当成设置窗口
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != me && !$0.isTerminated && $0.activationPolicy == .regular }) {
            DistributedNotificationCenter.default().postNotificationName(
                showNotification, object: page?.rawValue ?? "", userInfo: nil, deliverImmediately: true)
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        config.arguments = ["--settings"] + (page.map { [$0.rawValue] } ?? [])
        if let dir = ProcessInfo.processInfo.environment["WOWTYPE_DATA_DIR"], !dir.isEmpty {
            config.environment = ["WOWTYPE_DATA_DIR": dir]
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if let error {
                NSLog("WowType: 打开设置窗口失败 %@", error.localizedDescription)
            }
        }
    }

    /// `WowType --settings [general|input|emoji|words]`：设置窗口进程，关掉窗口就退出。
    static func run(page: String?) -> Never {
        let app = NSApplication.shared
        let delegate = SettingsAppDelegate(page: page.flatMap(SettingsPage.init(rawValue:)) ?? .general)
        app.delegate = delegate
        // 安装包是 LSUIElement（输入法不在程序坞里），设置窗口要在程序坞里、有菜单栏
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
        exit(0)
    }
}

final class SettingsAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: SettingsModel
    private var window: NSWindow!

    init(page: SettingsPage) {
        model = SettingsModel(page: page)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "WowType 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 460)
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.delegate = self
        if !window.setFrameUsingName("WowTypeSettings") {
            window.center()
        }
        window.setFrameAutosaveName("WowTypeSettings")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showRequested(_:)), name: SettingsApp.showNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.save()
    }

    func windowWillClose(_ notification: Notification) {
        model.save()
    }

    @objc private func showRequested(_ notification: Notification) {
        if let name = notification.object as? String, let page = SettingsPage(rawValue: name) {
            model.page = page
        }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func didBecomeActive(_ notification: Notification) {
        model.reload()
    }

    // MARK: 菜单

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "WowType")
        add(app, "关于 WowType", #selector(showAbout))
        app.addItem(.separator())
        add(app, "恢复默认设置…", #selector(resetToDefaults))
        app.addItem(.separator())
        add(app, "隐藏 WowType", #selector(NSApplication.hide(_:)), "h", target: nil)
        add(app, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: nil)
        add(app, "全部显示", #selector(NSApplication.unhideAllApplications(_:)), target: nil)
        app.addItem(.separator())
        add(app, "退出 WowType", #selector(NSApplication.terminate(_:)), "q", target: nil)

        let file = submenu(main, "文件")
        add(file, "用文本编辑打开设置文件", #selector(openConfigFile))
        add(file, "用文本编辑打开自定义词", #selector(openCustomWordsFile))
        add(file, "打开数据目录", #selector(openDataFolder))
        file.addItem(.separator())
        add(file, "关闭", #selector(NSWindow.performClose(_:)), "w", target: nil)

        // 输入框里的拷贝、粘贴、全选靠这个菜单的快捷键
        let edit = submenu(main, "编辑")
        add(edit, "撤销", Selector(("undo:")), "z", target: nil)
        add(edit, "重做", Selector(("redo:")), "z", [.command, .shift], target: nil)
        edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), "x", target: nil)
        add(edit, "拷贝", #selector(NSText.copy(_:)), "c", target: nil)
        add(edit, "粘贴", #selector(NSText.paste(_:)), "v", target: nil)
        add(edit, "全选", #selector(NSText.selectAll(_:)), "a", target: nil)

        let windowMenu = submenu(main, "窗口")
        add(windowMenu, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
        add(windowMenu, "缩放", #selector(NSWindow.performZoom(_:)), target: nil)
        NSApp.windowsMenu = windowMenu
        return main
    }

    private func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                     _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // target 是 nil 的走响应链（窗口、输入框）；其余的是这里的方法
        item.target = target ?? (responds(to: action) ? self : nil)
        menu.addItem(item)
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "好用的拼音输入法：整句、简拼、按错键纠正。\n代码按 MIT 或 Apache-2.0 双许可证发布。\n词库数据来自 rime-ice（GPL-3.0）。",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "WowType",
            .applicationVersion: appVersion,
            .version: "",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "恢复默认设置？"
        alert.informativeText = "排列方向、模糊音、双拼等回到默认值。自定义词和词库不受影响。"
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.model.resetToDefaults()
            }
        }
    }

    @objc private func openConfigFile() {
        model.save()
        AppState.shared.openConfigFile()
    }

    @objc private func openCustomWordsFile() {
        AppState.shared.openCustomWordsFile()
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(model.supportDir)
    }
}
