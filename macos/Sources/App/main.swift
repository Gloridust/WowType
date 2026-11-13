// WowType 的 macOS 输入法进程。
//
//   WowType.app/Contents/MacOS/WowType              输入法服务（系统按需启动）
//   … --register | --enable | --select | --disable  向系统登记 / 打开 / 切换 / 关闭（install.sh 用）
//   … --selftest                                    载入安装包里的词库打一句话，CI 用来检查链接和资源
//   … --settings [general|input|emoji|voice|translate|words] 设置窗口（另一个进程，输入法菜单里「设置…」开的就是它）
//   … --install-lexicon [wanxiang | 文件.tar.gz]      装万象词库并切过去；--use-lexicon rime-ice|wanxiang 切换
//   … --download-model [--accept-license]          下载本地翻译模型（缺 llama-server 时一起下）
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
    for name in ["lexicon.tsv", "english.txt", "words.lm", "s2t.tsv", "wubi86.tsv"] {
        print("  \(name)：\(AppState.shared.resource(name) == nil ? "没有" : "有")")
    }
    let start = Date()
    guard let engine = AppState.shared.makeConfiguredEngine() else {
        print("FAIL 载入词库")
        return false
    }
    print(String(format: "词库载入 %.1f 秒", Date().timeIntervalSince(start)))
    let config = AppState.shared.config
    print("设置 \(AppState.shared.configPath)：\(config == WowtypeConfig() ? "默认" : "改过")，输入方案 \(config.inputScheme.rawValue)\(config.shuangpin ? "（\(config.shuangpinScheme)）" : "")")
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
    guard client.committed == "你好" else { return false }
    // 安装包里的五笔码表：wqvb 空格上屏「你好」
    var wubi = WowtypeConfig()
    wubi.inputScheme = .wubi86
    for problem in engine.apply(wubi, wubi: AppState.shared.resource("wubi86.tsv")) {
        print("FAIL \(problem)")
    }
    let wubiClient = SelfTestClient()
    let wubiComposer = Composer(engine: engine, client: wubiClient)
    wubiComposer.apply(wubi)
    for c in "wqvb " {
        _ = wubiComposer.handle(.char(c))
    }
    print("五笔 wqvb → 上屏「\(wubiClient.committed)」")
    return wubiClient.committed == "你好"
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

/// 和 Linux 的 wowtype-config 一样：--install-voice-model [语音包.apk] 下载（或从文件）装上语音模型并打开语音输入，
/// --remove-voice-model 删掉模型并关掉语音输入。
func voiceModelCommand(_ args: [String]) -> Bool {
    let state = AppState.shared
    var values = WowtypeConfig.parse(readText(state.configPath) ?? "")
    let base = values
    if args[0] == "--remove-voice-model" {
        let freed = VoiceModelInstaller.remove(supportDir: state.supportDir)
        print(freed > 0 ? "已删除语音模型，空出 \(LocalModel.sizeText(freed))" : "没有语音模型")
        values.voice = false
    } else {
        let file = args.count > 1 ? URL(fileURLWithPath: args[1]) : nil
        if VoiceModelInstaller.isReady(supportDir: state.supportDir) && file == nil {
            print("语音模型已经有了：\(state.voiceModelDir)")
        } else {
            do {
                let size = try VoiceModelInstaller.install(supportDir: state.supportDir, from: file,
                                                           control: DownloadControl()) { done, total in
                    let text = total > 0 ? "\(LocalModel.sizeText(done)) / \(LocalModel.sizeText(total))"
                                         : LocalModel.sizeText(done)
                    print("\r下载语音模型：\(text)   ", terminator: "")
                    fflush(stdout)
                }
                print("\n语音模型装好了（\(LocalModel.sizeText(size))）：\(state.voiceModelDir)")
            } catch {
                print("\n语音模型没装好：\(error)")
                return false
            }
        }
        values.voice = true
    }
    do {
        try writeText(values.merged(changesFrom: base, into: readText(state.configPath)), to: state.configPath)
    } catch {
        print("wowtype.conf 写不进去：\(error.localizedDescription)")
        return false
    }
    print(values.voice ? "语音输入已打开：按住\(values.voiceKey == "Alt_R" ? "右 Option" : values.voiceKey) 说话"
                       : "语音输入已关掉")
    return true
}

/// 测试用：不开麦克风，读 wav（16kHz 单声道）当成按住语音键说的话，打印识别结果。
func voiceTest(_ wav: String) -> Bool {
    guard !wav.isEmpty else {
        print("用法：WowType --voice-test 说的话.wav")
        return false
    }
    setenv("WOWTYPE_VOICE_WAV", wav, 1)
    guard let voice = wowtype_voice_new(AppState.shared.voiceModelDir) else {
        print("核心没带语音")
        return false
    }
    defer { wowtype_voice_free(voice) }
    wowtype_voice_key_down(voice)
    usleep(400_000)
    wowtype_voice_key_up(voice)
    let start = Date()
    while Date().timeIntervalSince(start) < 60 {
        let phase = Int(wowtype_voice_poll(voice))
        let text = wowtype_voice_text(voice).map { String(cString: $0) } ?? ""
        if phase == Int(WOWTYPE_VOICE_RESULT) {
            print("识别结果：\(text)（\(String(format: "%.1f", Date().timeIntervalSince(start))) 秒）")
            return !text.isEmpty
        }
        if phase == Int(WOWTYPE_VOICE_ERROR) {
            print("出错：\(text)")
            return false
        }
        usleep(50_000)
    }
    print("一分钟没出结果")
    return false
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
    case "--install-voice-model", "--remove-voice-model": ok = voiceModelCommand(Array(arguments.dropFirst()))
    case "--voice-test": ok = voiceTest(arguments.count > 2 ? arguments[2] : "")
    case "--version":
        print(appVersion)
        ok = true
    default:
        print("用法：WowType [--register | --enable | --select | --disable | --selftest | --settings [页面] | --version |\n"
              + "              --install-lexicon [wanxiang | 文件.tar.gz] | --use-lexicon rime-ice|wanxiang |\n"
              + "              --download-model [--accept-license] | --install-voice-model [语音包.apk] |\n"
              + "              --remove-voice-model | --voice-test 说的话.wav]")
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
