// 设置窗口的数据：wowtype.conf 和 custom.tsv（和 Linux 设置界面 settings/wowtype-config 改的是同样的键、同样的格式）。
//
// 设置窗口只写文件：输入法按键时（AppState.checkForChanges）看到文件变了自己重新读，下一次按键就生效。
// 改设置停 0.25 秒才写（拖数字时不要每一下都写），只写窗口里改过的键（WowtypeConfig.merged），
// 窗口开着时在文本编辑里改的、别的键不会被盖掉；切回窗口时文件变了就重新读。

import AppKit

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, input, emoji, words

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .input: return "输入"
        case .emoji: return "表情"
        case .words: return "自定义词"
        }
    }

    /// SF Symbols（macOS 11 起都有）
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .input: return "keyboard"
        case .emoji: return "face.smiling"
        case .words: return "book.closed"
        }
    }
}

struct SettingsToast: Identifiable {
    let id = UUID()
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
}

final class SettingsModel: ObservableObject {
    @Published var page: SettingsPage
    @Published var config: WowtypeConfig {
        didSet {
            if config != oldValue && !quiet {
                scheduleSave()
            }
        }
    }
    @Published private(set) var words: [CustomWords.Entry] = []
    @Published private(set) var toast: SettingsToast?

    // 「添加自定义词」的两个框：打词时自动填拼音，手改过编码就不再自动填（清空了又自动填）
    @Published var newWord = "" {
        didSet {
            if newWord != oldValue { wordChanged() }
        }
    }
    @Published var newCode = "" {
        didSet {
            if !quiet && newCode != oldValue { codeEdited = !newCode.trimmed.isEmpty }
        }
    }
    @Published var search = ""

    let configPath: String
    let customPath: String
    let supportDir: URL
    /// 安装包里的雾凇词库（猜拼音用；设置里换了词库就用换的那个）
    private let bundledLexicon: String?

    /// 文件里现在的设置（上次读或写的）：保存时只写 config 和它不一样的键
    private var saved: WowtypeConfig
    private var configStamp: FileStamp?
    private var customStamp: FileStamp?
    private var quiet = false
    private var codeEdited = false
    private var saveWork: DispatchWorkItem?
    private var guessWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private let guesser = PinyinGuesser()

    init(page: SettingsPage, state: AppState = .shared) {
        self.page = page
        configPath = state.configPath
        customPath = state.customWordsPath
        supportDir = state.supportDir
        bundledLexicon = state.resource("lexicon.tsv")
        configStamp = FileStamp(state.configPath)
        let loaded = WowtypeConfig.parse(readText(state.configPath) ?? "")
        saved = loaded
        config = loaded
        customStamp = FileStamp(state.customWordsPath)
        words = CustomWords(text: readText(state.customWordsPath)).entries
    }

    private func quietly(_ body: () -> Void) {
        let was = quiet
        quiet = true
        body()
        quiet = was
    }

    // MARK: 设置

    /// 切回窗口时：文件在别处改了（文本编辑、同步）就重新读。窗口里还没写的先写（只写改过的键，不会盖掉别处的）。
    func reload() {
        save()
        if FileStamp(configPath) != configStamp {
            configStamp = FileStamp(configPath)
            let loaded = WowtypeConfig.parse(readText(configPath) ?? "")
            saved = loaded
            quietly { config = loaded }
        }
        if FileStamp(customPath) != customStamp {
            customStamp = FileStamp(customPath)
            words = CustomWords(text: readText(customPath)).entries
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 马上写（关窗口、退出、用文本编辑打开之前）。
    func save() {
        saveWork?.cancel()
        saveWork = nil
        guard config != saved else { return }
        let out = config.merged(changesFrom: saved, into: readText(configPath))
        do {
            try writeText(out, to: configPath)
        } catch {
            showToast("保存失败：\(error.localizedDescription)")
            return
        }
        configStamp = FileStamp(configPath)
        let now = WowtypeConfig.parse(out)
        saved = now
        if now != config {
            quietly { config = now }
        }
    }

    /// 恢复默认设置：词库不动（和 Linux 一样），自定义词不受影响。
    func resetToDefaults() {
        var defaults = WowtypeConfig()
        defaults.lexicon = config.lexicon
        config = defaults
        save()
        showToast("已恢复默认设置")
    }

    /// 词库：设置里的文件在就用它，不然用安装包里的（和输入法的 AppState.lexiconPath 一样）。
    var customLexiconMissing: Bool {
        !config.lexicon.isEmpty && !isFile(expand(config.lexicon))
    }

    private var lexiconForGuess: String? {
        if !config.lexicon.isEmpty, isFile(expand(config.lexicon)) {
            return expand(config.lexicon)
        }
        return bundledLexicon
    }

    func chooseLexicon() {
        let panel = NSOpenPanel()
        panel.title = "选择词库文件"
        panel.message = "每行：拼音<TAB>词<TAB>频次，拼音用空格分开音节"
        panel.prompt = "使用"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !config.lexicon.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: expand(config.lexicon)).deletingLastPathComponent()
        }
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            self.config.lexicon = (url.path as NSString).abbreviatingWithTildeInPath
            self.showToast("换词库了，几秒后生效")
        }
    }

    // MARK: 自定义词

    var codeIsInvalid: Bool {
        !newCode.trimmed.isEmpty && CustomWords.normalizeCode(newCode) == nil
    }

    var canAddWord: Bool {
        CustomWords.isValidWord(newWord.trimmed) && CustomWords.normalizeCode(newCode) != nil
    }

    /// 我的词：后加的在前面，按词或编码搜（编码不管空格），最多列 500 个。
    var shownWords: [CustomWords.Entry] {
        let query = search.trimmed.lowercased()
        let compact = query.replacingOccurrences(of: " ", with: "")
        return Array(words.reversed().filter { entry in
            query.isEmpty || entry.word.lowercased().contains(query)
                || entry.code.replacingOccurrences(of: " ", with: "").contains(compact)
        }.prefix(500))
    }

    private func wordChanged() {
        guessWork?.cancel()
        guard !codeEdited else { return }
        let word = newWord.trimmed
        if word.isEmpty {
            quietly { newCode = "" }
            return
        }
        // 查词库要几十毫秒，打字停一下再查
        let lexicon = lexiconForGuess
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let guess = self.guesser.guess(word, lexicon: lexicon)
                DispatchQueue.main.async {
                    guard !self.codeEdited, self.newWord.trimmed == word else { return }
                    self.quietly { self.newCode = guess ?? "" }
                }
            }
        }
        guessWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 加词。成功返回 true（两个框清空）。
    @discardableResult
    func addWord() -> Bool {
        let word = newWord.trimmed
        if !codeEdited && newCode.trimmed.isEmpty && !word.isEmpty {
            // 还没来得及猜：现在猜
            guessWork?.cancel()
            quietly { newCode = guesser.guess(word, lexicon: lexiconForGuess) ?? "" }
        }
        guard CustomWords.isValidWord(word) else {
            if word.contains("\t") || word.contains("\n") {
                showToast("词里不能有 TAB 和换行，换行写成 \\n")
            }
            return false
        }
        guard let code = CustomWords.normalizeCode(newCode) else {
            showToast("编码不对：拼音用空格隔开音节（zhang san），或者只用字母（mail）")
            return false
        }
        var doc = readCustomWords()
        let replaced = doc.add(code: code, word: word)
        guard writeCustomWords(doc) else { return false }
        quietly {
            newWord = ""
            newCode = ""
        }
        codeEdited = false
        showToast(replaced ? "已更新「\(word)」" : "已添加「\(word)」，打 \(code.replacingOccurrences(of: " ", with: "")) 试试")
        return true
    }

    func removeWord(_ word: String) {
        var doc = readCustomWords()
        let removed = doc.remove(word: word)
        guard !removed.isEmpty, writeCustomWords(doc) else { return }
        showToast("已删除「\(word)」", actionTitle: "撤销") { [weak self] in
            guard let self else { return }
            var doc = self.readCustomWords()
            for entry in removed {
                doc.add(code: entry.code, word: entry.word)
            }
            self.writeCustomWords(doc)
        }
    }

    func importWords() {
        let panel = NSOpenPanel()
        panel.title = "导入自定义词"
        panel.message = "每行：编码<TAB>词（WowType 导出的文件、Linux 上的 custom.tsv 都行）"
        panel.prompt = "导入"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                self.showToast("读不了这个文件（要 UTF-8 文本）")
                return
            }
            let incoming = CustomWords.parseImport(text)
            guard !incoming.isEmpty else {
                self.showToast("文件里没有能用的词（每行：编码<TAB>词）")
                return
            }
            var doc = self.readCustomWords()
            let (added, updated) = doc.merge(incoming)
            guard self.writeCustomWords(doc) else { return }
            self.showToast("导入了 \(added) 个新词" + (updated > 0 ? "，更新 \(updated) 个" : ""))
        }
    }

    func exportWords() {
        let panel = NSSavePanel()
        panel.title = "导出自定义词"
        panel.nameFieldStringValue = "wowtype-custom-words.tsv"
        panel.prompt = "导出"
        present(panel) { [weak self] url in
            guard let self, let url else { return }
            let doc = self.readCustomWords()
            do {
                try doc.text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.showToast("导出失败：\(error.localizedDescription)")
                return
            }
            self.showToast("已导出 \(doc.entries.count) 个词到 \((url.path as NSString).abbreviatingWithTildeInPath)")
        }
    }

    /// 每次改之前重新读文件（窗口开着时文本编辑里改的不丢），改完马上写。
    private func readCustomWords() -> CustomWords {
        CustomWords(text: readText(customPath))
    }

    @discardableResult
    private func writeCustomWords(_ doc: CustomWords) -> Bool {
        do {
            try writeText(doc.text, to: customPath)
        } catch {
            showToast("保存失败：\(error.localizedDescription)")
            return false
        }
        customStamp = FileStamp(customPath)
        words = doc.entries
        return true
    }

    // MARK: 提示条

    func showToast(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        toastWork?.cancel()
        toast = SettingsToast(text: text, actionTitle: actionTitle, action: action)
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 3 : 6), execute: work)
    }

    func runToastAction() {
        let action = toast?.action
        toastWork?.cancel()
        toast = nil
        action?()
    }

    // MARK: 文件

    /// 打开、存文件的对话框：有窗口就挂在窗口上。
    private func present(_ panel: NSSavePanel, _ done: @escaping (URL?) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
        } else {
            done(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}

/// 读文本文件；不在是 nil。不是 UTF-8 也读出来（坏的字节换成 �），免得当成没有文件、整个重写。
func readText(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// 整个换掉（先写临时文件再改名）。文件是个链接（比如链到同步盘）时写链接指向的文件。
func writeText(_ text: String, to path: String) throws {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func expand(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

private func isFile(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
}

/// 从词库猜拼音：词库文件映射进内存（不占内存，几十毫秒查一次），换了词库换文件。
final class PinyinGuesser {
    private let lock = NSLock()
    private var path: String?
    private var data: Data?

    func guess(_ word: String, lexicon: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let lexicon, !word.isEmpty else { return nil }
        if path != lexicon {
            path = lexicon
            data = try? Data(contentsOf: URL(fileURLWithPath: lexicon), options: .alwaysMapped)
        }
        return data?.withUnsafeBytes { CustomWords.guessPinyin(word, lexicon: $0) }
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
