// 输入法菜单（菜单栏输入法图标下）：设置、编辑自定义词、打开数据文件夹、关于。
import AppKit

@MainActor
enum AppMenu {
    static func make(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: "WowType")
        menu.addItem(item("设置…", #selector(MenuActions.openSettings(_:))))
        menu.addItem(item("编辑自定义词…", #selector(MenuActions.editCustomWords(_:))))
        menu.addItem(item("打开数据文件夹", #selector(MenuActions.openDataFolder(_:))))
        menu.addItem(.separator())
        menu.addItem(item("关于 WowType", #selector(MenuActions.about(_:))))
        return menu
    }

    private static func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = MenuActions.shared
        return item
    }
}

/// IMK 的菜单项可以指向任意对象；放在一个常驻对象上，不依赖哪个控制器还活着。
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func editCustomWords(_ sender: Any?) {
        let paths = IMEApp.shared.paths
        let url = paths.custom
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
            let header = "# 编码<TAB>词[<TAB>频次]，一行一个，保存后马上生效\n"
            try? Data(header.utf8).write(to: url, options: .atomic)
        }
        NSWorkspace.shared.open(url)
    }

    @objc func openDataFolder(_ sender: Any?) {
        let dir = IMEApp.shared.paths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc func about(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "拼音输入法。词库来自 rime-ice，见 Resources/LICENSE 和 SOURCE.txt。"),
        ])
    }
}
