// WowType 的 macOS 输入法进程。
//
//   WowType.app/Contents/MacOS/WowType              输入法服务（系统按需启动）
//   … --register | --enable | --select | --disable  向系统登记 / 打开 / 切换 / 关闭（install.sh 用）
//   … --selftest                                    载入安装包里的词库打一句话，CI 用来检查链接和资源
//   … --version

import AppKit
import InputMethodKit

/// 自检里用的假输入框。
final class SelfTestClient: TextClient {
    var committed = ""
    var page: CandidatePage?
    func insertText(_ text: String) { committed += text }
    func setMarkedText(_ text: String, cursor: Int) {}
    func showCandidates(_ page: CandidatePage?) { self.page = page }
    var previousCharacter: UInt32 { committed.unicodeScalars.last?.value ?? 0 }
}

func selfTest() -> Bool {
    print("WowType \(appVersion)，核心接口版本 \(Engine.abiVersion)")
    print("资源目录 \(AppState.shared.resourceDir.path)")
    print("数据目录 \(AppState.shared.supportDir.path)")
    for name in ["lexicon.tsv", "english.txt", "words.lm"] {
        print("  \(name)：\(AppState.shared.resource(name) == nil ? "没有" : "有")")
    }
    let start = Date()
    guard let engine = AppState.shared.makeEngine() else {
        print("FAIL 载入词库")
        return false
    }
    print(String(format: "词库载入 %.1f 秒", Date().timeIntervalSince(start)))
    let client = SelfTestClient()
    let composer = Composer(engine: engine, client: client)
    for c in "nihao" {
        _ = composer.handle(.char(c))
    }
    let first = client.page?.texts.first ?? ""
    _ = composer.handle(.char(" "))
    print("nihao → 第一个候选「\(first)」，上屏「\(client.committed)」")
    return client.committed == "你好"
}

let arguments = CommandLine.arguments
if arguments.count > 1 {
    let ok: Bool
    switch arguments[1] {
    case "--register": ok = Installer.register()
    case "--enable": ok = Installer.enable()
    case "--select": ok = Installer.select()
    case "--disable": ok = Installer.disable()
    case "--selftest": ok = selfTest()
    case "--version":
        print(appVersion)
        ok = true
    default:
        print("用法：WowType [--register | --enable | --select | --disable | --selftest | --version]")
        ok = false
    }
    exit(ok ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.save()
    }
}

guard let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
      let bundleID = Bundle.main.bundleIdentifier
else {
    NSLog("WowType: Info.plist 里缺 InputMethodConnectionName 或 CFBundleIdentifier")
    exit(1)
}
let server = IMKServer(name: connection, bundleIdentifier: bundleID)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
AppState.shared.loadEngineInBackground()
withExtendedLifetime(server) {
    app.run()
}
