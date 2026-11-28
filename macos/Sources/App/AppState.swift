// 进程里只有一份的东西：词库（后台载入）、设置、数据目录、定时保存学习数据、互译的翻译器。

import AppKit
import Carbon
import CWowtype

final class AppState {
    static let shared = AppState()

    /// 后台载入完成前是 nil；输入控制器每次按键时来取（换词库时换成新的）。
    private(set) var engine: Engine?
    private var loading = false
    /// 载入途中设置又换了词库：载完再看一次
    private var reloadAfterLoading = false
    private var commitsSinceSave = 0
    /// 每上屏这么多次存一次（系统可能随时杀掉输入法进程，和 fcitx5 外壳一样）。
    private let saveEvery = 20

    /// wowtype.conf 的内容（键名同 Linux）。改了以后 configGeneration 加一，输入控制器照着重新设置会话。
    private(set) var config = WowtypeConfig()
    private(set) var configGeneration = 0
    /// 互译的翻译器：设置里第一次打开 Translate 时建，之后一直留着（和 Linux 一样），所有输入框共用。
    /// 本地模型的 llama-server 也只有这一个，第一次翻译时才起
    private(set) var translator: Translator?
    /// 正在用的词库文件，和它载入时的 (大小, 修改时间)
    private var lexiconInUse: String?
    private var lexiconStamp: FileStamp?
    /// 上次载入失败的词库和它那时的 (大小, 修改时间)：文件没变、设置没换就不再试（不然每秒重试一次），
    /// 这期间用着自带的词库
    private var failedLexicon: String?
    private var failedLexiconStamp: FileStamp?
    /// 引擎载入时用的整句增强模型（没有是 nil）和它那时的 (大小, 修改时间)：导入、删掉、换了就重新载入引擎
    private var nnlmInUse: String?
    private var nnlmStamp: FileStamp?
    private var configStamp: FileStamp?
    private var customStamp: FileStamp?
    private var lastCheck: TimeInterval = 0
    /// 互译本地模型现在用的 llama-server（空的是没找到）
    private var llamaServerInUse = ""
    /// 上次找 llama-server 的时间（没找到时最多 5 秒找一次，不在按键路径上每秒查文件）
    private var llamaProbe: TimeInterval = 0
    private var missingLexiconLogged: String?
    /// 上一次看系统剪贴板时它的 changeCount（没变就不读）
    private var clipboardChangeCount = -1
    /// 跨设备复制粘贴（docs/SYNC.md）。只有输入法这个进程收发（startClipboardSync），设置窗口那个进程不动它
    let clipboardSync = ClipboardSync()
    private var clipboardSyncOwner = false
    private var clipboardSyncTimer: Timer?
    /// 同步那边上一次看剪贴板时的 changeCount，和那时读到的文字（nil：读不了，比如标了「机密」）
    private var syncChangeCount = -1
    private var syncLastText: String?
    /// 发布页上比现在装的新的版本（输入法菜单里多一项「下载并安装」）；没有是 nil
    private(set) var availableUpdate: String?
    private var updateChecking = false
    /// 下一次看要不要检查更新的时刻（systemUptime）：最多一小时看一次，没网时也不会每切一次输入框就去连
    private var nextUpdateLook: TimeInterval = 0

    /// 第几轮「切到 WowType」（InitialMode）：进程起来算第 1 轮，每次从别的输入法切回来加一。
    /// 每个输入框（输入控制器）在新的一轮里第一次用到 WowType 时按 InitialMode 定一次中 / 英
    private(set) var switchGeneration = 1
    /// 切走过 WowType（停用以后系统当前的输入源不是它）：下一次有输入框用到 WowType 时开新的一轮
    private var switchedAway = false
    /// 停用以后过这么久再看系统当前的输入源（切输入法时系统先停用、再换输入源）
    private let switchCheckDelay: TimeInterval = 0.3

    /// 输入控制器停用了（切输入法、换应用、点到别处都会）：过一会儿看系统现在用的还是不是 WowType，
    /// 不是就记下切走了。安全输入开着（密码框里系统临时换成英文键盘）时不算，和 Linux 一样。
    func noteDeactivated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + switchCheckDelay) { [weak self] in
            guard let self, !IsSecureEventInputEnabled(), Installer.isCurrentSource == false else { return }
            self.switchedAway = true
        }
    }

    /// 最近启用的输入控制器（最近用过的输入框）：外部命令切模式切的是它
    weak var activeController: WowTypeInputController?

    /// 外部命令（WowType --mode）：request 是 zh、en、translate、toggle，空串只问。返回切完以后最近用过的输入框的模式；
    /// 还没有输入框用过 WowType 时是空串。
    func externalMode(_ request: String) -> String {
        guard let controller = activeController else { return "" }
        return controller.externalMode(request)
    }

    /// 输入控制器启用了：切走过就开新的一轮，返回现在是第几轮、这一下是不是刚从别的输入法切回来
    /// （刚切回来按 InitialMode，不按 WindowMode，和 Linux 一样）。
    func noteActivated() -> (generation: Int, switchedBack: Bool) {
        let switchedBack = switchedAway
        if switchedAway {
            switchedAway = false
            switchGeneration += 1
        }
        return (switchGeneration, switchedBack)
    }

    /// 上一次启用 WowType 的应用和窗口（WindowMode，#254）
    private var windowFocus = WindowFocus()

    /// 输入控制器启用了：记下现在是哪个应用的哪个窗口，返回是不是换了应用、换了窗口。
    func noteWindow(_ key: String) -> Bool {
        windowFocus.moved(to: key)
    }

    /// 打字统计的句柄（core 的 Recorder）：建好时是关着的（不读不建文件），loadConfig 按 TypingStats 打开。
    /// 开着时只在本机按天记计数，不记打的内容。
    private(set) var stats: OpaquePointer?

    private init() {
        RecentEmoji.shared.path = supportDir.appendingPathComponent("emoji-recent.txt").path
        let statsPath = supportDir.appendingPathComponent("stats.json").path
        stats = wowtype_stats_new(statsPath)
        if stats == nil {
            NSLog("WowType: 建不了打字统计 %@", statsPath)
        }
    }

    deinit {
        if let stats {
            // 开着时交出最后攒着的、等写完
            wowtype_stats_free(stats)
        }
    }

    /// 设置里的 DeveloperMode（默认关）：开着时核心把每次选词、上屏明文记进数据目录的 devlog.jsonl，
    /// 会话的每次调用自己写，这里只管开关。
    private func applyDeveloperSettings() {
        DevLog.apply(enabled: config.developerMode,
                     path: supportDir.appendingPathComponent(DevLog.fileName).path)
    }

    /// 设置里的 TypingStats：关掉时记录器丢掉内存里还没写的计数，以后什么都不记。
    private func applyStatsSettings() {
        guard let stats else { return }
        _ = wowtype_stats_set_enabled(stats, config.typingStats ? 1 : 0)
    }

    /// 记一次物理按键（按键热力图）。长按由 `isARepeat` 在外壳挡掉，这里每次按下都算；
    /// 密码框（安全输入）里的不算。统计关着时什么都不做。
    func recordKey(_ keyCode: UInt16, sensitive: Bool) {
        guard let stats, config.typingStats, !sensitive else { return }
        _ = wowtype_stats_key(stats, 1, UInt32(keyCode), 1, 0, wowtype_stats_now_ms())
    }

    /// 记一次上屏：文字只交给核心数各类字符有几个，核心不留下。密码框里的不算，统计关着时什么都不做。
    func recordCommit(_ text: String, source: String, scheme: String, candidateIndex: Int, sensitive: Bool) {
        guard let stats, config.typingStats, !sensitive else { return }
        text.withCString { textPointer in
            source.withCString { sourcePointer in
                scheme.withCString { schemePointer in
                    _ = wowtype_stats_commit(stats, textPointer, sourcePointer, schemePointer,
                                             Int32(candidateIndex), 0, wowtype_stats_now_ms())
                }
            }
        }
    }

    /// 把攒着的统计交给核心的写文件线程（失焦时），不等它写。
    func flushStats() {
        guard let stats, config.typingStats else { return }
        _ = wowtype_stats_flush(stats, wowtype_stats_now_ms())
    }

    // 第一次要画候选框时才建窗口（自检时没有图形界面）
    private var panelCreated = false
    lazy var candidatePanel: CandidatePanel = {
        panelCreated = true
        let panel = CandidatePanel()
        panel.fontSize = CGFloat(config.candidateFontSize)
        return panel
    }()

    /// 安装包里的数据（词库、英文词表、语言模型）。
    var resourceDir: URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
    }

    /// 用户数据：~/Library/Application Support/WowType（测试时可用 WOWTYPE_DATA_DIR 换个地方）
    var supportDir: URL {
        if let dir = ProcessInfo.processInfo.environment["WOWTYPE_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WowType", isDirectory: true)
    }

    var userDictPath: String { supportDir.appendingPathComponent("user.tsv").path }
    var historyPath: String { supportDir.appendingPathComponent("history.tsv").path }
    /// 设置，键名同 Linux 的 ~/.config/fcitx5/conf/wowtype.conf
    var configPath: String { supportDir.appendingPathComponent("wowtype.conf").path }
    /// 自定义词（常用语），格式同 Linux 的 ~/.local/share/wowtype/custom.tsv
    var customWordsPath: String { supportDir.appendingPathComponent("custom.tsv").path }
    /// 互译的 API Key（一行，0600），同 Linux 的 ~/.config/wowtype/translate.key；不写进 wowtype.conf
    var translateKeyPath: String { supportDir.appendingPathComponent("translate.key").path }
    /// 跨设备复制粘贴的配对文件（设备编号、组密钥）和中转服务的访问口令，都只有自己能读
    var syncStatePath: String { supportDir.appendingPathComponent("sync.json").path }
    var syncRelayKeyPath: String { supportDir.appendingPathComponent("sync-relay.key").path }
    /// ClipboardSyncDeviceName 留空时用的名字：「系统设置 → 通用 → 关于本机」里的电脑名
    var syncHostName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
    /// 改 wowtype.conf 的 Lexicon，只动这一项（命令行 --install-lexicon / --use-lexicon 用）。
    /// 输入法按键时看到文件变了就换词库；万象包更新了、路径没变时，词库文件的大小、时间变了也会重载。
    func setLexicon(_ path: String) throws {
        let text = readText(configPath)
        let base = WowtypeConfig.parse(text ?? "")
        var wanted = base
        wanted.lexicon = path
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try writeText(wanted.merged(changesFrom: base, into: text), to: configPath)
    }

    /// 本地翻译模型，设置里 TranslateLocalModel 留空时用（同 Linux 的 ~/.local/share/wowtype/models/）
    /// 语音识别模型（设置窗口「语音」页下载），同 Linux 的 ~/.local/share/wowtype/wtlocal
    var voiceModelDir: String { VoiceModelInstaller.folder(in: supportDir).path }

    var localModelPath: String {
        supportDir.appendingPathComponent("models/Hy-MT3-1.8B-Q4_K_M.gguf").path
    }

    /// 设置里没填 TranslateLlamaServer 时去哪找 llama-server：输入法是系统启动的，PATH 里只有
    /// /usr/bin 这些，Homebrew 装的 llama.cpp 要自己找。都没有时交给核心（PATH、~/.local/share/wowtype/llama）。
    func findLlamaServer() -> String {
        let candidates = [supportDir.appendingPathComponent("llama/llama-server").path,
                          "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server",
                          "/opt/local/bin/llama-server"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }

    /// 实际用哪个词库：设置里的 Lexicon（文件在才用）> 安装包里的雾凇词库。
    func lexiconPath() -> String? {
        let configured = config.lexicon
        if !configured.isEmpty {
            let path = (configured as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                return path
            }
            if missingLexiconLogged != path {
                missingLexiconLogged = path
                NSLog("WowType: 设置里的词库 %@ 不在，用自带的词库", path)
            }
        }
        return bundledLexiconPath()
    }

    /// 安装包里的词库。词库旁边会写一份快照（.wcache，下次启动快很多）；安装包是签过名的，
    /// 不能往里写，所以在数据目录放一个指向安装包里词库的链接，快照就落在数据目录。
    private func bundledLexiconPath() -> String? {
        let bundled = resourceDir.appendingPathComponent("lexicon.tsv")
        guard FileManager.default.fileExists(atPath: bundled.path) else { return nil }
        let link = supportDir.appendingPathComponent("lexicon.tsv")
        let fm = FileManager.default
        // 第一次启动时数据目录还没有：先建，不然链接建不成，快照就写进安装包了
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != bundled.path {
            try? fm.removeItem(at: link)
            if (try? fm.createSymbolicLink(at: link, withDestinationURL: bundled)) == nil {
                return bundled.path
            }
        }
        return link.path
    }

    /// 整句增强模型（字级神经语言模型）：设置窗口导入的微信输入法模型优先，没有再用安装包里的 nnlm.bin
    /// （WowType 自己训的，scripts/make-data.sh 下载到了就随包带上）；都没有是 nil，整句照常出，只是不用它重排。
    func nnlmPath() -> String? {
        let imported = NnlmInstaller.model(in: supportDir).path
        if FileManager.default.fileExists(atPath: imported) {
            return imported
        }
        return resource("nnlm.bin")
    }

    func resource(_ name: String) -> String? {
        let path = resourceDir.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 读设置文件。没有就用默认值（和 Linux 一样，不自动建文件；设置窗口改了设置、或者用文本编辑打开时才建）。
    func loadConfig() {
        configStamp = FileStamp(configPath)
        let loaded = WowtypeConfig.load(path: configPath)
        if loaded != config || configGeneration == 0 {
            config = loaded
            configGeneration += 1
            applyTranslateSettings()
            applyStatsSettings()
            applyDeveloperSettings()
            applyClipboardSyncSettings()
            NSLog("WowType: 设置 %@ 每页%d 模糊音=%d(%u) 纠错=%d 双拼=%d(%@) 五笔=%d Shift切换=%@ 繁体=%d 半角标点=%d 字号=%d 词库=%@ 工具栏=%d 剪贴板历史=%d 表情键=%@ 互译=%@",
                  config.horizontal ? "横排" : "竖排", config.pageSize, config.fuzzy ? 1 : 0, config.fuzzyGroups,
                  config.typoCorrection ? 1 : 0, config.shuangpin ? 1 : 0, config.shuangpinScheme, config.wubi ? 1 : 0,
                  config.shiftToggle.rawValue, config.traditional ? 1 : 0, config.halfwidthPunct ? 1 : 0,
                  config.candidateFontSize, config.lexicon.isEmpty ? "自带" : config.lexicon,
                  config.toolbar ? 1 : 0, config.clipboardHistory ? 1 : 0, config.emojiKey?.name ?? "不用",
                  translateSummary())
        }
        applyPanelSettings()
    }

    /// 设置里管互译的部分。和 Linux 一样，打开过一次就留着翻译器（关掉时只是切不到「译」）；
    /// 不用本地模型了马上停掉 llama-server。
    private func applyTranslateSettings() {
        if config.translate && translator == nil {
            translator = Translator()
        }
        guard let translator else { return }
        // 手动建的 Key 文件权限可能太宽，收紧到只有自己能读
        TranslateKeyFile.tighten(translateKeyPath)
        llamaServerInUse = config.translateLocal ? findLlamaServer() : ""
        translator.configure(config, keyFile: translateKeyPath, defaultLocalModel: localModelPath,
                             llamaServer: llamaServerInUse)
    }

    private func translateSummary() -> String {
        guard config.translate else { return "关" }
        guard let translator, translator.isReady else { return "开（未配置，切不到「译」）" }
        let service: String
        switch config.translateEngine {
        case .local:
            service = "本地 HY-MT"
        case .bilibili:
            service = "哔哩哔哩 " + (config.translateModel.isEmpty ? WowtypeConfig.bilibiliDefaultModel : config.translateModel)
        case .custom:
            service = "\(config.translateModel) @ \(config.translateBaseUrl)"
        }
        return "开（\(service) → \(config.translateTarget)）"
    }

    // MARK: 跨设备复制粘贴

    /// 输入法进程启动时调一次：从此由这个进程收发。
    func startClipboardSync() {
        clipboardSyncOwner = true
        applyClipboardSyncSettings()
    }

    private func applyClipboardSyncSettings() {
        guard clipboardSyncOwner else { return }
        TranslateKeyFile.tighten(syncRelayKeyPath)
        clipboardSync.configure(config, stateFile: syncStatePath, relayKeyFile: syncRelayKeyPath,
                                hostName: syncHostName)
        guard config.clipboardSync else {
            clipboardSyncTimer?.invalidate()
            clipboardSyncTimer = nil
            return
        }
        // 重新来过：现在剪贴板里有什么，下一拍再报一次（核心只当基准，不发）
        syncChangeCount = -1
        guard clipboardSyncTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickClipboardSync() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        clipboardSyncTimer = timer
    }

    /// 每秒一次：把本机剪贴板交给核心，取别的设备复制过来的。
    private func tickClipboardSync() {
        // 设置窗口里改了设置（开关、中转服务）：不用等切输入框就跟上
        checkForChanges()
        guard config.clipboardSync else { return }
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != syncChangeCount {
            // changeCount 变了才真去读（不然 macOS 15.4 以后可能每秒弹一次「粘贴自…」）
            syncChangeCount = pasteboard.changeCount
            let skipped: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                        "org.nspasteboard.AutoGeneratedType"]
            if let types = pasteboard.types, types.contains(where: { skipped.contains($0.rawValue) }) {
                // 密码管理器标了「不要记」的：不交给核心
                syncLastText = nil
            } else {
                let text = pasteboard.string(forType: .string) ?? ""
                // 太长的核心反正不发；不留一大段在内存里，当成空的
                syncLastText = text.utf8.count > 16 * 1024 ? "" : text
            }
        }
        // 没变也照报同一段：核心重新起来以后（刚配好对、换了设置）要靠它认出「没变」
        if let text = syncLastText {
            clipboardSync.observe(text)
        }
        var latest: String?
        while let received = clipboardSync.poll() {
            NSLog("WowType: 跨设备粘贴：收到 %@ 复制的 %d 字节", received.from, received.text.utf8.count)
            latest = received.text
        }
        // 核心已经把它记进剪贴板历史（v + 空格里能选）；这里再放进系统剪贴板，Command+V 也能贴。
        // 放进去以后下一拍会当成「本机复制的」报回去，核心认得出来、不往回发
        if let latest, config.clipboardSyncPaste {
            pasteboard.clearContents()
            pasteboard.setString(latest, forType: .string)
        }
    }

    /// 有人在用输入法（切到输入框、按键）：中转服务那边保持连接。
    func touchClipboardSync() {
        if config.clipboardSync { clipboardSync.touch() }
    }

    /// 退出时停掉本地模型的 llama-server（它是输入法起的子进程）。
    func shutdownTranslator() {
        translator?.configure(WowtypeConfig(), keyFile: "", defaultLocalModel: "")
    }

    /// 候选框的设置（字号）。
    private func applyPanelSettings() {
        // 候选框是第一次要画时才建的，自检时不要建窗口
        guard panelCreated else { return }
        candidatePanel.fontSize = CGFloat(config.candidateFontSize)
    }

    /// 设置里管引擎的部分 + 自定义词。
    private func applyEngineSettings(_ engine: Engine) {
        for problem in engine.apply(config, conversion: resource("s2t.tsv"), wubi: resource("wubi86.tsv")) {
            NSLog("WowType: %@", problem)
        }
        customStamp = FileStamp(customWordsPath)
        let custom = engine.loadCustomWords(customWordsPath)
        if custom < 0 {
            NSLog("WowType: 自定义词载入失败 %@", customWordsPath)
        } else if custom > 0 {
            NSLog("WowType: 载入自定义词 %d 条", custom)
        }
    }

    /// 同步载入（自检和后台线程用）。只读文件，设置在主线程上由 install 套上。
    func makeEngine(lexicon: String) -> Engine? {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let engine = Engine(lexicon: lexicon, languageModel: resource("words.lm"))
            ?? Engine(lexicon: lexicon)
        else {
            NSLog("WowType: 载入词库失败 %@", lexicon)
            return nil
        }
        if let english = resource("english.txt") {
            engine.loadEnglish(english)
        }
        // 用户自己训的领域词级模型（可选），和 words.lm 混着用
        let domain = supportDir.appendingPathComponent("words.domain.lm").path
        if FileManager.default.fileExists(atPath: domain) {
            if engine.setDomainLM(domain) {
                NSLog("WowType: 载入领域词级模型 %@", domain)
            } else {
                NSLog("WowType: 领域词级模型载入失败 %@", domain)
            }
        }
        if let nnlm = nnlmPath() {
            let vocab = wowtype_engine_load_nnlm(engine.handle, nnlm)
            if vocab >= 0 {
                NSLog("WowType: 载入整句增强模型 %@（字表 %d）", nnlm, vocab)
            } else {
                NSLog("WowType: 整句增强模型载入失败 %@", nnlm)
            }
        }
        engine.loadUserDict(userDictPath)
        engine.loadHistory(historyPath)
        return engine
    }

    /// 自检用：读设置、载入词库、套上设置。
    func makeConfiguredEngine() -> Engine? {
        loadConfig()
        guard let lexicon = lexiconPath() else {
            NSLog("WowType: 安装包里没有 lexicon.tsv")
            return nil
        }
        guard let engine = makeEngine(lexicon: lexicon) else { return nil }
        applyEngineSettings(engine)
        return engine
    }

    /// 启动时调用：词库有几十 MB，放后台读，读完再交给输入控制器。
    func loadEngineInBackground() {
        if configGeneration == 0 {
            loadConfig()
        }
        guard !loading else {
            reloadAfterLoading = true
            return
        }
        guard let lexicon = lexiconPath() else {
            NSLog("WowType: 安装包里没有 lexicon.tsv")
            return
        }
        // 换词库：新引擎要读学习数据，先把旧引擎学到的存下来、等写完（载入途中学的就丢了，最多几秒）
        save(force: true, wait: true)
        loading = true
        let stamp = FileStamp(lexicon)
        // 设置里指定的词库在、但读不出来（格式不对、没权限）：改载自带的，不然只能打英文
        let bundled = bundledLexiconPath()
        let fallback = bundled == lexicon ? nil : bundled
        let fallbackStamp = fallback.flatMap { FileStamp($0) }
        // makeEngine 里载入的整句增强模型：记下是哪个、什么时候的（载没载上都记，不然载不上时每秒重载）
        let nnlm = nnlmPath()
        let nnlmStampNow = nnlm.flatMap { FileStamp($0) }
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            var used = lexicon
            var engine = self.makeEngine(lexicon: lexicon)
            if engine == nil, let fallback {
                NSLog("WowType: 词库 %@ 读不出来，改用自带的词库", lexicon)
                engine = self.makeEngine(lexicon: fallback)
                used = fallback
            }
            let loaded = engine, loadedPath = used
            DispatchQueue.main.async {
                self.loading = false
                self.nnlmInUse = nnlm
                self.nnlmStamp = nnlmStampNow
                NSLog("WowType: 词库 %@ 载入%@，用时 %.1f 秒", loadedPath, loaded == nil ? "失败" : "完成",
                      Date().timeIntervalSince(start))
                // 想要的词库没载上：记下来，文件和设置都没变时 checkForChanges 不再试
                if loaded == nil || loadedPath != lexicon {
                    self.failedLexicon = lexicon
                    self.failedLexiconStamp = stamp
                } else {
                    self.failedLexicon = nil
                    self.failedLexiconStamp = nil
                }
                if let engine = loaded {
                    self.applyEngineSettings(engine)
                    self.engine = engine
                    self.commitsSinceSave = 0
                    self.lexiconInUse = loadedPath
                    self.lexiconStamp = loadedPath == lexicon ? stamp : fallbackStamp
                }
                if self.reloadAfterLoading {
                    self.reloadAfterLoading = false
                    self.checkForChanges(force: true)
                }
            }
        }
    }

    /// 用本地模型互译、之前没找到 llama-server 时，最多 5 秒看一次现在有没有了。
    private func llamaServerAppeared(now: TimeInterval) -> Bool {
        guard config.translate, config.translateLocal, llamaServerInUse.isEmpty, now - llamaProbe >= 5 else {
            return false
        }
        llamaProbe = now
        return !findLlamaServer().isEmpty
    }

    /// 看看设置、自定义词、词库文件改了没有（按键时调，一秒最多看一次；切换输入框时 force）。
    /// 设置改了马上生效；换了词库在后台载入，载完之前照旧用旧的。
    func checkForChanges(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastCheck >= 1 else { return }
        lastCheck = now
        if translator != nil && (force || llamaServerAppeared(now: now)) {
            // 切换输入框时再配一次（顺带收紧 Key 文件的权限）；本地模型的 llama-server 之前没找到、现在有了
            // （设置窗口里刚下好，或者后来才 brew install 的）也重配，不用切输入框。
            // 模型文件不用这样盯：核心判断「就绪」时每次都现看模型在不在
            applyTranslateSettings()
        }
        if FileStamp(configPath) != configStamp {
            let generation = configGeneration
            loadConfig()
            if configGeneration != generation, let engine {
                for problem in engine.apply(config, conversion: resource("s2t.tsv"), wubi: resource("wubi86.tsv")) {
                    NSLog("WowType: %@", problem)
                }
            }
        }
        if let engine, FileStamp(customWordsPath) != customStamp {
            customStamp = FileStamp(customWordsPath)
            let custom = engine.loadCustomWords(customWordsPath)
            NSLog("WowType: 自定义词改了，重新载入 %d 条", custom)
        }
        // 想要的词库变了就（重新）载入：换了词库、词库文件改了、上次没载上的文件换过了。
        // engine 还是 nil（上次连自带的都没载上）时也走这里，不会卡在只能打英文
        guard let wanted = lexiconPath() else { return }
        let wantedStamp = FileStamp(wanted)
        let failedBefore = wanted == failedLexicon && wantedStamp == failedLexiconStamp
        let lexiconChanged = !failedBefore && (wanted != lexiconInUse || wantedStamp != lexiconStamp)
        // 设置窗口导入、删掉了整句增强模型：核心没有「卸下模型」的接口，整个引擎在后台重新载入（几秒，载完之前照旧用旧的）
        let nnlm = nnlmPath()
        let nnlmChanged = nnlm != nnlmInUse || nnlm.flatMap { FileStamp($0) } != nnlmStamp
        guard lexiconChanged || nnlmChanged else { return }
        if loading {
            reloadAfterLoading = true
        } else {
            if lexiconChanged {
                NSLog("WowType: 换词库 %@ -> %@", lexiconInUse ?? "", wanted)
            } else {
                NSLog("WowType: 整句增强模型换了（%@），重新载入", nnlm ?? "删掉了")
            }
            loadEngineInBackground()
        }
    }

    /// 设置窗口「文件」菜单「用文本编辑打开设置文件」：没有设置文件就写一份全是默认值的，用文本编辑打开。
    func openConfigFile() {
        if !FileManager.default.fileExists(atPath: configPath) {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try? WowtypeConfig.template().write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        openInTextEditor(configPath)
    }

    /// 设置窗口「文件」菜单「用文本编辑打开自定义词」：custom.tsv，格式同 Linux。
    func openCustomWordsFile() {
        if !FileManager.default.fileExists(atPath: customWordsPath) {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let header = """
            # 自定义词（常用语）：一行一个，编码<TAB>词[<TAB>频次]。加进去的词总排在候选第一个，简拼也能打。
            # 编码一般是拼音（可以用空格分音节），也可以是别的字母（mail）；词里 \\n 是换行。
            # 例：
            # zi jie tiao dong	字节跳动
            # mail	hello@example.com

            """
            try? header.write(toFile: customWordsPath, atomically: true, encoding: .utf8)
        }
        openInTextEditor(customWordsPath)
    }

    private func openInTextEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        if FileManager.default.fileExists(atPath: textEdit.path) {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 剪贴板历史（设置里 ClipboardHistory 打开时）：看一眼系统剪贴板，有新的文字就交给核心记（只在内存里）。
    /// 切换输入框、打开工具栏的剪贴板页时调；changeCount 没变就不读。
    /// 密码管理器复制的密码会标上 nspasteboard.org 的 ConcealedType（还有 TransientType、AutoGeneratedType），不记。
    func sampleClipboard() {
        guard config.clipboardHistory else {
            // 关着时核心已经清空了；再打开时把那时剪贴板上的记下来
            clipboardChangeCount = -1
            return
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChangeCount else { return }
        clipboardChangeCount = pasteboard.changeCount
        let skipped: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                    "org.nspasteboard.AutoGeneratedType"]
        guard let types = pasteboard.types, !types.contains(where: { skipped.contains($0.rawValue) }),
              let text = pasteboard.string(forType: .string)
        else {
            return
        }
        ClipboardHistory.remember(text)
    }

    /// 切换输入框时调：设置里 CheckUpdate 开着，上次查（输入法或设置窗口查的，记在 update-state）过了一天，
    /// 就在后台问一次 GitHub 最新正式版，不挡按键。有新版只在输入法菜单里多一项，不弹通知：输入法是后台进程、
    /// 没有开发者签名，通知要先弹框要授权，打字时弹出来也打扰人；菜单里点一下打开设置窗口，那里下载安装。
    /// 开发版（dev）、测试（设了 WOWTYPE_DATA_DIR）不查。
    func checkUpdateIfDue() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard config.checkUpdate, !updateChecking, uptime >= nextUpdateLook, AppUpdate.isRelease(appVersion),
              ProcessInfo.processInfo.environment["WOWTYPE_DATA_DIR"] == nil
        else { return }
        nextUpdateLook = uptime + 3600
        let dir = supportDir
        let state = UpdateInstaller.readState(supportDir: dir)
        noteLatest(state.latest)
        guard AppUpdate.due(state, now: Int64(Date().timeIntervalSince1970)) else { return }
        updateChecking = true
        let beta = config.betaUpdates
        DispatchQueue.global(qos: .utility).async {
            let release = try? UpdateInstaller.fetchLatest(supportDir: dir, beta: beta)
            DispatchQueue.main.async {
                self.updateChecking = false
                guard let release else { return }
                self.noteLatest(release.tag)
                if let version = self.availableUpdate {
                    NSLog("WowType: 有新版本 %@（现在 %@）", version, appVersion)
                }
                self.autoUpdateLexicon(release)
            }
        }
    }

    /// 后台更新万象词库没成功的那一版和时刻（Unix 秒）：一天以内不再试（只记在这个进程里）
    private var lexiconFailed: (version: String, at: Int64)?
    private var lexiconUpdating = false

    /// 检查更新顺带：正在用的万象词库在发布页上有新版，就在后台下载、按 SHA256SUMS 校验、整个换进去
    /// （和 Linux 的 auto_update_lexicon 一样，不打扰用户）。词库文件变了，下一次按键时在后台换上新的。
    private func autoUpdateLexicon(_ release: LexiconPackInstaller.Release) {
        let dir = supportDir
        let wanxiang = LexiconPackInstaller.lexicon(in: dir)
        let inUse = !config.lexicon.isEmpty && (config.lexicon as NSString).expandingTildeInPath == wanxiang
        let now = Int64(Date().timeIntervalSince1970)
        guard !lexiconUpdating,
              let version = LexiconPack.autoUpdate(
                installed: LexiconPack.installedVersion(folder: LexiconPackInstaller.folder(in: dir).path),
                inUse: inUse, available: release.wanxiang?.version,
                failedVersion: lexiconFailed?.version, failedAt: lexiconFailed?.at ?? 0, now: now)
        else { return }
        lexiconUpdating = true
        NSLog("WowType: 万象词库有新版 %@，在后台更新", version)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () -> String in
                let tarball = try LexiconPackInstaller.download(release) { _, _ in }
                defer { try? FileManager.default.removeItem(at: tarball) }
                return try LexiconPackInstaller.install(tarball, supportDir: dir)
            }
            DispatchQueue.main.async {
                self.lexiconUpdating = false
                switch result {
                case .success(let installed):
                    self.lexiconFailed = nil
                    NSLog("WowType: 万象词库更新到 %@", installed)
                case .failure(let error):
                    self.lexiconFailed = (version, now)
                    NSLog("WowType: 万象词库 %@ 没更新好：%@", version, String(describing: error))
                }
            }
        }
    }

    private func noteLatest(_ tag: String) {
        availableUpdate = AppUpdate.version(tag: tag).flatMap { AppUpdate.isNewer($0, than: appVersion) ? $0 : nil }
    }

    /// 上屏里有学到的选词（Composer.onCommit 只在 frame->learned 时调）。
    func didCommit() {
        commitsSinceSave += 1
        if commitsSinceSave >= saveEvery {
            save()
        }
    }

    /// Ctrl+Delete 忘掉了学错的词：马上存（不等攒够上屏次数）。
    func didForget() {
        commitsSinceSave += 1
        save()
    }

    /// 存用户词库和输入习惯。在核心的后台线程上写（ABI 1.11），这里（主线程，也是按键的线程）不等磁盘；
    /// wait 时等写完再返回（退出、换词库前：新引擎要读这两个文件）。
    func save(force: Bool = false, wait: Bool = false) {
        guard let engine else { return }
        // 上次后台写失败了现在才知道：记下来，这次接着存（写的都是整份，存成了就补上了，和 Linux 一样）
        if let error = engine.waitSaved(timeout: 0) {
            NSLog("WowType: 保存用户词库或输入习惯失败：%@", error)
            commitsSinceSave = max(commitsSinceSave, 1)
        }
        if force || commitsSinceSave > 0 {
            try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let dictQueued = engine.saveUserDictAsync(userDictPath)
            let historyQueued = engine.saveHistoryAsync(historyPath)
            if dictQueued && historyQueued {
                commitsSinceSave = 0
            }
        }
        if wait, let error = engine.waitSaved() {
            NSLog("WowType: 保存用户词库或输入习惯失败：%@", error)
        }
    }
}

/// 文件的 (大小, 修改时间)；文件不在是 nil。用来看文件改了没有。
struct FileStamp: Equatable {
    let size: UInt64
    let modified: Date

    init?(_ path: String) {
        // 自带词库是指向安装包的链接：看链接指向的文件
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: real),
              let modified = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        self.modified = modified
    }
}
