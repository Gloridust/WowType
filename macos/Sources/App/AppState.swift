// 进程里只有一份的东西：词库（后台载入）、设置、数据目录、定时保存学习数据、互译的翻译器。

import AppKit
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
    private var configStamp: FileStamp?
    private var customStamp: FileStamp?
    private var lastCheck: TimeInterval = 0
    private var missingLexiconLogged: String?
    /// 上一次看系统剪贴板时它的 changeCount（没变就不读）
    private var clipboardChangeCount = -1

    /// 打字统计的句柄（core 的 Recorder）：按天聚合，只在本机。
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
            wowtype_stats_free(stats)
        }
    }

    /// 记一次物理按键（按键热力图）。长按由 `isARepeat` 在外壳挡掉，这里每次按下都算。
    func recordKey(_ keyCode: UInt16) {
        guard let stats else { return }
        _ = wowtype_stats_key(stats, 1, UInt32(keyCode), 1, wowtype_stats_now_ms())
    }

    /// 记一次上屏；只分类计数，不保存文字。
    func recordCommit(_ text: String, source: String, scheme: String, candidateIndex: Int) {
        guard let stats else { return }
        text.withCString { textPointer in
            source.withCString { sourcePointer in
                scheme.withCString { schemePointer in
                    _ = wowtype_stats_commit(stats, textPointer, sourcePointer, schemePointer,
                                             Int32(candidateIndex), wowtype_stats_now_ms())
                }
            }
        }
    }

    /// 把攒着的统计写进文件（失焦、退出前）。
    func flushStats() {
        guard let stats else { return }
        if wowtype_stats_flush(stats, wowtype_stats_now_ms()) != 0 {
            NSLog("WowType: 打字统计写入失败")
        }
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
    var localModelPath: String {
        supportDir.appendingPathComponent("models/HY-MT1.5-1.8B-Q4_K_M.gguf").path
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
            NSLog("WowType: 设置 %@ 每页%d 模糊音=%d(%u) 纠错=%d 双拼=%d(%@) Shift切换=%@ 繁体=%d 半角标点=%d 字号=%d 词库=%@ 工具栏=%d 剪贴板历史=%d 表情键=%@ 互译=%@",
                  config.horizontal ? "横排" : "竖排", config.pageSize, config.fuzzy ? 1 : 0, config.fuzzyGroups,
                  config.typoCorrection ? 1 : 0, config.shuangpin ? 1 : 0, config.shuangpinScheme,
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
        translator.configure(config, keyFile: translateKeyPath, defaultLocalModel: localModelPath,
                             llamaServer: config.translateLocal ? findLlamaServer() : "")
    }

    private func translateSummary() -> String {
        guard config.translate else { return "关" }
        guard let translator, translator.isReady else { return "开（未配置，切不到「译」）" }
        let service = config.translateLocal ? "本地 HY-MT" : "\(config.translateModel) @ \(config.translateBaseUrl)"
        return "开（\(service) → \(config.translateTarget)）"
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
        for problem in engine.apply(config, conversion: resource("s2t.tsv")) {
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
        // 换词库：新引擎要读学习数据，先把旧引擎学到的存下来（载入途中学的就丢了，最多几秒）
        save(force: true)
        loading = true
        let stamp = FileStamp(lexicon)
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = self.makeEngine(lexicon: lexicon)
            DispatchQueue.main.async {
                self.loading = false
                NSLog("WowType: 词库 %@ 载入%@，用时 %.1f 秒", lexicon, engine == nil ? "失败" : "完成",
                      Date().timeIntervalSince(start))
                if let engine {
                    self.applyEngineSettings(engine)
                    self.engine = engine
                    self.commitsSinceSave = 0
                    self.lexiconInUse = lexicon
                    self.lexiconStamp = stamp
                }
                if self.reloadAfterLoading {
                    self.reloadAfterLoading = false
                    self.checkForChanges(force: true)
                }
            }
        }
    }

    /// 看看设置、自定义词、词库文件改了没有（按键时调，一秒最多看一次；切换输入框时 force）。
    /// 设置改了马上生效；换了词库在后台载入，载完之前照旧用旧的。
    func checkForChanges(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastCheck >= 1 else { return }
        lastCheck = now
        if force && translator != nil {
            // 切换输入框时再找一次 llama-server（设置以后才 brew install 的）、收紧 Key 文件的权限
            applyTranslateSettings()
        }
        if FileStamp(configPath) != configStamp {
            let generation = configGeneration
            loadConfig()
            if configGeneration != generation, let engine {
                for problem in engine.apply(config, conversion: resource("s2t.tsv")) {
                    NSLog("WowType: %@", problem)
                }
            }
        }
        if let engine, FileStamp(customWordsPath) != customStamp {
            customStamp = FileStamp(customWordsPath)
            let custom = engine.loadCustomWords(customWordsPath)
            NSLog("WowType: 自定义词改了，重新载入 %d 条", custom)
        }
        guard engine != nil || loading else { return }
        let wanted = lexiconPath()
        if let wanted, wanted != lexiconInUse || FileStamp(wanted) != lexiconStamp {
            if loading {
                reloadAfterLoading = true
            } else if engine != nil {
                NSLog("WowType: 换词库 %@ -> %@", lexiconInUse ?? "", wanted)
                loadEngineInBackground()
            }
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

    func save(force: Bool = false) {
        guard let engine, force || commitsSinceSave > 0 else { return }
        commitsSinceSave = 0
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if !engine.saveUserDict(userDictPath) {
            NSLog("WowType: 保存用户词库失败")
        }
        if !engine.saveHistory(historyPath) {
            NSLog("WowType: 保存输入习惯失败")
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
