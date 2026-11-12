// 菜单「设置互译 API Key…」：一个小窗口，密码框里填 Key，存到数据目录的 translate.key（0600）。
// Key 不写进 wowtype.conf（那个文件谁都能读），也不进日志。
//
// 不用 NSAlert.runModal：模态循环里输入法可能收不到别的应用的按键，窗口开着时别处打字会卡住。
// 密码框里系统开着安全输入、只用英文键盘，不会再进到 WowType 自己。

import AppKit

final class TranslateKeyWindow: NSObject, NSWindowDelegate {
    static let shared = TranslateKeyWindow()

    private var window: NSWindow?
    private let field = NSSecureTextField()
    private let status = NSTextField(labelWithString: "")

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        field.stringValue = ""
        let path = AppState.shared.translateKeyPath
        status.stringValue = TranslateKeyFile.read(path).isEmpty ? "现在：没设置" : "现在：已设置（不显示）"
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    private func makeWindow() -> NSWindow {
        let width: CGFloat = 440
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 196),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "互译 API Key"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 196))
        window.contentView = content

        let path = (AppState.shared.translateKeyPath as NSString).abbreviatingWithTildeInPath
        let note = NSTextField(wrappingLabelWithString:
            "翻译服务（wowtype.conf 里的 TranslateBaseUrl）的 API Key。存在 \(path)，只有你自己能读，"
            + "不写进 wowtype.conf。本机的服务（Ollama 等）、本地模型不用填。留空保存就删掉。")
        note.frame = NSRect(x: 20, y: 110, width: width - 40, height: 66)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        content.addSubview(note)

        field.frame = NSRect(x: 20, y: 78, width: width - 40, height: 24)
        field.placeholderString = "sk-…"
        content.addSubview(field)

        status.frame = NSRect(x: 20, y: 52, width: width - 40, height: 18)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        content.addSubview(status)

        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: width - 20 - 88, y: 14, width: 88, height: 30)
        content.addSubview(save)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: width - 20 - 88 * 2 - 8, y: 14, width: 88, height: 30)
        content.addSubview(cancel)
        return window
    }

    @objc private func save() {
        let state = AppState.shared
        try? FileManager.default.createDirectory(at: state.supportDir, withIntermediateDirectories: true)
        if TranslateKeyFile.write(field.stringValue, to: state.translateKeyPath) {
            field.stringValue = ""
            window?.orderOut(nil)
        } else {
            status.stringValue = "保存失败：写不了 \(state.translateKeyPath)"
        }
    }

    @objc private func cancel() {
        field.stringValue = ""
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        field.stringValue = ""
    }
}
