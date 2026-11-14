// 组字：按键交给核心的输入会话（wowtype_session_*），按会话给的结果更新编辑区、候选框、上屏。
//
// 不依赖 AppKit。输入法外壳实现 TextClient（IMK 的 client），按键测试用一个假的 TextClient。
//
// 会话（ABI 1.6 起）管打字途中的全部按键：字母、隔音符、退格、Esc、空格、回车、数字选词、
// 翻页、移光标、展开面板。候选框照 frame 的 cand_* 画（显示的就是这一页 / 面板的这一屏）。
// 还在外壳的（docs/PORTING.md 第 4 块挪进会话）：标点，以及打字途中按标点先上屏当前候选；
// v + 空格的工具栏和表情面板（Toolbar.swift）。
// 打字途中按 Control+Delete（Mac 键盘上的 Delete 是退格；有向前删除键或按 Fn+Control+Delete 也行）
// 忘掉光标处学错的词（ABI 1.7），也是会话管，外壳只在 frame->forgot 时马上存学习数据（onForget）。
//
// 互译（「译」，和 Linux 的 fcitx5 外壳一样）：上屏的字不交给应用，攒成原文（translateSource）显示在
// 候选框顶上；原文停下来 0.5 秒（句末标点立刻）发去翻译，译文边出边写在应用的编辑区里（带下划线）。
// 回车 / 空格上屏译文，Shift+回车上屏原文，Esc 清空。翻译器不阻塞：外壳收到 onTranslatePoll 以后
// 每 50 毫秒调一次 pollTranslation，直到它返回 false。

import CWowtype
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// 引擎：词库、语言模型、学习数据。一个进程一份，所有输入框共用。
public final class Engine {
    public let handle: OpaquePointer

    /// 翻页时一个音节的字要列全（yi 有八百多个字），候选上限给 1000。
    public static let maxCandidates: UInt32 = 1000

    public init?(lexicon: String, languageModel: String? = nil) {
        guard let handle = wowtype_engine_new(lexicon, languageModel) else {
            return nil
        }
        self.handle = handle
        wowtype_engine_set_max_candidates(handle, Engine.maxCandidates)
    }

    deinit {
        wowtype_engine_free(handle)
    }

    /// 英文词表；返回载入的词数，失败 -1。
    @discardableResult
    public func loadEnglish(_ path: String) -> Int {
        Int(wowtype_engine_load_english(handle, path))
    }

    @discardableResult
    public func loadUserDict(_ path: String) -> Int {
        Int(wowtype_engine_load_user_dict(handle, path))
    }

    @discardableResult
    public func saveUserDict(_ path: String) -> Bool {
        wowtype_engine_save_user_dict(handle, path) == 0
    }

    @discardableResult
    public func loadHistory(_ path: String) -> Int {
        Int(wowtype_engine_load_history(handle, path))
    }

    @discardableResult
    public func saveHistory(_ path: String) -> Bool {
        wowtype_engine_save_history(handle, path) == 0
    }

    /// 自定义词（custom.tsv）：替换上一次载入的，文件不存在就清空。返回条数，-1 出错。
    @discardableResult
    public func loadCustomWords(_ path: String) -> Int {
        Int(wowtype_engine_load_custom_words(handle, path))
    }

    /// 简繁对照表载入过没有（繁体输出要用，第一次打开繁体时才读）。
    public private(set) var conversionLoaded = false

    /// 设置里管引擎的部分（模糊音、纠错、双拼、生僻字、繁体），和 Linux 的 applyCoreSettings 一样。
    /// conversion 是简繁对照表 s2t.tsv 的路径，没有就不出繁体。返回要记日志的问题。
    @discardableResult
    public func apply(_ config: WowtypeConfig, conversion: String? = nil) -> [String] {
        var problems: [String] = []
        wowtype_engine_set_fuzzy(handle, config.fuzzy ? 1 : 0)
        wowtype_engine_set_fuzzy_groups(handle, config.fuzzyGroups)
        wowtype_engine_set_shuangpin(handle, config.shuangpin ? 1 : 0)
        if wowtype_engine_set_shuangpin_scheme(handle, config.shuangpinScheme) != 0 {
            problems.append("不认识双拼方案 \(config.shuangpinScheme)，用自然码")
            wowtype_engine_set_shuangpin_scheme(handle, "ziranma")
        }
        wowtype_engine_set_typo_correction(handle, config.typoCorrection ? 1 : 0)
        wowtype_engine_set_rare_ext_chars(handle, config.rareExtChars ? 1 : 0)
        if config.traditional && !conversionLoaded {
            if let conversion, wowtype_engine_load_conversion(handle, conversion) > 0 {
                conversionLoaded = true
            } else {
                problems.append("简繁表载入失败 \(conversion ?? "（没有 s2t.tsv）")")
            }
        }
        wowtype_engine_set_traditional(handle, config.traditional && conversionLoaded ? 1 : 0)
        return problems
    }

    public static var abiVersion: Int {
        Int(wowtype_abi_version())
    }
}

/// 候选框要画的东西（会话给的这一页，或展开面板的这一屏）。
public struct CandidatePage: Equatable {
    public var texts: [String]
    /// 光标在 texts 里的第几个；-1 不在这一页上（翻页翻走以后）
    public var cursor: Int
    public var hasPrev: Bool
    public var hasNext: Bool
    /// 展开面板（横排按下键）、表情面板：每行 columns 个，数字选光标所在行的第几个
    public var expanded: Bool
    /// 候选上方的一行提示（工具栏、表情面板用）；没有为 nil。texts 可以是空的，只画提示
    public var aux: String? = nil
    /// 竖排：一行一个（设置里 CandidateLayout=Vertical、工具栏）
    public var vertical = false
    /// 互译时候选上下多出来的两行；不在互译时 nil。互译时没有候选（只攒着原文）也画框
    public var translate: TranslatePanel? = nil
    public static let columns = 6
}

/// 互译时的候选框（Linux 上是 fcitx5 面板的 auxUp + 原文框、auxDown）。
public struct TranslatePanel: Equatable {
    /// 「中→英 互译：」
    public var title: String
    /// 原文：攒着的 + 正在打的（已选的词 + 还没选的拼音）
    public var source: String
    /// 最下面一行：翻译中、出错原因、怎么上屏；空串不画
    public var status: String
}

/// 外壳要实现的：往输入框里写字、画编辑区和候选框。
public protocol TextClient: AnyObject {
    /// 上屏（同时清掉编辑区）。
    func insertText(_ text: String)
    /// 编辑区（marked text）；空串表示清掉。cursor 是 UTF-16 偏移。
    func setMarkedText(_ text: String, cursor: Int)
    /// 画候选框；nil 表示收起。
    func showCandidates(_ page: CandidatePage?)
    /// 光标前一个字符（Unicode 码位），不知道给 0。数字后面的符号（3.14、20:22）要原样上屏。
    var previousCharacter: UInt32 { get }
    /// 能把打的字发去翻译。密码框之类（macOS 上是系统开着安全输入时）照常打中文，不往外发。
    var allowsTranslation: Bool { get }
    /// previousCharacter 是应用告诉的（不是外壳猜的）。中英文之间自动加空格只信应用告诉的，
    /// 和 Linux 一样：读不到光标前的文字就不猜。
    var previousCharacterIsReliable: Bool { get }
}

extension TextClient {
    public var previousCharacterIsReliable: Bool { true }
    public var allowsTranslation: Bool { true }
}

public final class Composer {
    public enum Mode: Equatable {
        case chinese
        case english
        /// 互译（「译」）：设置里打开了 Translate、翻译器配好了才切得到
        case translate
    }

    /// 原文停下来这么久才发请求（句末标点立刻发）
    public static let translateDelay = 0.5

    public private(set) var mode: Mode = .chinese
    /// 设置（wowtype.conf）里管会话和外壳的部分；管引擎的部分用 Engine.apply。
    public private(set) var config = WowtypeConfig()
    /// 一页几个候选
    public var pageSize: Int {
        get { config.pageSize }
        set { config.pageSize = newValue; configure() }
    }
    /// 候选横排（左右键移光标、上下键翻页、下键展开面板）；false 竖排（上下键移光标、左右键翻页）
    public var horizontal: Bool {
        get { config.horizontal }
        set { config.horizontal = newValue; configure() }
    }
    /// 0 全角中文标点，1 半角
    public var punctStyle: Int32 { config.halfwidthPunct ? 1 : 0 }

    let session: OpaquePointer
    private(set) var engine: Engine?
    private(set) weak var client: TextClient?
    private var shiftTap = ShiftTap()
    /// 最近上屏的字（给会话当上文排序），只留末尾一小段。
    private var recent = ""
    /// 每次上屏后调用（外壳用来定时保存学习数据）。
    public var onCommit: ((String) -> Void)?
    /// 每次真正上屏时调用（text, source, scheme, candidateIndex），给打字统计用；
    /// 只分类计数，不保存文字。candidateIndex 是选中的候选位置（1 起），0 表示不是选候选。
    public var onCommitStats: ((String, String, String, Int) -> Void)?
    /// 这次上屏来自第几个候选（1 起），上屏后取走。
    private var pendingCandidateIndex = 0
    /// Ctrl+Delete 忘掉了学错的词以后调用（外壳马上存学习数据，免得重启又回来）。
    public var onForget: (() -> Void)?
    /// 打开工具栏的剪贴板页时调用（设置里 ClipboardHistory 开着时）：外壳看一眼系统剪贴板，
    /// 有新的就交给 ClipboardHistory.remember。
    public var sampleClipboard: (() -> Void)?
    /// 最近用过的 emoji（表情面板里排最前）。
    public var recentEmoji = RecentEmoji.shared
    /// 开着的工具栏 / 表情面板（Toolbar.swift）；nil 是没开
    var tool: ToolState?

    // 互译
    /// 翻译器（一个进程一个，所有输入框共用）；nil 表示没有互译
    private var translator: TranslationBackend?
    /// 攒着的原文（还没上屏）
    public private(set) var translateSource = ""
    /// 编辑区里现在写着的译文（原文改了、新译文还没写到这么长时先留着，免得一闪一闪）
    private var translateShown = ""
    /// 按过回车 / 空格，等译好了就上屏
    private var translatePending = false
    /// 什么时候发请求（clock 的时间）；nil 不用发
    private var translateAt: Double?
    /// 现在画的是哪个结果（signature），结果变了才重画
    private var translateDrawn = ""
    /// 原文变了、在等译文：外壳开始每 50 毫秒调一次 pollTranslation（已经在调就不用管）。
    public var onTranslatePoll: (() -> Void)?
    /// 单调时钟（秒），测试里换成假的。
    public var clock: () -> Double = monotonicSeconds

    public init(engine: Engine?, client: TextClient) {
        self.engine = engine
        self.client = client
        session = wowtype_session_new(engine?.handle, nil)
        configure()
    }

    deinit {
        wowtype_session_free(session)
    }

    public var hasEngine: Bool { engine != nil }

    /// 现在用的引擎（外壳换了词库以后拿来比，换成新的）。
    public var currentEngine: Engine? { engine }

    public func setEngine(_ engine: Engine?) {
        guard engine !== self.engine else { return }
        if self.engine != nil && isComposing {
            // 换词库：编辑区、候选都是旧词库算的，清掉（和 Linux 一样）
            wowtype_session_reset(session, 0)
        }
        // 先让会话换上新的，再放掉旧的（旧引擎可能就此释放）
        wowtype_session_set_engine(session, engine?.handle)
        self.engine = engine
        refresh()
    }

    /// 换设置。Shift 切换关掉时回到中文；剪贴板历史关掉时马上清空；关掉了互译或者翻译器没配好时离开「译」（和 Linux 一样）。
    public func apply(_ config: WowtypeConfig) {
        self.config = config
        if config.shiftToggle == .off || (mode == .translate && !translateAvailable) {
            switchMode(to: .chinese)
        }
        if !config.clipboardHistory {
            ClipboardHistory.clear()
        }
        configure()
    }

    /// 换翻译器（外壳在设置里第一次打开互译时建）。
    public func setTranslator(_ translator: TranslationBackend?) {
        guard translator !== self.translator else { return }
        leaveTranslate()
        self.translator = translator
        if mode == .translate && !translateAvailable {
            mode = .chinese
        }
        refresh()
    }

    /// Shift 切得到「译」：设置里打开了互译，翻译器也配好了（填了服务，或者本地模型文件在）。
    public var translateAvailable: Bool {
        config.translate && translator?.isReady == true
    }

    /// 现在在「译」里，而且这个输入框能翻译（不是密码框）。
    public var translating: Bool {
        mode == .translate && translator != nil && client?.allowsTranslation == true
    }

    public func setClient(_ client: TextClient) {
        self.client = client
    }

    public var isComposing: Bool {
        guard let input = wowtype_session_input(session) else { return false }
        return input.pointee != 0
    }

    public var input: String {
        wowtype_session_input(session).map { String(cString: $0) } ?? ""
    }

    /// 已选的词连起来（选了句首的词、剩下的还在打）。
    var selectedText: String {
        wowtype_session_selected_text(session).map { String(cString: $0) } ?? ""
    }

    /// 还没选词的那部分输入。
    var remaining: String {
        wowtype_session_remaining(session).map { String(cString: $0) } ?? ""
    }

    /// 输入法手里还有没上屏的字：正在打的拼音，或者互译攒着的原文。
    public var hasPendingText: Bool {
        isComposing || !translateSource.isEmpty
    }

    // MARK: 按键

    /// 处理一次按下；返回 true 表示吃掉了这个键（不交给应用）。
    public func handle(_ key: KeyInput) -> Bool {
        if key.release {
            return false
        }
        shiftTap.interrupt()
        // 表情面板快捷键中英文都管；工具栏、表情面板开着时按键都归它们（和 Linux 一样）
        if let emojiKey = config.emojiKey, emojiKey.matches(key) {
            toggleEmojiPanel()
            return true
        }
        if tool != nil {
            return handleToolKey(key)
        }
        if !translateSource.isEmpty && !translating {
            // 「译」里攒着原文时输入框变成了不能翻译的（开了安全输入）：原文先原样上屏
            leaveTranslate()
            refresh()
        }
        // 互译、没在打拼音：回车上屏译文、退格删原文、数字和 / + 进原文……
        if translating && !isComposing && handleTranslateKey(key) {
            return true
        }
        if mode == .english {
            // 英文模式：按键原样交给应用；汉字后面打字母、数字要补空格时自己上屏
            return autoSpaceKey(key)
        }
        let composing = isComposing
        if engine == nil && !composing {
            // 词库还在后台载入：先什么都不吃，字母原样给应用
            return false
        }
        if !key.modifiers.isDisjoint(with: [.control, .option, .command]) {
            // 打字途中先问会话：Ctrl+Delete、Ctrl+退格忘掉光标处学错的词。
            // 别的快捷键交给应用，打到一半时编辑区留着
            return composing && sendToSession(key)
        }
        if !composing {
            return handleIdle(key)
        }
        return handleComposing(key)
    }

    /// Shift 的按下 / 松开（macOS 的 flagsChanged）。单按切中英文时返回 true。
    /// right 是右 Shift（设置里 ShiftToggle 可以只用一边，或者不用 Shift 切换）。
    @discardableResult
    public func shiftChanged(down: Bool, otherModifiers: Bool, now: Double, right: Bool = false) -> Bool {
        let allowed: Bool
        switch tool == nil ? config.shiftToggle : .off { // 工具栏、表情面板开着时不切
        case .both: allowed = true
        case .left: allowed = !right
        case .right: allowed = right
        case .off: allowed = false
        }
        guard allowed else {
            shiftTap.interrupt()
            return false
        }
        guard shiftTap.shift(down: down, otherModifiers: otherModifiers, now: now) else {
            return false
        }
        toggleMode()
        return true
    }

    /// 别的修饰键变了（Command、Option 等）：这次 Shift 不算单按。
    public func otherModifierChanged() {
        shiftTap.interrupt()
    }

    /// 单按 Shift：中 → 英 → 译 → 中（没配好互译时只在中英之间切），和 Linux 一样。
    public func toggleMode() {
        switch mode {
        case .chinese: switchMode(to: .english)
        case .english: switchMode(to: translateAvailable ? .translate : .chinese)
        case .translate: switchMode(to: .chinese)
        }
    }

    /// 切模式。打到一半切英文：已选的词 + 打的字母原样上屏（和微信输入法一样）；
    /// 离开「译」：攒着的原文原样上屏，正在打的拼音留着接着打。
    public func switchMode(to newMode: Mode) {
        let target = newMode == .translate && !translateAvailable ? Mode.chinese : newMode
        guard target != mode else { return }
        if mode == .translate {
            leaveTranslate()
        }
        if target == .english && isComposing {
            commitInput()
        }
        mode = target
        refresh()
    }

    /// 切走输入法、换输入框：打到一半的原样上屏（互译时拼音进原文，原文再原样上屏，和 Linux 一样），
    /// 工具栏、表情面板收起来。
    public func commitComposition() {
        closeTool()
        if isComposing {
            commitInput()
        }
        if !translateSource.isEmpty {
            commitTranslateSource()
        }
    }

    /// 放弃正在打的（输入框失去焦点）：拼音和互译攒着的原文都丢掉。
    public func cancel() {
        tool = nil
        clearTranslation()
        apply(wowtype_session_reset(session, 0))
    }

    /// 点候选框里显示的第 index 个（和按数字键一样）。
    public func select(_ index: Int) {
        if let tool {
            // 工具栏一页 9 个、表情面板一屏 36 个，index 是这一页 / 这一屏里的
            let size = tool.panel.isEmoji ? CandidatePage.columns * ToolLimits.gridRows : ToolLimits.pageSize
            selectTool(tool.cursor / size * size + index)
            return
        }
        guard index >= 0, let frame = wowtype_session_select(session, index), frame.pointee.handled != 0 else {
            return
        }
        apply(frame)
    }

    // MARK: 内部

    private func configure() {
        var config = WowtypeSessionConfig()
        let settings = self.config
        config.size = UInt32(MemoryLayout<WowtypeSessionConfig>.size)
        config.page_size = UInt32(max(settings.pageSize, 1))
        config.calculator = settings.calculator ? 1 : 0
        config.date_time = settings.dateTime ? 1 : 0
        config.emoji_suggest = settings.emojiSuggest ? 1 : 0
        config.horizontal = settings.horizontal ? 1 : 0
        config.page_keys = settings.pageKeys
        config.select_keys = settings.selectKeysValue
        config.pick_char = settings.pickChar ? 1 : 0
        wowtype_session_configure(session, &config)
        if isComposing {
            refresh()
        }
    }

    private func handleIdle(_ key: KeyInput) -> Bool {
        guard let c = key.ascii else {
            return false
        }
        if key.isLetter {
            // 大小写字母都开始编辑区（和 Linux 一样）：大写原样保留，Hello、iPhone 出英文候选
            return sendToSession(key)
        }
        if key.isDigit {
            // 数字交给应用；汉字后面要补空格时自己上屏（第 5 章）
            return autoSpaceKey(key)
        }
        if let text = punctuation(for: c) {
            insert(text)
            return true
        }
        return false
    }

    private func handleComposing(_ key: KeyInput) -> Bool {
        if opensToolbar(key) {
            return true
        }
        if sendToSession(key) {
            return true
        }
        // 会话不管的键。展开面板里按了这种键，会话已经把面板收起来了，先重画
        refresh()
        guard let c = key.ascii, c > 0x20, c < 0x7f, c != 0x27 else {
            // 其他功能键（Tab、Home 等）打字途中吃掉，免得光标跑到别处
            return true
        }
        // 打字途中按标点、其他可见字符（/ + 等）：先上屏当前候选（光标停在句首词上时，
        // 选完它还剩半句，接着选第一个候选，直到整句上屏），再上屏标点或这个字符
        for _ in 0..<16 where isComposing {
            commitCurrent()
        }
        insert(punctuation(for: c) ?? String(UnicodeScalar(c)))
        return true
    }

    /// 没在打拼音时 ' 是单引号（‘ ’ 交替）；打拼音途中它是隔音符，进不到这里。
    /// 引号左右交替的状态在核心里，所以一个键只能调一次 wowtype_punct。
    private func punctuation(for c: UInt8) -> String? {
        guard wowtype_fullwidth_punct(Int32(c)) != nil else {
            return nil
        }
        guard let text = wowtype_punct(Int32(c), punctStyle, Int32(bitPattern: previousCharacter)) else {
            return String(UnicodeScalar(c))
        }
        return String(cString: text)
    }

    /// 光标前一个字：互译时是攒着的原文的最后一个字（3.14 的点、20:22 的冒号要原样进原文）。
    private var previousCharacter: UInt32 {
        if translating, let last = translateSource.unicodeScalars.last {
            return last.value
        }
        return client?.previousCharacter ?? 0
    }

    @discardableResult
    private func sendToSession(_ key: KeyInput) -> Bool {
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.keysym = key.keysym
        raw.modifiers = key.modifiers.rawValue
        raw.release = key.release ? 1 : 0
        raw.prev_char = previousCharacter
        guard let frame = wowtype_session_key(session, &raw) else {
            return false
        }
        let handled = frame.pointee.handled != 0
        if handled {
            apply(frame)
        }
        return handled
    }

    /// 和按空格一样：上屏光标处的候选，没有候选时上屏原始输入。
    private func commitCurrent() {
        sendToSession(.char(" "))
    }

    func commitInput() {
        // 回车：已选的词 + 剩下的字母原样上屏（会话会记选词）
        apply(wowtype_session_reset(session, 1))
    }

    /// 按会话给的 frame 上屏、更新编辑区和候选框。
    private func apply(_ frame: UnsafePointer<WowtypeFrame>?) {
        if let frame, let commit = frame.pointee.commit {
            insert(String(cString: commit))
            // 选的是打字推荐的 emoji：记进最近用过（表情面板里排最前）
            var info = WowtypeCandidateInfo()
            info.size = UInt32(MemoryLayout<WowtypeCandidateInfo>.size)
            if wowtype_session_last_choice(session, &info) == 0 {
                pendingCandidateIndex = Int(info.index)
                if info.kind == WOWTYPE_CAND_EMOJI, let emoji = info.emoji {
                    recentEmoji.remember(String(cString: emoji))
                }
            }
        }
        if let frame, Int(frame.pointee.size) >= MemoryLayout<WowtypeFrame>.size, frame.pointee.forgot != 0 {
            onForget?()
        }
        refresh()
    }

    /// 汉字和字母、数字之间要不要补一个空格（设置里的 AutoSpace，只看这一处边界）。
    private func needsAutoSpace(before next: String) -> Bool {
        let flags = config.autoSpaceFlags
        guard flags != 0, let client, let first = next.unicodeScalars.first,
              client.previousCharacterIsReliable
        else {
            return false
        }
        let prev = client.previousCharacter
        return prev != 0 && wowtype_autospace(Int32(bitPattern: prev), Int32(bitPattern: first.value), flags) == 1
    }

    /// 英文模式、没在打字时直接打的字母和数字：要补空格就连空格一起上屏，吃掉这个键。
    private func autoSpaceKey(_ key: KeyInput) -> Bool {
        guard key.modifiers.isDisjoint(with: [.control, .option, .command]),
              key.isLetter || key.isDigit, let c = key.ascii
        else {
            return false
        }
        let text = String(UnicodeScalar(c))
        guard needsAutoSpace(before: text) else {
            return false
        }
        client?.insertText(" " + text)
        onCommitStats?(text, statsSource, statsScheme, 0)
        return true
    }

    /// 上屏：交给应用（要补空格时带上空格）；互译时进原文。
    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        if translating {
            translateSource += text
            translateSourceChanged(now: endsSentence(text))
            refresh()
        } else {
            client?.insertText(needsAutoSpace(before: text) ? " " + text : text)
            onCommitStats?(text, statsSource, statsScheme, takeCandidateIndex())
        }
        recent = String((recent + text).suffix(20))
        wowtype_session_set_context(session, recent)
        onCommit?(text)
    }

    /// 统计用的输入模式：互译 / 英文 / 双拼 / 全拼。
    private var statsSource: String {
        if mode == .translate { return "translate" }
        if mode == .english { return "english" }
        return config.shuangpin ? "shuangpin" : "quanpin"
    }

    /// 双拼方案在统计里的名字（小写）；不是双拼时为空。
    private var statsScheme: String {
        config.shuangpin ? config.shuangpinScheme.lowercased() : ""
    }

    private func takeCandidateIndex() -> Int {
        let index = pendingCandidateIndex
        pendingCandidateIndex = 0
        return index
    }

    func refresh() {
        if let tool {
            drawTool(tool)
            return
        }
        let frame = isComposing ? wowtype_session_frame(session) : nil
        if translating && (frame != nil || !translateSource.isEmpty) {
            refreshTranslate(frame)
            return
        }
        guard let frame else {
            client?.setMarkedText("", cursor: 0)
            client?.showCandidates(nil)
            return
        }
        let f = frame.pointee
        let preedit = String(cString: f.preedit)
        client?.setMarkedText(preedit, cursor: utf16Offset(preedit, byteOffset: Int(f.preedit_cursor)))
        client?.showCandidates(candidatePage(frame))
    }

    /// 会话这一页 / 展开面板这一屏的候选；没有候选是 nil。
    private func candidatePage(_ frame: UnsafePointer<WowtypeFrame>) -> CandidatePage? {
        let f = frame.pointee
        // 只读显示的这些：候选可能有上千个
        var texts: [String] = []
        texts.reserveCapacity(f.cand_count)
        for i in 0..<f.cand_count {
            if let text = wowtype_session_candidate(session, i) {
                texts.append(String(cString: text))
            }
        }
        guard !texts.isEmpty else { return nil }
        return CandidatePage(texts: texts, cursor: Int(f.cand_cursor), hasPrev: f.has_prev != 0,
                             hasNext: f.has_next != 0, expanded: f.panel == 1, vertical: !config.horizontal)
    }

    // MARK: 互译

    /// 互译、没在打拼音时的键（Linux 的 handleTranslateKey）。返回 true 表示吃掉了。
    private func handleTranslateKey(_ key: KeyInput) -> Bool {
        guard key.modifiers.isDisjoint(with: [.control, .option, .command]) else {
            return false
        }
        if !translateSource.isEmpty {
            switch key.keysym {
            case Keysym.returnKey, Keysym.keypadEnter:
                if key.modifiers.contains(.shift) {
                    commitTranslateSource()
                } else {
                    commitTranslation()
                }
                return true
            case 0x20:
                commitTranslation()
                return true
            case Keysym.escape:
                clearTranslation()
                refresh()
                return true
            case Keysym.backspace:
                translateSource.removeLast()
                translateSourceChanged(now: false)
                refresh()
                return true
            case Keysym.left, Keysym.right, Keysym.up, Keysym.down, Keysym.home, Keysym.end,
                 Keysym.pageUp, Keysym.pageDown, Keysym.tab, Keysym.delete:
                // 原文里没有光标，别让应用里的光标乱跑
                return true
            default:
                break
            }
        }
        // 数字和没有中文写法的符号（/ + = 等）平时直接交给应用；互译时要进原文，免得插到前面
        guard let c = key.ascii, c > 0x20, !key.isLetter, wowtype_fullwidth_punct(Int32(c)) == nil else {
            return false
        }
        insert(String(UnicodeScalar(c)))
        return true
    }

    /// 原文变了：停 0.5 秒（now 立刻）再发请求，外壳开始轮询。
    private func translateSourceChanged(now: Bool) {
        translatePending = false
        guard !translateSource.isEmpty else {
            clearTranslation()
            return
        }
        translator?.owner = self
        translateAt = clock() + (now ? 0 : Composer.translateDelay)
        onTranslatePoll?()
    }

    private func clearTranslation() {
        translateSource = ""
        translateShown = ""
        translatePending = false
        translateAt = nil
        translateDrawn = ""
        if let translator, translator.owner === self {
            translator.cancel()
            translator.owner = nil
        }
    }

    /// 离开「译」：攒着的原文原样上屏。
    private func leaveTranslate() {
        guard !translateSource.isEmpty else {
            clearTranslation()
            return
        }
        let source = translateSource
        clearTranslation()
        client?.insertText(source)
        onCommitStats?(source, "translate", statsScheme, 0)
    }

    /// 外壳每 50 毫秒调一次：到时间就发请求，结果变了就重画，按过回车的译好了就上屏。
    /// 返回 false 表示不用再调了（下一次原文变了会再叫 onTranslatePoll）。
    @discardableResult
    public func pollTranslation() -> Bool {
        guard let translator else {
            translateAt = nil
            return false
        }
        if translateSource.isEmpty {
            translateAt = nil
            if translator.owner === self {
                translator.cancel()
                translator.owner = nil
            }
            return false
        }
        if let at = translateAt, clock() >= at {
            translateAt = nil
            translator.owner = self
            translator.start(translateSource)
        }
        let snapshot = translator.poll()
        let fresh = translateSource == snapshot.source
        if fresh && snapshot.phase == .error && translatePending {
            // 出错了就不等了：错误写在候选框底下，回车重试
            translatePending = false
        }
        if translatePending && fresh && snapshot.phase == .done {
            commitTranslation()
            return false
        }
        // 结果变了才重画；正在打拼音时候选列表（和翻到的页、光标）不动
        if translateSignature(snapshot) != translateDrawn {
            refresh()
        }
        return translateAt != nil || snapshot.phase == .running || translatePending
    }

    private func translateSignature(_ snapshot: TranslateSnapshot) -> String {
        let fresh = translateSource == snapshot.source
        var out = "\(fresh ? "\(snapshot.phase)" : "-")|\(translatePending)|\(translateSource)"
        if fresh {
            out += "|" + snapshot.text
            if snapshot.phase == .error {
                out += "|" + snapshot.error
            }
        }
        return out
    }

    /// 回车 / 空格：译好了就上屏译文；还没译好（或出错了，回车就是重试）记下来，好了再上屏。
    private func commitTranslation() {
        guard let translator, !translateSource.isEmpty else { return }
        let snapshot = translator.poll()
        let fresh = translateSource == snapshot.source
        if fresh && snapshot.phase == .done {
            let text = snapshot.text
            clearTranslation()
            client?.insertText(text)
            onCommitStats?(text, "translate", statsScheme, 0)
            refresh()
            return
        }
        translatePending = true
        translator.owner = self
        if !fresh || snapshot.phase == .error || snapshot.phase == .idle {
            translator.start(translateSource)
            translateAt = nil
        }
        onTranslatePoll?()
        refresh()
    }

    /// Shift+回车：原文原样上屏。
    private func commitTranslateSource() {
        guard !translateSource.isEmpty else { return }
        let source = translateSource
        clearTranslation()
        client?.insertText(source)
        onCommitStats?(source, "translate", statsScheme, 0)
        refresh()
    }

    /// 互译时画编辑区和候选框（Linux 的 fillTranslateView）：编辑区里是译文，
    /// 候选框顶上是「中→英 互译：」+ 原文 + 正在打的拼音，底下是状态。
    private func refreshTranslate(_ frame: UnsafePointer<WowtypeFrame>?) {
        guard let translator else { return }
        let snapshot = translator.poll()
        let fresh = !translateSource.isEmpty && translateSource == snapshot.source
        let failed = fresh && snapshot.phase == .error
        let done = fresh && snapshot.phase == .done
        let text = fresh && !failed ? snapshot.text : ""
        translateDrawn = translateSignature(snapshot)

        // 编辑区里的译文：原文改了、新译文还没写到上一句那么长时先留着上一句
        if translateSource.isEmpty || failed {
            translateShown = ""
        } else if done || text.utf8.count >= translateShown.utf8.count {
            translateShown = text
        }

        var box = translateSource
        if let frame {
            box += String(cString: frame.pointee.preedit)
        }
        let status: String
        if failed {
            status = snapshot.error + "（回车重试）"
        } else if translatePending {
            status = "翻译中…好了就上屏"
        } else if !translateSource.isEmpty && !done {
            status = "翻译中…"
        } else if !translateSource.isEmpty && frame == nil {
            status = "回车上屏 · Shift+回车上屏原文 · Esc 清空"
        } else {
            status = ""
        }
        client?.setMarkedText(translateShown, cursor: translateShown.utf16.count)
        var page = frame.flatMap(candidatePage)
            ?? CandidatePage(texts: [], cursor: -1, hasPrev: false, hasNext: false, expanded: false)
        page.translate = TranslatePanel(title: translator.tag(for: translateSource) + " 互译：",
                                        source: box, status: status)
        client?.showCandidates(page)
    }

    /// 候选（全部，不分页），测试用。
    public func allCandidates() -> [String] {
        var out: [String] = []
        for i in 0..<Int(wowtype_session_candidate_total(session)) {
            var info = WowtypeCandidateInfo()
            info.size = UInt32(MemoryLayout<WowtypeCandidateInfo>.size)
            if wowtype_session_candidate_info(session, i, &info) == 0, let text = info.text {
                out.append(String(cString: text))
            }
        }
        return out
    }
}

/// 这段文字以句末标点（或换行）结尾：一句话多半打完了，马上翻译。
func endsSentence(_ text: String) -> Bool {
    ["。", "！", "？", "…", ".", "!", "?", "\n"].contains { text.hasSuffix($0) }
}

/// 单调时钟（秒）。
public func monotonicSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

/// UTF-8 字节偏移 → UTF-16 偏移（IMK 的 selectionRange 用 UTF-16）。
func utf16Offset(_ text: String, byteOffset: Int) -> Int {
    let utf8 = text.utf8
    let clamped = max(0, min(byteOffset, utf8.count))
    let index = utf8.index(utf8.startIndex, offsetBy: clamped)
    return text.utf16.distance(from: text.utf16.startIndex, to: index.samePosition(in: text.utf16) ?? text.utf16.endIndex)
}
