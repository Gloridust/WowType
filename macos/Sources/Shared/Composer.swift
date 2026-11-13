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

    /// 混上领域词级模型（用户自己训的 words.domain.lm），nil 去掉；再调一次是换掉上一个。
    @discardableResult
    public func setDomainLM(_ path: String?) -> Bool {
        wowtype_engine_set_domain_lm(handle, path) == 0
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

    /// 输入模式由会话管（单按 Shift 的判断也在会话里）。
    public var mode: Mode {
        switch wowtype_session_mode(session) {
        case WOWTYPE_MODE_ENGLISH: return .english
        case WOWTYPE_MODE_TRANSLATE: return .translate
        default: return .chinese
        }
    }
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
    /// 上屏里有引擎学到的选词时调用（frame->learned；外壳攒够次数存一次学习数据）。
    /// 只上屏了标点、emoji、计算结果的不调。
    public var onCommit: ((String) -> Void)?
    /// Ctrl+Delete 忘掉了学错的词以后调用（外壳马上存学习数据，免得重启又回来）。
    public var onForget: (() -> Void)?
    /// 打开工具栏的剪贴板页时调用（设置里 ClipboardHistory 开着时）：外壳看一眼系统剪贴板，
    /// 有新的就交给 ClipboardHistory.remember。
    public var sampleClipboard: (() -> Void)?
    /// 最近用过的 emoji（表情面板里排最前）。
    /// 最近用过的 emoji（在核心里，一个进程一份）；测试里换一个只在内存里的
    public var recentEmoji = RecentEmoji.shared
    /// 开着的工具栏 / 表情面板（Toolbar.swift）；nil 是没开

    // 互译：攒原文、去抖、回车等译完、离开「译」上屏原文都在会话里，这里只画和排定时器
    /// 翻译器（一个进程一个，所有输入框共用）；nil 表示没有互译
    private var translator: TranslationBackend?
    /// 交给会话的函数表背后的对象（会话借用它，换翻译器时先让会话换掉再放）
    private var translateBridge: TranslateBridge?
    /// 攒着的原文（还没上屏）
    public var translateSource: String {
        String(cString: wowtype_session_translate_source(session))
    }
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

    /// 换设置。Shift 切换关掉、也没另设切换键时回到中文（切不回来了）；剪贴板历史关掉时马上清空；关掉了互译或者翻译器没配好时离开「译」（和 Linux 一样）。
    public func apply(_ config: WowtypeConfig) {
        self.config = config
        let noWayBack = config.shiftToggle == .off && config.toggleKey == nil
        if noWayBack || (mode == .translate && !translateAvailable) {
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
        // 换翻译器前攒着的原文原样上屏（会话换翻译器时会丢掉原文）
        let source = translateSource
        if !source.isEmpty {
            client?.insertText(source)
        }
        self.translator = translator
        let bridge = translator.map(TranslateBridge.init)
        if var table = bridge?.table {
            wowtype_session_set_translate_backend(session, &table)
        } else {
            wowtype_session_set_translate_backend(session, nil)
        }
        translateBridge = bridge
        configure()
        if mode == .translate && !translateAvailable {
            apply(wowtype_session_set_mode(session, WOWTYPE_MODE_CHINESE))
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
        // 先报给会话：按住 Shift 时按了别的键，这一下就不算单按（下面有的键不交给会话）
        observe(key)
        // 表情面板快捷键中英文都管；工具栏、表情面板开着时按键都归它们（和 Linux 一样）
        if let emojiKey = config.emojiKey, emojiKey.matches(key) {
            toggleEmojiPanel()
            return true
        }
        if openPanel != nil {
            return handleToolKey(key)
        }
        if let toggleKey = config.toggleKey, toggleKey.matches(key) {
            // 另设的切换键：中 ↔ 英；在「译」里按回中文
            switchMode(to: mode == .chinese ? .english : .chinese)
            return true
        }
        // 互译、没在打拼音：回车上屏译文、Shift+回车上屏原文、Esc 清空、退格删原文、数字和符号进原文……
        // 都由会话处理（「译」里攒着原文时输入框变成了不能翻译的，会话先把原文原样上屏）
        if mode == .translate && !isComposing
            && key.modifiers.isDisjoint(with: [.control, .option, .command]) {
            return sendToSession(key)
        }
        if mode == .english {
            // 英文模式：按键原样交给应用；汉字后面打字母、数字要补空格时会话连空格一起上屏
            return sendToSession(key)
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
    /// 判断在会话里（和 Linux 同一套规矩）：中间按了别的键、按住超过 0.5 秒、按下时带着别的修饰键、
    /// 工具栏或表情面板开着都不算。
    @discardableResult
    public func shiftChanged(down: Bool, otherModifiers: Bool, now: Double, right: Bool = false) -> Bool {
        configure() // 翻译器可能刚配好（本地模型下载完）：「译」这一档跟着
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.keysym = right ? 0xffe2 : 0xffe1
        raw.release = down ? 0 : 1
        raw.modifiers = otherModifiers ? Modifiers.control.rawValue : 0
        raw.time_ms = UInt64(max(now, 0) * 1000)
        guard let frame = wowtype_session_key(session, &raw), frame.pointee.mode_changed != 0 else {
            return false
        }
        // 打到一半切英文：会话把已选的词 + 打的字母放进了 frame；离开「译」时是攒着的原文
        apply(frame)
        return true
    }

    /// 别的修饰键变了（Command、Option 等）：这次 Shift 不算单按。
    public func otherModifierChanged() {
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.action = UInt32(WOWTYPE_KEY_ACTION_OBSERVE)
        wowtype_session_key(session, &raw)
    }

    /// 告诉会话有这个键（只用来打断单按 Shift，不处理）。
    private func observe(_ key: KeyInput) {
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.keysym = key.keysym
        raw.modifiers = key.modifiers.rawValue
        raw.action = UInt32(WOWTYPE_KEY_ACTION_OBSERVE)
        wowtype_session_key(session, &raw)
    }

    /// 单按 Shift：中 → 英 → 译 → 中（没配好互译时只在中英之间切），和 Linux 一样。
    public func toggleMode() {
        switch mode {
        case .chinese: switchMode(to: .english)
        case .english: switchMode(to: translateAvailable ? .translate : .chinese)
        case .translate: switchMode(to: .chinese)
        }
    }

    /// 切模式。打到一半切英文：已选的词 + 打的字母原样上屏（会话做，和微信输入法一样）；
    /// 离开「译」：攒着的原文原样上屏，正在打的拼音留着接着打。
    public func switchMode(to newMode: Mode) {
        let target = newMode == .translate && !translateAvailable ? Mode.chinese : newMode
        guard target != mode else { return }
        let raw: Int32
        switch target {
        case .chinese: raw = WOWTYPE_MODE_CHINESE
        case .english: raw = WOWTYPE_MODE_ENGLISH
        case .translate: raw = WOWTYPE_MODE_TRANSLATE
        }
        apply(wowtype_session_set_mode(session, raw))
    }

    /// 切走输入法、换输入框：打到一半的原样上屏（互译时拼音进原文，原文再原样上屏，和 Linux 一样），
    /// 工具栏、表情面板收起来。
    public func commitComposition() {
        closeTool()
        // 互译时拼音先进原文，攒着的原文再原样上屏（会话做）
        if isComposing || !translateSource.isEmpty {
            apply(wowtype_session_reset(session, 1))
        }
    }

    /// 放弃正在打的（输入框失去焦点）：拼音和互译攒着的原文都丢掉。
    public func cancel() {
        closeTool()
        translateDrawn = ""
        wowtype_session_translate_clear(session)
        apply(wowtype_session_reset(session, 0))
    }

    /// 点候选框里显示的第 index 个（和按数字键一样）。
    public func select(_ index: Int) {
        // 工具栏 / 表情面板开着时选的是面板这一页 / 这一屏里的第 index 项（会话认）
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
        config.arrow_keys = settings.arrowKeysValue
        config.page_keys = settings.pageKeys
        config.select_keys = settings.selectKeysValue
        config.pick_char = settings.pickChar ? 1 : 0
        config.punct_style = settings.halfwidthPunct ? 1 : 0
        config.auto_space = UInt32(bitPattern: settings.autoSpaceFlags)
        switch settings.shiftToggle {
        case .both: config.shift_toggle = WOWTYPE_SHIFT_TOGGLE_BOTH
        case .left: config.shift_toggle = WOWTYPE_SHIFT_TOGGLE_LEFT
        case .right: config.shift_toggle = WOWTYPE_SHIFT_TOGGLE_RIGHT
        case .off: config.shift_toggle = WOWTYPE_SHIFT_TOGGLE_OFF
        }
        config.translate_mode = translateAvailable ? 1 : 0
        config.toolbar = settings.toolbar ? 1 : 0
        config.clipboard_history = settings.clipboardHistory ? 1 : 0
        config.shuangpin_keys = settings.shuangpinShowKeys ? 1 : 0
        wowtype_session_configure(session, &config)
        if isComposing {
            refresh()
        }
    }

    private func handleIdle(_ key: KeyInput) -> Bool {
        guard let c = key.ascii else {
            return false
        }
        guard c > 0x20, c < 0x7f else {
            return false
        }
        // 都交给会话：字母开始编辑区（大写原样保留，Hello、iPhone 出英文候选）；
        // 标点换成中文标点（半角样式、数字后面的、没有中文写法的交给应用）；
        // 汉字后面打数字要补空格时会话自己上屏（第 5 章）
        if sendToSession(key) {
            return true
        }
        // 互译时打的字都要进原文：会话交给应用的（数字后面的点 3.14、半角标点）原样进原文
        if translating && !key.isLetter {
            insert(String(UnicodeScalar(c)))
            return true
        }
        return false
    }

    private func handleComposing(_ key: KeyInput) -> Bool {
        if key.keysym == 0x20 && input == "v" && config.clipboardHistory {
            // 只打一个 v 再按空格打开工具栏（会话做）：剪贴板页要的历史先读一次
            sampleClipboard?()
        }
        if sendToSession(key) {
            return true
        }
        // 会话不管的键（标点、符号也是会话处理：先上屏候选再上屏标点）。展开面板里按了这种键，
        // 会话已经把面板收起来了，先重画；其他功能键（Tab、Home 等）打字途中吃掉，免得光标跑到别处
        refresh()
        return true
    }

    /// 光标前一个字：互译时是攒着的原文的最后一个字（3.14 的点、20:22 的冒号要原样进原文）。
    private var previousCharacter: UInt32 {
        if translating, let last = translateSource.unicodeScalars.last {
            return last.value
        }
        return client?.previousCharacter ?? 0
    }

    @discardableResult
    func sendToSession(_ key: KeyInput) -> Bool {
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.keysym = key.keysym
        raw.modifiers = key.modifiers.rawValue
        raw.release = key.release ? 1 : 0
        raw.time_ms = UInt64(max(clock(), 0) * 1000)
        if mode == .translate && client?.allowsTranslation != true {
            // 密码框（安全输入）：「译」里也照常上屏，不往外发
            raw.hints |= WOWTYPE_KEY_HINT_NO_TRANSLATE
        }
        if translating {
            // 互译时上屏的字进原文：光标前的字是原文的最后一个字（3.14 的点、20:22 的冒号原样进原文），不补空格
            raw.prev_char = previousCharacter
            raw.hints |= WOWTYPE_KEY_HINT_NO_AUTO_SPACE
        } else {
            // 应用告诉的才给（自己猜的给 0）：会话按它决定要不要补空格；数字后面的标点它自己也记
            raw.prev_char = client.map { $0.previousCharacterIsReliable ? $0.previousCharacter : 0 } ?? 0
        }
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
    func apply(_ frame: UnsafePointer<WowtypeFrame>?) {
        if let frame, let commit = frame.pointee.commit {
            // 会话已经补好了空格（insert 不再补）；互译时进原文
            let text = String(cString: commit)
            insert(text, spaced: true)
            if frame.pointee.learned != 0 {
                onCommit?(text)
            }
            // 选了 emoji（打字推荐的、表情面板的）会话记进最近用过
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

    /// 上屏：交给应用（要补空格时带上空格；spaced：会话上屏的已经补过了）；互译时进原文。
    /// 上文由会话自己记；存学习数据的回调只在会话上屏学到的词时调（见 apply）。
    func insert(_ text: String, spaced: Bool = false) {
        guard !text.isEmpty else { return }
        if spaced {
            // 会话上屏的（补好了空格；互译时是译文、原文）
            client?.insertText(text)
        } else if translating {
            // 工具栏、表情面板上屏的：互译时交给会话攒进原文
            apply(wowtype_session_commit_text(session, text, 0))
        } else {
            client?.insertText(needsAutoSpace(before: text) ? " " + text : text)
        }
    }

    func refresh() {
        if openPanel != nil {
            drawTool()
            return
        }
        if translating, let all = wowtype_session_frame(session), all.pointee.translating != 0,
           isComposing || !translateSource.isEmpty {
            refreshTranslate(all)
            return
        }
        let frame = isComposing ? wowtype_session_frame(session) : nil
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

    /// 外壳每 50 毫秒调一次（会话的 wake_after_ms）：到时间就发请求，按过回车的译好了就上屏，
    /// 结果变了就重画。返回 false 表示不用再调了（下一次原文变了会再叫 onTranslatePoll）。
    @discardableResult
    public func pollTranslation() -> Bool {
        guard let frame = wowtype_session_tick(session, UInt64(max(clock(), 0) * 1000)) else {
            return false
        }
        if frame.pointee.commit != nil {
            // 按过回车，译好了：上屏译文（正在打的拼音留着）
            translateDrawn = ""
            apply(frame)
        } else if frame.pointee.translating != 0 && translateSignature(frame) != translateDrawn {
            // 结果变了才重画；正在打拼音时候选列表（和翻到的页、光标）不动
            refresh()
        }
        return frame.pointee.wake_after_ms > 0
    }

    private func translateSignature(_ frame: UnsafePointer<WowtypeFrame>) -> String {
        let f = frame.pointee
        return [f.translate_source, f.translate_text, f.translate_status, f.translate_title]
            .map { String(cString: $0) }.joined(separator: "|") + "|\(f.translate_done)"
    }

    /// 互译时画编辑区和候选框（Linux 的 fillTranslateView）：编辑区里是译文，
    /// 候选框顶上是「中→英 互译：」+ 原文 + 正在打的拼音，底下是状态。内容都是会话给的。
    private func refreshTranslate(_ frame: UnsafePointer<WowtypeFrame>) {
        let f = frame.pointee
        translateDrawn = translateSignature(frame)
        if f.wake_after_ms > 0 {
            onTranslatePoll?()
        }
        let shown = String(cString: f.translate_text)
        var box = String(cString: f.translate_source)
        if isComposing {
            box += String(cString: f.preedit)
        }
        client?.setMarkedText(shown, cursor: shown.utf16.count)
        var page = (isComposing ? candidatePage(frame) : nil)
            ?? CandidatePage(texts: [], cursor: -1, hasPrev: false, hasNext: false, expanded: false)
        page.translate = TranslatePanel(title: String(cString: f.translate_title), source: box,
                                        status: String(cString: f.translate_status))
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
