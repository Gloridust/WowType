// 从 DMG 或下载目录双击打开时：一个小窗口，「安装」「卸载」两个按钮。
import AppKit
import SwiftUI

enum InstallerWindow {
    static func runApp() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = InstallerAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class InstallerAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "安装 WowType"
        window.contentView = NSHostingView(rootView: InstallerView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct InstallerView: View {
    @State private var message = "装到「~/Library/Input Methods」，只给当前用户，不用管理员密码。"
    @State private var failed = false
    @State private var working = false

    var body: some View {
        VStack(spacing: 14) {
            Text("WowType 输入法").font(.title2)
            Text(message)
                .foregroundStyle(failed ? Color.red : Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("卸载") { run(install: false) }.disabled(working)
                Button("安装") { run(install: true) }.keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func run(install: Bool) {
        working = true
        defer { working = false }
        do {
            if install {
                try Installer.install()
                message = "装好了。如果系统设置弹出提示，请允许 WowType；正在运行的程序要是看不到它，退出再打开一次。"
            } else {
                try Installer.uninstall()
                message = "已卸载。设置和学到的词留在「~/Library/Application Support/WowType」。"
            }
            failed = false
        } catch {
            message = "失败：\(error)"
            failed = true
        }
    }
}
