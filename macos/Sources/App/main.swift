// WowType 的 macOS 输入法进程。
//
//   WowType.app/Contents/MacOS/WowType              输入法服务（系统按需启动）
//   … --register | --enable | --select | --disable  向系统登记 / 打开 / 切换 / 关闭（install.sh 用）
//   … --selftest                                    载入安装包里的词库打一句话，CI 用来检查链接和资源
//   … --settings [general|input|emoji|words]        设置窗口（另一个进程，输入法菜单里「设置…」开的就是它）
//   … --version

import AppKit
import CWowtype
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
    for name in ["lexicon.tsv", "english.txt", "words.lm", "s2t.tsv"] {
        print("  \(name)：\(AppState.shared.resource(name) == nil ? "没有" : "有")")
    }
    let start = Date()
    guard let engine = AppState.shared.makeConfiguredEngine() else {
        print("FAIL 载入词库")
        return false
    }
    print(String(format: "词库载入 %.1f 秒", Date().timeIntervalSince(start)))
    let config = AppState.shared.config
    print("设置 \(AppState.shared.configPath)：\(config == WowtypeConfig() ? "默认" : "改过")，双拼 \(config.shuangpin ? config.shuangpinScheme : "关")")
    // 下面照默认设置打一句（设置里开了双拼 nihao 就不是你好了）
    engine.apply(WowtypeConfig())
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
    case "--settings": SettingsApp.run(page: arguments.count > 2 ? arguments[2] : nil)
    case "--version":
        print(appVersion)
        ok = true
    default:
        print("用法：WowType [--register | --enable | --select | --disable | --selftest | --settings [页面] | --version]")
        ok = false
    }
    exit(ok ? 0 : 1)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.save()
        AppState.shared.shutdownTranslator()
    }
}

// 被 kill（install.sh 换新版本、注销）时也存学习数据，停掉本地翻译模型的 llama-server（它是子进程，
// 不停就一直占着 1.5 GB 内存）
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    AppState.shared.save()
    AppState.shared.shutdownTranslator()
    exit(0)
}
terminationSource.resume()

// 核心的接口主版本要和编译时的头文件一样（docs/ABI.md）：静态链接时一定对得上，改成动态库以后装错了版本就别跑
if Int(wowtype_abi_version()) / 1000 != Int(WOWTYPE_ABI_VERSION_MAJOR) {
    NSLog("WowType: 核心接口版本 %d 和编译时的主版本 %d 对不上", wowtype_abi_version(), WOWTYPE_ABI_VERSION_MAJOR)
    exit(1)
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
