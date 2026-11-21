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

    /// 在后台存用户词库、输入习惯（ABI 1.11）：只抄一份数据就返回，写文件（两次 fsync）在核心的存盘线程上。
    /// 返回交出去了没有。
    @discardableResult
    public func saveUserDictAsync(_ path: String) -> Bool {
        wowtype_engine_save_user_dict_async(handle, path) == 0
    }

    @discardableResult
    public func saveHistoryAsync(_ path: String) -> Bool {
        wowtype_engine_save_history_async(handle, path) == 0
    }

    /// 等后台存盘写完：timeout 秒，nil 一直等，0 只看一眼。返回 nil 是都写完了（或者还在写、等不到 timeout）、
    /// 上次问过以后交的都写成了；写失败了返回原因（只报一次）。
    public func waitSaved(timeout: Double? = nil) -> String? {
        let ms = timeout.map { Int32(max(0, min($0 * 1000, Double(Int32.max)))) } ?? -1
        guard wowtype_engine_save_wait(handle, ms) < 0 else { return nil }
        return wowtype_last_error().map { String(cString: $0) } ?? "unknown"
    }

    /// 自定义词（custom.tsv）：替换上一次载入的，文件不存在就清空。返回条数，-1 出错。
    @discardableResult
    public func loadCustomWords(_ path: String) -> Int {
        Int(wowtype_engine_load_custom_words(handle, path))
    }

    /// 简繁对照表载入过没有（繁体输出要用，第一次打开繁体时才读）。
    public private(set) var conversionLoaded = false
    /// 五笔码表载入过没有（选了五笔才读）。
    public private(set) var wubiLoaded = false

    /// 设置里管引擎的部分（模糊音、纠错、双拼、生僻字、繁体、五笔码表），和 Linux 的 applyCoreSettings 一样。
    /// conversion 是简繁对照表 s2t.tsv 的路径，没有就不出繁体；wubi 是五笔码表 wubi86.tsv 的路径，
    /// 没有时五笔照全拼打（候选框上方会话会说）。返回要记日志的问题。
    @discardableResult
    public func apply(_ config: WowtypeConfig, conversion: String? = nil, wubi: String? = nil) -> [String] {
        var problems: [String] = []
        wowtype_engine_set_fuzzy(handle, config.fuzzy ? 1 : 0)
        wowtype_engine_set_fuzzy_groups(handle, config.fuzzyGroups)
        wowtype_engine_set_shuangpin(handle, config.shuangpin ? 1 : 0)
        if wowtype_engine_set_shuangpin_scheme(handle, config.shuangpinScheme) != 0 {
            problems.append("不认识双拼方案 \(config.shuangpinScheme)，用自然码")
            wowtype_engine_set_shuangpin_scheme(handle, "ziranma")
        }
        wowtype_engine_set_shuangpin_abbrev(handle, config.shuangpinAbbrev ? 1 : 0)
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
        if config.wubi && !wubiLoaded {
            if let wubi, wowtype_engine_load_wubi(handle, wubi) > 0 {
                wubiLoaded = true
            } else {
                problems.append("五笔码表载入失败 \(wubi ?? "（没有 wubi86.tsv）")，先按全拼打")
            }
        }
        return problems
    }

    public static var abiVersion: Int {
        Int(wowtype_abi_version())
    }
}

/// 候选框要画的东西（会话给的这一页，或展开面板的这一屏）。
public struct CandidatePage: Equatable {
    public var texts: [String]
    /// 每个候选后面的小字（五笔还要打的码、z 临时拼音反查的五笔码），和 texts 一样长；没有的是空串
    public var comments: [String] = []
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
    /// 候选前面画序号。上屏以后的联想没按 Tab 进联想行时不画：这时数字不选联想，照常交给应用
    public var labels = true
    /// 互译时候选上下多出来的两行；不在互译时 nil。互译时没有候选（只攒着原文）也画框
    public var translate: TranslatePanel? = nil
    public static let columns = 6

    /// 第 i 个候选后面的小字，没有是空串。
    public func comment(_ i: Int) -> String {
        i < comments.count ? comments[i] : ""
    }
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
    /// 光标前一个字符（Unicode 码位），不知道给 0。数字写法里的符号（3.14、20:22）要原样上屏。
    var previousCharacter: UInt32 { get }
    /// 能把打的字发去翻译。密码框之类（macOS 上是系统开着安全输入时）照常打中文，不往外发。
    var allowsTranslation: Bool { get }
    /// previousCharacter 是应用告诉的（不是外壳猜的）。中英文之间自动加空格只信应用告诉的，
    /// 和 Linux 一样：读不到光标前的文字就不猜。
    var previousCharacterIsReliable: Bool { get }
    /// 能按位置改应用里的字（中文标点自动配对要：挪光标、删补好的右半边）：应用说得清光标在哪、
    /// 读得到光标旁边的字。这一下不能时不配对，标点照常一个一个上屏（不会留下一个光标在它后面的右括号）。
    var canEditAroundCaret: Bool { get }
    /// 应用里光标后一个字（Unicode 码位）；不知道（应用不说、有选区、光标在文字末尾）是 nil。
    /// 自动配对跳过右标点、成对删之前拿它核对。
    var nextCharacter: UInt32? { get }
    /// 按位置改一次字（见 CaretEdit）；改不了（不知道光标在哪）返回 false。
    func edit(_ edit: CaretEdit) -> Bool
}

extension TextClient {
    public var previousCharacterIsReliable: Bool { true }
    public var allowsTranslation: Bool { true }
    public var canEditAroundCaret: Bool { false }
    public var nextCharacter: UInt32? { nil }
    public func edit(_ edit: CaretEdit) -> Bool { false }
}

/// 自动配对（AutoPairPunct）要应用做的一次修改：光标（刚上屏的字后面）往后 offset 个字（UTF-16，负数往前）起，
/// 换掉 length 个字，换成 text；光标落在换上的字后面。
///
/// IMK 里没有「挪光标」，只有按位置换字（insertText 带 replacementRange，长按出重音字母也是这么换的）。
/// 挪光标就是把目标位置前面那个字原样换一遍：上屏「（）」后把「（」换成「（」，光标落在两个中间；
/// 跳过补好的「）」是把它换成它自己。不知道那个字是什么时换空的（长度 0 的位置换成空串），只把光标放过去。
public struct CaretEdit: Equatable {
    public var offset: Int
    public var length: Int
    public var text: String

    public init(offset: Int, length: Int, text: String) {
        self.offset = offset
        self.length = length
        self.text = text
    }

    /// 空的一对按退格：光标前、后各删一个字（左右半边都是一个 UTF-16 单元的中文标点）。
    public static let deletePair = CaretEdit(offset: -1, length: 2, text: "")

    /// 光标挪 delta 个字（会话的 frame->cursor_delta）。inserted 是这一下刚上屏的字（光标在它后面），
    /// next 是按键之前光标后面那个字（跳过右标点时就是它）。
    public static func move(by delta: Int, inserted: String, next: UInt32?) -> CaretEdit {
        if delta < 0 {
            // 往左：把目标位置前面那个字（刚上屏的字里的）原样换一遍
            let units = Array(inserted.utf16)
            let index = units.count + delta - 1
            if index >= 0, index < units.count, !(0xD800...0xDFFF).contains(units[index]) {
                return CaretEdit(offset: delta - 1, length: 1, text: String(decoding: [units[index]], as: UTF16.self))
            }
        } else if delta == 1, let next, next > 0, next < 0xD800 || (next >= 0xE000 && next < 0x10000),
                  let scalar = Unicode.Scalar(next) {
            // 往右跳过一个：把光标后面那个字（补好的右半边）换成它自己
            return CaretEdit(offset: 0, length: 1, text: String(Character(scalar)))
        }
        return CaretEdit(offset: delta, length: 0, text: "")
    }
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
    /// 每次真正上屏时调用（text, source, scheme, candidateIndex），给打字统计用；
    /// 只分类计数，不保存文字。candidateIndex 是选中的候选位置（1 起），0 表示不是选候选。
    public var onCommitStats: ((String, String, String, Int) -> Void)?
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
    /// 上一次 apply 以后的模式：离开「译」的 frame 里上屏的照「译」记统计
    private var appliedMode: Mode = .chinese
    /// 候选框上画着上屏以后的联想：会话关掉了联想、键又交给了应用时要收起来
    private var associationShown = false
    /// 会话的自动配对开着（设置里打开了、这个输入框现在能按位置改字）。变了才重新配会话（关掉时会话丢掉记着的配对）
    private var pairing = false
    /// 这一下按键之前应用里光标后面的字（报给了会话的），跳过补好的右标点时换它自己
    private var keyNextCharacter: UInt32?
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

    /// 换设置。Shift 切换关掉、也没另设切换键时回到中文（切不回来了；进出「译」的键只进出「译」，不算）；剪贴板历史关掉时马上清空；关掉了互译或者翻译器没配好时离开「译」（和 Linux 一样）。
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
        if let action = modeKeyAction(key) {
            // 另设的切换键（中 ↔ 英，在「译」里回中文）、进出「译」的键：会话切；
            // 进不了「译」（没配好、密码框）时交给应用。翻译器可能刚配好或者不能用了：先跟上（和单按 Shift 一样）
            configure()
            return sendToSession(key, action: action)
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
            // 先问会话：打字途中 Ctrl+Delete、Ctrl+退格忘掉光标处学错的词。别的快捷键交给应用，
            // 打到一半时编辑区留着；没在打字时会话借这一下知道应用里的字可能变了（上文作废）
            return sendToSession(key)
        }
        if !composing {
            return handleIdle(key)
        }
        return handleComposing(key)
    }

    /// Shift 的按下 / 松开（macOS 的 flagsChanged）。这一下切了模式时返回 true。
    /// right 是右 Shift（设置里 ShiftToggle 可以只用一边，或者不用 Shift 切换）。
    /// 判断在会话里（和 Linux 同一套规矩）：中间按了别的键、按住超过 0.5 秒、按下时带着别的修饰键、
    /// 工具栏或表情面板开着都不算。now 和 clock 是同一个时钟。
    /// 单按先不切（双击 Shift 不切换，#253）：叫 onTranslatePoll 开始轮询，到时间没有第二下在
    /// pollTranslation 里切；之前按了别的键时在那个键里先切（mode 变了，外壳照常弹提示）。
    @discardableResult
    public func shiftChanged(down: Bool, otherModifiers: Bool, now: Double, right: Bool = false) -> Bool {
        configure() // 翻译器可能刚配好（本地模型下载完）：「译」这一档跟着
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.keysym = right ? 0xffe2 : 0xffe1
        raw.release = down ? 0 : 1
        raw.modifiers = otherModifiers ? Modifiers.control.rawValue : 0
        raw.time_ms = UInt64(max(now, 0) * 1000)
        guard let frame = wowtype_session_key(session, &raw) else { return false }
        if frame.pointee.wake_after_ms > 0 {
            // 单按 Shift 等双击（#253）：到时间没有第二下，pollTranslation 里切
            onTranslatePoll?()
        }
        guard frame.pointee.mode_changed != 0 else { return false }
        // 打到一半切英文：会话把已选的词 + 打的字母放进了 frame；离开「译」时是攒着的原文
        apply(frame)
        return true
    }

    /// 别的修饰键变了（Command、Option 等）：这次 Shift 不算单按（等双击的那一下单按先切）。
    public func otherModifierChanged() {
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.action = UInt32(WOWTYPE_KEY_ACTION_OBSERVE)
        followObserved(wowtype_session_key(session, &raw))
    }

    /// 告诉会话有这个键（只用来打断单按 Shift，不处理）。
    private func observe(_ key: KeyInput) {
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.keysym = key.keysym
        raw.modifiers = key.modifiers.rawValue
        raw.action = UInt32(WOWTYPE_KEY_ACTION_OBSERVE)
        followObserved(wowtype_session_key(session, &raw))
    }

    /// OBSERVE 的 frame 里切了模式：等双击的单按 Shift 被这个键打断（#253），会话先切了
    /// （打到一半切英文时字母在 frame 里），这个键照新模式处理。
    private func followObserved(_ frame: UnsafePointer<WowtypeFrame>?) {
        if let frame, frame.pointee.mode_changed != 0 {
            apply(frame)
        }
    }

    /// 设置里另设的切换键、进出「译」的键（和 Linux 一样：两个一样时算进出「译」）。
    private func modeKeyAction(_ key: KeyInput) -> UInt32? {
        if config.translateModeKey?.matches(key) == true {
            return UInt32(WOWTYPE_KEY_ACTION_TOGGLE_TRANSLATE)
        }
        if config.toggleKey?.matches(key) == true {
            return UInt32(WOWTYPE_KEY_ACTION_TOGGLE_MODE)
        }
        return nil
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

    /// 外部命令里模式的叫法（和 Linux 的 org.wowtype.Input 一样）：zh、en、translate。
    public var modeName: String {
        switch mode {
        case .chinese: return "zh"
        case .english: return "en"
        case .translate: return "translate"
        }
    }

    /// 外部命令切模式（和 Linux 的 org.wowtype.Input SetMode 一样，vim 退出插入模式时切英文这类用法）：
    /// zh、en、translate（互译配好了才行）、toggle（中英之间切，在「译」里回中文）。认不出、切不到返回 false。
    /// 不弹「中 / 英」提示；打到一半切英文时和单按 Shift 一样，打的字母原样上屏。
    @discardableResult
    public func setMode(named name: String) -> Bool {
        let target: Mode
        switch name {
        case "zh": target = .chinese
        case "en": target = .english
        case "translate":
            guard translateAvailable else { return false }
            target = .translate
        case "toggle": target = mode == .chinese ? .english : .chinese
        default: return false
        }
        switchMode(to: target)
        return true
    }

    /// 能自己切中 / 英：单按 Shift 没关，或者另设了切换键（只设了进出「译」的键不算）。
    public var canToggleMode: Bool {
        config.shiftToggle != .off || config.toggleKey != nil
    }

    /// 切到 WowType 时（从别的输入法切过来、这个进程里第一次用到这个输入框）按设置里的 InitialMode 定中 / 英，
    /// 和 Linux 的 applyInitialMode 一样：Last 不动；切不回中文时不进英文；在「译」里的回到中文 / 英文。
    /// 不弹「中 / 英」提示。外壳负责只在切输入法时调（换窗口、换应用不调）。
    public func applyInitialMode() {
        switch config.initialMode {
        case .last:
            return
        case .chinese:
            switchMode(to: .chinese)
        case .english:
            switchMode(to: canToggleMode ? .english : .chinese)
        }
    }

    /// 换到别的应用、别的窗口时（#254）按设置里的 WindowMode 定中 / 英，和 Linux 的 applyWindowMode 一样：
    /// Same 不动（每个应用记着自己的模式）；切不回中文时不进英文；在「译」里的回到中文 / 英文。不弹提示。
    /// 外壳负责只在应用、窗口变了时调；从别的输入法切回来的那一下按 InitialMode，不调这个。
    public func applyWindowMode() {
        switch config.windowMode {
        case .same:
            return
        case .chinese:
            switchMode(to: .chinese)
        case .english:
            switchMode(to: canToggleMode ? .english : .chinese)
        }
    }

    /// 系统要结束组字（换输入框、点了别处、切走输入法）：已选的词 + 打的字母原样上屏（和回车一样，
    /// 双拼是打的键、五笔是码，不带分音节的隔音符）；互译时拼音先进原文，原文再原样上屏。
    /// 工具栏、表情面板收起来，会话记的上文作废（回来时光标可能在别处）。
    /// Linux 上同样的时候是丢掉：那边工具包抢先上屏的是编辑区里显示的字，输入法没法换成原始字母。
    public func commitComposition() {
        closeTool()
        if hasPendingText {
            apply(wowtype_session_reset(session, 1))
        }
        apply(wowtype_session_reset(session, 0))
    }

    /// 放弃正在打的：拼音、选了一半的句子、互译攒着的原文都丢掉，工具栏、表情面板收起来，上文作废。
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

    /// 候选框上点了翻页箭头、滚了滚轮（和 Linux 的 panelListKey 一样，当成按了 Page Up / Page Down）。
    /// 只在打字途中、工具栏或表情面板开着时翻；上屏以后的联想只有一页，不翻（不然这个键会交给应用）。
    public func turnPage(forward: Bool) {
        guard isComposing || openPanel != nil else { return }
        _ = handle(.key(forward ? Keysym.pageDown : Keysym.pageUp))
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
        config.translate_key = settings.translateModeKey == nil ? 0 : 1
        // 互译只翻一句（#191）：双击 Shift 进「译」，翻完回去的 frame 可能在 pollTranslation 里，外壳比对模式跟上
        config.translate_one_shot = settings.translateOneShot ? 1 : 0
        config.toolbar = settings.toolbar ? 1 : 0
        config.clipboard_history = settings.clipboardHistory ? 1 : 0
        config.shuangpin_keys = settings.shuangpinShowKeys ? 1 : 0
        config.wubi = settings.wubi ? 1 : 0
        config.wubi_auto_commit = settings.wubiAutoCommit ? 1 : 0
        config.wubi_hint = settings.wubiHint ? 1 : 0
        config.association = settings.association ? 1 : 0
        // 自动配对要能挪应用里的光标：这个输入框现在不能时先不开（sendToSession 每个键看一眼，变了再配）
        pairing = settings.autoPairPunct && client?.canEditAroundCaret == true
        config.auto_pair_punct = pairing ? 1 : 0
        // 双击 Shift 不切换（#253）：等着的单按在 pollTranslation、observe 的 frame 里切，都跟着 mode_changed
        config.shift_double_tap = 1
        wowtype_session_configure(session, &config)
        if isComposing {
            refresh()
        }
    }

    private func handleIdle(_ key: KeyInput) -> Bool {
        // 都交给会话：字母开始编辑区（大写原样保留，Hello、iPhone 出英文候选）；
        // 标点换成中文标点（半角样式、数字写法里的符号、没有中文写法的交给应用）；
        // 汉字后面打数字要补空格时会话自己上屏（第 5 章）；退格、方向键、回车这些交给应用，
        // 会话借这一下知道应用里的字可能变了（上文作废）
        if sendToSession(key) {
            return true
        }
        // 互译时打的字都要进原文：会话交给应用的（数字写法里的点 3.14、半角标点）原样进原文
        if translating, let c = key.ascii, c > 0x20, c < 0x7f, !key.isLetter {
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
    func sendToSession(_ key: KeyInput, action: UInt32 = UInt32(WOWTYPE_KEY_ACTION_NONE)) -> Bool {
        if config.autoPairPunct || pairing {
            // 输入框能不能按位置改字可能变了（换了输入框、点到了说不清光标的地方）：变了重新配会话
            let wanted = config.autoPairPunct && client?.canEditAroundCaret == true
            if wanted != pairing {
                configure()
            }
        }
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.keysym = key.keysym
        raw.modifiers = key.modifiers.rawValue
        raw.release = key.release ? 1 : 0
        raw.action = action
        raw.time_ms = UInt64(max(clock(), 0) * 1000)
        if client?.allowsTranslation != true {
            // 密码框（安全输入）：「译」里也照常上屏、不往外发，进出「译」的键进不去。
            // 不带 NO_LEARN（「确定是密码框」）：真的密码框里系统换成英文键盘，按键根本到不了输入法；
            // 安全输入开着还能打中文的是终端的「安全键盘输入」、没关掉安全输入的密码管理器，在那里照常学词
            raw.hints |= WOWTYPE_KEY_HINT_NO_TRANSLATE
        }
        keyNextCharacter = nil
        if pairing && !translating, let next = client?.nextCharacter {
            // 自动配对：跳过右标点、成对删之前，会话拿光标后的字核对补好的右半边还在不在
            raw.next_char = next
            raw.hints |= WOWTYPE_KEY_HINT_NEXT_CHAR
            keyNextCharacter = next
        }
        if translating {
            // 互译时上屏的字进原文：光标前的字是原文的最后一个字（3.14 的点、20:22 的冒号原样进原文），不补空格
            raw.prev_char = previousCharacter
            raw.hints |= WOWTYPE_KEY_HINT_NO_AUTO_SPACE
        } else {
            // 应用告诉的才给（自己猜的给 0）：会话按它决定要不要补空格、核对自己记的上文；
            // 数字写法里的标点它自己也记。应用说了光标前没有字（输入框清空了、光标在开头）也报：
            // 会话清掉记的上文，和 fcitx5、Windows 一样（不报的话清空输入框后还拿上一次上屏的字当上文）
            raw.prev_char = reliablePreviousCharacter
            if client?.previousCharacterIsReliable == true {
                raw.hints |= WOWTYPE_KEY_HINT_SURROUNDING
            }
        }
        guard let frame = wowtype_session_key(session, &raw) else {
            return false
        }
        let handled = frame.pointee.handled != 0
        if handled {
            apply(frame)
        } else if Int(frame.pointee.size) >= MemoryLayout<WowtypeFrame>.size, frame.pointee.delete_next != 0,
                  client?.edit(.deletePair) == true {
            // 自动配对：空的一对按退格，左右两半一起删（这个退格吃掉，不再交给应用）
            refresh()
            return true
        } else if associationShown {
            // 联想开着时按了打字以外的键（空格、回车、数字、方向键……）：会话关掉了联想、键交给应用
            refresh()
        }
        return handled
    }

    /// 应用告诉的光标前一个字（外壳自己猜的不算），没有是 0。
    private var reliablePreviousCharacter: UInt32 {
        client.map { $0.previousCharacterIsReliable ? $0.previousCharacter : 0 } ?? 0
    }

    /// 按会话给的 frame 上屏、更新编辑区和候选框。
    func apply(_ frame: UnsafePointer<WowtypeFrame>?) {
        let delta = frame.map { Int($0.pointee.size) >= MemoryLayout<WowtypeFrame>.size ? Int($0.pointee.cursor_delta) : 0 } ?? 0
        // 离开「译」的那一下上屏的（只翻一句时的译文，原文原样上屏）照「译」记统计：会话已经切回去了（和 Linux 一样）
        let statsMode = frame.map { $0.pointee.mode_changed != 0 } == true && appliedMode == .translate ? .translate : mode
        appliedMode = mode
        var inserted = ""
        if let frame, let commit = frame.pointee.commit {
            // 会话已经补好了空格、记了上文；互译时上屏的是译文、原文
            let text = String(cString: commit)
            inserted = text
            client?.insertText(text)
            // 打字统计（外壳按 TypingStats 决定记不记）：互译上屏的不是候选，位置记 0
            onCommitStats?(text, statsSource(statsMode), statsScheme(statsMode),
                           statsMode == .translate ? 0 : Int(frame.pointee.choice_index))
            if frame.pointee.learned != 0 {
                onCommit?(text)
            }
            // 选了 emoji（打字推荐的、表情面板的）会话记进最近用过
        }
        if delta != 0 {
            // 自动配对：上屏「（）」后光标放到中间（-1），跳过补好的右半边（+1）。紧跟在上屏后面、下一个键之前
            _ = client?.edit(CaretEdit.move(by: delta, inserted: inserted, next: keyNextCharacter))
        }
        if let frame, Int(frame.pointee.size) >= MemoryLayout<WowtypeFrame>.size, frame.pointee.forgot != 0 {
            onForget?()
        }
        refresh()
    }

    /// 上屏一段与拼音无关的字（语音识别的结果）：交给会话，和工具栏、表情面板上屏的一样
    /// 补空格、记上文，互译时进原文。
    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        apply(wowtype_session_commit_text(session, text, reliablePreviousCharacter))
    }

    /// 统计用的输入模式：互译 / 英文 / 五笔 / 双拼 / 全拼。
    private func statsSource(_ mode: Mode) -> String {
        if mode == .translate { return "translate" }
        if mode == .english { return "english" }
        if config.wubi { return "wubi" }
        return config.shuangpin ? "shuangpin" : "quanpin"
    }

    /// 双拼方案在统计里的名字（小写）；不是双拼时为空。
    private func statsScheme(_ mode: Mode) -> String {
        config.shuangpin && mode != .translate && mode != .english ? config.shuangpinScheme.lowercased() : ""
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
        // 没在打字时也可能有上屏以后的联想（会话给的一页，照普通候选框画）
        let associating = !isComposing && wowtype_session_association(session) != 0
        associationShown = associating
        let frame = isComposing || associating ? wowtype_session_frame(session) : nil
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
        var comments: [String] = []
        texts.reserveCapacity(f.cand_count)
        for i in 0..<f.cand_count {
            if let text = wowtype_session_candidate(session, i) {
                texts.append(String(cString: text))
                comments.append(wowtype_session_candidate_comment(session, i).map { String(cString: $0) } ?? "")
            }
        }
        // 五笔空码、没有码表时没有候选，只有上方一行提示
        let aux = f.aux.map { String(cString: $0) }
        guard !texts.isEmpty || aux != nil else { return nil }
        var page = CandidatePage(texts: texts, cursor: Int(f.cand_cursor), hasPrev: f.has_prev != 0,
                                 hasNext: f.has_next != 0, expanded: f.panel == 1, aux: aux, vertical: !config.horizontal)
        page.labels = !(f.panel == WOWTYPE_PANEL_ASSOCIATION && f.cand_cursor < 0)
        page.comments = comments
        return page
    }

    // MARK: 互译

    /// 外壳每 50 毫秒调一次（会话的 wake_after_ms）：到时间就发请求，按过回车的译好了就上屏，
    /// 结果变了就重画；单按 Shift 等双击等到了时间就切（#253，mode 变了外壳弹提示）。
    /// 返回 false 表示不用再调了（下一次原文变了、又单按了 Shift 会再叫 onTranslatePoll）。
    @discardableResult
    public func pollTranslation() -> Bool {
        guard let frame = wowtype_session_tick(session, UInt64(max(clock(), 0) * 1000)) else {
            return false
        }
        if frame.pointee.mode_changed != 0 {
            // 打到一半切英文时字母在 frame 里；离开「译」时是攒着的原文
            let wake = frame.pointee.wake_after_ms > 0
            translateDrawn = ""
            apply(frame)
            return wake
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
