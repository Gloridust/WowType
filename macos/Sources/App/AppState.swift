// 进程里只有一份的东西：词库（后台载入）、数据目录、定时保存学习数据。

import AppKit

final class AppState {
    static let shared = AppState()

    /// 后台载入完成前是 nil；输入控制器每次按键时来取。
    private(set) var engine: Engine?
    private var loading = false
    private var commitsSinceSave = 0
    /// 每上屏这么多次存一次（系统可能随时杀掉输入法进程，和 fcitx5 外壳一样）。
    private let saveEvery = 20

    // 第一次要画候选框时才建窗口（自检时没有图形界面）
    lazy var candidatePanel = CandidatePanel()

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

    /// 词库路径。词库旁边会写一份快照（.wcache，下次启动快很多）；安装包是签过名的，
    /// 不能往里写，所以在数据目录放一个指向安装包里词库的链接，快照就落在数据目录。
    func lexiconPath() -> String? {
        let bundled = resourceDir.appendingPathComponent("lexicon.tsv")
        guard FileManager.default.fileExists(atPath: bundled.path) else { return nil }
        let link = supportDir.appendingPathComponent("lexicon.tsv")
        let fm = FileManager.default
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

    /// 同步载入（自检和后台线程用）。
    func makeEngine() -> Engine? {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let lexicon = lexiconPath() else {
            NSLog("WowType: 安装包里没有 lexicon.tsv")
            return nil
        }
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

    /// 启动时调用：词库有几十 MB，放后台读，读完再交给输入控制器。
    func loadEngineInBackground() {
        guard engine == nil, !loading else { return }
        loading = true
        let start = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = self.makeEngine()
            DispatchQueue.main.async {
                self.engine = engine
                self.loading = false
                NSLog("WowType: 词库载入%@，用时 %.1f 秒", engine == nil ? "失败" : "完成",
                      Date().timeIntervalSince(start))
            }
        }
    }

    func didCommit() {
        commitsSinceSave += 1
        if commitsSinceSave >= saveEvery {
            save()
        }
    }

    func save() {
        guard let engine, commitsSinceSave > 0 else { return }
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
