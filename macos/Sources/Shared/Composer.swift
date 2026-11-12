// 组字：按键交给核心的输入会话（wowtype_session_*），按会话给的结果更新编辑区、候选框、上屏。
//
// 不依赖 AppKit。输入法外壳实现 TextClient（IMK 的 client），按键测试用一个假的 TextClient。
//
// 会话（ABI 1.6 起）管打字途中的全部按键：字母、隔音符、退格、Esc、空格、回车、数字选词、
// 翻页、移光标、展开面板。候选框照 frame 的 cand_* 画（显示的就是这一页 / 面板的这一屏）。
// 还在外壳的（docs/PORTING.md 第 4 块挪进会话）：标点，以及打字途中按标点先上屏当前候选。
// 打字途中按 Control+Delete（Mac 键盘上的 Delete 是退格；有向前删除键或按 Fn+Control+Delete 也行）
// 忘掉光标处学错的词（ABI 1.7），也是会话管，外壳只在 frame->forgot 时马上存学习数据（onForget）。

import CWowtype

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
    /// 展开面板（横排按下键）：每行 columns 个，数字选光标所在行的第几个
    public var expanded: Bool
    public static let columns = 6
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
}

public final class Composer {
    public enum Mode: Equatable {
        case chinese
        case english
    }

    public private(set) var mode: Mode = .chinese
    /// 一页几个候选
    public var pageSize = 9 {
        didSet { configure() }
    }
    /// 候选横排（左右键移光标、上下键翻页、下键展开面板）；false 竖排（上下键移光标、左右键翻页）
    public var horizontal = true {
        didSet { configure() }
    }
    /// 0 全角中文标点，1 半角
    public var punctStyle: Int32 = 0

    private let session: OpaquePointer
    private var engine: Engine?
    private weak var client: TextClient?
    private var shiftTap = ShiftTap()
    /// 最近上屏的字（给会话当上文排序），只留末尾一小段。
    private var recent = ""
    /// 每次上屏后调用（外壳用来定时保存学习数据）。
    public var onCommit: ((String) -> Void)?
    /// Ctrl+Delete 忘掉了学错的词以后调用（外壳马上存学习数据，免得重启又回来）。
    public var onForget: (() -> Void)?

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

    public func setEngine(_ engine: Engine?) {
        self.engine = engine
        wowtype_session_set_engine(session, engine?.handle)
        refresh()
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

    // MARK: 按键

    /// 处理一次按下；返回 true 表示吃掉了这个键（不交给应用）。
    public func handle(_ key: KeyInput) -> Bool {
        if key.release {
            return false
        }
        shiftTap.interrupt()
        if mode == .english {
            return false
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
    @discardableResult
    public func shiftChanged(down: Bool, otherModifiers: Bool, now: Double) -> Bool {
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

    public func toggleMode() {
        if mode == .chinese {
            // 打到一半切英文：已选的词 + 打的字母原样上屏（和微信输入法一样）
            if isComposing {
                commitInput()
            }
            mode = .english
        } else {
            mode = .chinese
        }
    }

    /// 切走输入法、换输入框：打到一半的原样上屏。
    public func commitComposition() {
        guard isComposing else { return }
        commitInput()
    }

    /// 放弃正在打的（输入框失去焦点）。
    public func cancel() {
        apply(wowtype_session_reset(session, 0))
    }

    /// 点候选框里显示的第 index 个（和按数字键一样）。
    public func select(_ index: Int) {
        guard index >= 0, let frame = wowtype_session_select(session, index), frame.pointee.handled != 0 else {
            return
        }
        apply(frame)
    }

    // MARK: 内部

    private func configure() {
        var config = WowtypeSessionConfig()
        config.size = UInt32(MemoryLayout<WowtypeSessionConfig>.size)
        config.page_size = UInt32(max(pageSize, 1))
        config.calculator = 1
        config.date_time = 1
        config.emoji_suggest = 1
        config.horizontal = horizontal ? 1 : 0
        config.page_keys = UInt32(WOWTYPE_PAGE_KEYS_MINUS)
        config.select_keys = Int32(WOWTYPE_SELECT_KEYS_OFF)
        config.pick_char = 1
        wowtype_session_configure(session, &config)
        if isComposing {
            refresh()
        }
    }

    private func handleIdle(_ key: KeyInput) -> Bool {
        guard let c = key.ascii else {
            return false
        }
        if c >= 0x61 && c <= 0x7a {
            return sendToSession(key)
        }
        if c >= 0x41 && c <= 0x5a {
            // 大写字母：交给应用（Caps Lock、Shift+字母打英文）
            return false
        }
        if let text = punctuation(for: c) {
            insert(text)
            return true
        }
        return false
    }

    private func handleComposing(_ key: KeyInput) -> Bool {
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
        let prev = client?.previousCharacter ?? 0
        guard let text = wowtype_punct(Int32(c), punctStyle, Int32(bitPattern: prev)) else {
            return String(UnicodeScalar(c))
        }
        return String(cString: text)
    }

    @discardableResult
    private func sendToSession(_ key: KeyInput) -> Bool {
        var raw = WowtypeKey()
        raw.size = UInt32(MemoryLayout<WowtypeKey>.size)
        raw.keysym = key.keysym
        raw.modifiers = key.modifiers.rawValue
        raw.release = key.release ? 1 : 0
        raw.prev_char = client?.previousCharacter ?? 0
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

    private func commitInput() {
        // 回车：已选的词 + 剩下的字母原样上屏（会话会记选词）
        apply(wowtype_session_reset(session, 1))
    }

    /// 按会话给的 frame 上屏、更新编辑区和候选框。
    private func apply(_ frame: UnsafePointer<WowtypeFrame>?) {
        if let frame, let commit = frame.pointee.commit {
            insert(String(cString: commit))
        }
        if let frame, Int(frame.pointee.size) >= MemoryLayout<WowtypeFrame>.size, frame.pointee.forgot != 0 {
            onForget?()
        }
        refresh()
    }

    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        client?.insertText(text)
        recent = String((recent + text).suffix(20))
        wowtype_session_set_context(session, recent)
        onCommit?(text)
    }

    private func refresh() {
        guard let frame = wowtype_session_frame(session), isComposing else {
            client?.setMarkedText("", cursor: 0)
            client?.showCandidates(nil)
            return
        }
        let f = frame.pointee
        let preedit = String(cString: f.preedit)
        client?.setMarkedText(preedit, cursor: utf16Offset(preedit, byteOffset: Int(f.preedit_cursor)))
        // 只读显示的这些：候选可能有上千个
        var texts: [String] = []
        texts.reserveCapacity(f.cand_count)
        for i in 0..<f.cand_count {
            if let text = wowtype_session_candidate(session, i) {
                texts.append(String(cString: text))
            }
        }
        guard !texts.isEmpty else {
            client?.showCandidates(nil)
            return
        }
        client?.showCandidates(CandidatePage(texts: texts, cursor: Int(f.cand_cursor),
                                             hasPrev: f.has_prev != 0, hasNext: f.has_next != 0,
                                             expanded: f.panel == 1))
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

/// UTF-8 字节偏移 → UTF-16 偏移（IMK 的 selectionRange 用 UTF-16）。
func utf16Offset(_ text: String, byteOffset: Int) -> Int {
    let utf8 = text.utf8
    let clamped = max(0, min(byteOffset, utf8.count))
    let index = utf8.index(utf8.startIndex, offsetBy: clamped)
    return text.utf16.distance(from: text.utf16.startIndex, to: index.samePosition(in: text.utf16) ?? text.utf16.endIndex)
}
