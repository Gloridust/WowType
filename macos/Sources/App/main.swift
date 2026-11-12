// WowType 的 macOS 输入法进程。
//
//   WowType.app/Contents/MacOS/WowType              输入法服务（系统按需启动）
//   … --register | --enable | --select | --disable  向系统登记 / 打开 / 切换 / 关闭（install.sh 用）
//   … --selftest                                    载入安装包里的词库打一句话，CI 用来检查链接和资源
//   … --settings [general|input|emoji|translate|words] 设置窗口（另一个进程，输入法菜单里「设置…」开的就是它）
//   … --install-lexicon [wanxiang | 文件.tar.gz]      装万象词库并切过去；--use-lexicon rime-ice|wanxiang 切换
//   … --download-model [--accept-license]          下载本地翻译模型（缺 llama-server 时一起下）
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

/// 和 Linux 的 wowtype-config 一样：--install-lexicon wanxiang|<文件.tar.gz> 下载 / 装上万象并切过去，
/// --use-lexicon rime-ice|wanxiang 切换。改的是 wowtype.conf 的 Lexicon，输入法下一次按键时换词库。
func lexiconCommand(_ args: [String]) -> Bool {
    let state = AppState.shared
    let wanxiang = LexiconPackInstaller.lexicon(in: state.supportDir)
    let lexicon: String
    if args[0] == "--use-lexicon" {
        guard args.count == 2, ["rime-ice", "wanxiang"].contains(args[1]) else {
            print("用法：WowType --use-lexicon rime-ice|wanxiang")
            return false
        }
        if args[1] == "wanxiang" && LexiconPack.installedVersion(folder: LexiconPackInstaller.folder(in: state.supportDir).path) == nil {
            print("还没装万象词库，先运行 WowType --install-lexicon wanxiang")
            return false
        }
        lexicon = args[1] == "wanxiang" ? wanxiang : ""
    } else {
        let source = args.count > 1 ? args[1] : "wanxiang"
        do {
            let file: URL
            if source == "wanxiang" {
                let release = try LexiconPackInstaller.fetchLatest()
                guard let pack = release.wanxiang else {
                    print("最新版 \(release.tag) 的发布页上还没有万象词库包")
                    return false
                }
                file = try LexiconPackInstaller.download(release) { done, total in
                    let text = total > 0 ? "\(done / 1_048_576) / \(total / 1_048_576) MB" : "\(done / 1_048_576) MB"
                    print("\r下载 \(pack.name)：\(text)   ", terminator: "")
                    fflush(stdout)
                }
                print()
            } else {
                file = URL(fileURLWithPath: source)
            }
            defer { if source == "wanxiang" { try? FileManager.default.removeItem(at: file) } }
            let version = try LexiconPackInstaller.install(file, supportDir: state.supportDir)
            print("万象词库 \(version) 装好了：\(LexiconPackInstaller.folder(in: state.supportDir).path)")
        } catch {
            print("万象词库没装好：\(error)")
            return false
        }
        lexicon = wanxiang
    }
    do {
        try state.setLexicon(lexicon)
    } catch {
        print("wowtype.conf 写不进去：\(error.localizedDescription)")
        return false
    }
    print("已切到" + (lexicon.isEmpty ? "雾凇拼音（默认）" : "万象拼音") + "，输入法下一次按键时换词库（载入要几秒）")
    return true
}

/// 和 Linux 的 wowtype-config --download-model 一样：先同意许可（--accept-license 跳过确认），下载本地翻译模型，
/// 找不到 llama-server 时顺带下载 llama.cpp 官方的。断了再跑一次接着下。
func downloadModelCommand(accepted: Bool) -> Bool {
    print(LocalModel.terms)
    print("协议全文：\(LocalModel.license)\n")
    if !accepted {
        guard isatty(STDIN_FILENO) != 0 else {
            print("加 --accept-license 表示接受上面的许可")
            return false
        }
        print("接受这份许可并下载？[y/N] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), ["y", "yes"].contains(answer)
        else { return false }
    }
    let state = AppState.shared
    let config = WowtypeConfig.load(path: state.configPath)
    let model = config.translateLocalModel.isEmpty
        ? state.localModelPath : (config.translateLocalModel as NSString).expandingTildeInPath
    let plan = LocalModelInstaller.plan(model: model, customServer: config.translateLlamaServer,
                                        supportDir: state.supportDir)
    if plan.canDownload {
        print("要下载 \(LocalModel.sizeText(plan.bytes))" + (LocalModelInstaller.hasPartial(model: model) ? "（接着上次下）" : ""))
        do {
            try LocalModelInstaller.install(plan, model: model, supportDir: state.supportDir, control: DownloadControl()) { p in
                let text: String
                switch p.stage {
                case .connecting: text = "正在连接…"
                case .model: text = "下载模型 \(p.percent)%（\(megabytes(p.done)) / \(megabytes(p.total))）"
                case .llama: text = "下载 llama-server \(p.percent)%（\(megabytes(p.done)) / \(megabytes(p.total))）"
                case .unpacking: text = "安装 llama-server…"
                }
                print("\r\(text)   ", terminator: "")
                fflush(stdout)
            }
            print()
        } catch {
            print("\n没下完：\((error as? PackError)?.description ?? error.localizedDescription)（再跑一次会接着下）")
            return false
        }
    }
    print("模型：\(model)")
    guard let server = LocalModelInstaller.findServer(custom: config.translateLlamaServer, supportDir: state.supportDir)
    else {
        print(config.translateLlamaServer.isEmpty
              ? "没有 llama-server，这台 Mac 也下载不了（要 macOS 13.3 以上），请自己装 llama.cpp（brew install llama.cpp）"
              : "设置里写的 llama-server 不在：\(config.translateLlamaServer)")
        return false
    }
    print("llama-server：\(server)")
    print("好了，可以用离线翻译了（输入法切换输入框后生效）")
    return true
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
    case "--install-lexicon", "--use-lexicon": ok = lexiconCommand(Array(arguments.dropFirst()))
    case "--download-model": ok = downloadModelCommand(accepted: arguments.contains("--accept-license"))
    case "--version":
        print(appVersion)
        ok = true
    default:
        print("用法：WowType [--register | --enable | --select | --disable | --selftest | --settings [页面] | --version |\n"
              + "              --install-lexicon [wanxiang | 文件.tar.gz] | --use-lexicon rime-ice|wanxiang |\n"
              + "              --download-model [--accept-license]]")
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
