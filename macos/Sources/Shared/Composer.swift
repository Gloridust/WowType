// 组字：按键交给核心的输入会话（wowtype_session_*），按会话给的结果更新编辑区、候选框、上屏。
//
// 不依赖 AppKit。输入法外壳实现 TextClient（IMK 的 client），按键测试用一个假的 TextClient。
//
// 过渡（docs/PORTING.md 第 2 步）：会话现在管字母、隔音符、退格、Esc、候选列表、选词和上屏；
// 空格、数字选词、回车、翻页、光标移动、标点还没挪进会话，这里和 fcitx5 外壳一样先自己处理。
// 挪进会话以后，这个文件只剩「按键给会话、按 frame 画界面」。

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

/// 候选框这一页要画的东西。
public struct CandidatePage: Equatable {
    public var texts: [String]
    /// 光标在这一页的第几个
    public var cursor: Int
    public var pageIndex: Int
    public var pageCount: Int
    public var hasPrev: Bool { pageIndex > 0 }
    public var hasNext: Bool { pageIndex + 1 < pageCount }
}

/// 外壳要实现的：往输入框里写字、画编辑区和候选框。
public protocol TextClient: AnyObject {
    /// 上屏（同时清掉编辑区）。
    func insertText(_ text: String)
    /// 编辑区（marked text）；空串表示清掉。cursor 是 UTF-16 偏移。
    func setMarkedText(_ text: String, cursor: Int)
    /// 画候选框；nil 表示收起。
    func showCandidates(_ page: CandidatePage?)
    /// 光标前一个字符（Unicode 码位），不知道给 0。数字后面的句号要原样上屏。
    var previousCharacter: UInt32 { get }
}

public final class Composer {
    public enum Mode: Equatable {
        case chinese
        case english
    }

    public private(set) var mode: Mode = .chinese
    public var pageSize = 9
    /// 0 全角中文标点，1 半角
    public var punctStyle: Int32 = 0

    private let session: OpaquePointer
    private var engine: Engine?
    private weak var client: TextClient?
    private var page = 0
    private var cursor = 0
    private var total = 0
    private var shiftTap = ShiftTap()
    /// 最近上屏的字（给会话当上文排序），只留末尾一小段。
    private var recent = ""
    /// 每次上屏后调用（外壳用来定时保存学习数据）。
    public var onCommit: ((String) -> Void)?

    public init(engine: Engine?, client: TextClient) {
        self.engine = engine
        self.client = client
        session = wowtype_session_new(engine?.handle, nil)
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
            // 快捷键交给应用；打到一半时编辑区留着
            return false
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
        apply(wowtype_session_reset(session, 1))
    }

    /// 放弃正在打的（输入框失去焦点）。
    public func cancel() {
        apply(wowtype_session_reset(session, 0))
    }

    // MARK: 内部

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
        let sym = key.keysym
        switch sym {
        case Keysym.backspace, Keysym.escape:
            return sendToSession(key) || true
        case 0x20:
            chooseCurrent()
            return true
        case Keysym.returnKey, Keysym.keypadEnter:
            commitInput()
            return true
        case Keysym.left:
            moveCursor(-1)
            return true
        case Keysym.right:
            moveCursor(1)
            return true
        case Keysym.up, Keysym.pageUp:
            turnPage(-1)
            return true
        case Keysym.down, Keysym.pageDown:
            turnPage(1)
            return true
        default:
            break
        }
        guard let c = key.ascii else {
            // 其他功能键（Tab、Home 等）打字途中吃掉，免得光标跑到别处
            return true
        }
        if key.isLetter || c == 0x27 {
            if sendToSession(key) {
                return true
            }
        }
        if key.isDigit {
            if c >= 0x31 {
                let index = page * pageSize + Int(c - 0x31)
                if index < total && Int(c - 0x31) < pageSize {
                    choose(index)
                }
            }
            return true
        }
        if c == 0x2d || c == 0x3d {
            // - = 翻页；只有一页时照常当标点
            if pageCount > 1 {
                turnPage(c == 0x2d ? -1 : 1)
                return true
            }
        }
        // 打字途中按标点：先上屏当前候选（句首词选完还剩的接着选），再上屏标点
        for _ in 0..<16 where isComposing {
            chooseCurrent()
        }
        insert(punctuation(for: c) ?? String(UnicodeScalar(c)))
        return true
    }

    private func punctuation(for c: UInt8) -> String? {
        guard c != 0x27, wowtype_fullwidth_punct(Int32(c)) != nil else {
            return nil
        }
        let prev = client?.previousCharacter ?? 0
        guard let text = wowtype_punct(Int32(c), punctStyle, Int32(bitPattern: prev)) else {
            return String(UnicodeScalar(c))
        }
        return String(cString: text)
    }

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
            page = 0
            cursor = 0
            apply(frame)
        }
        return handled
    }

    private func chooseCurrent() {
        guard total > 0 else {
            commitInput()
            return
        }
        choose(min(page * pageSize + cursor, total - 1))
    }

    private func choose(_ index: Int) {
        guard let frame = wowtype_session_choose(session, index), frame.pointee.handled != 0 else {
            return
        }
        page = 0
        cursor = 0
        apply(frame)
    }

    private func commitInput() {
        apply(wowtype_session_commit_input(session))
    }

    private var pageCount: Int {
        total == 0 ? 0 : (total + pageSize - 1) / pageSize
    }

    private func turnPage(_ delta: Int) {
        let target = page + delta
        guard target >= 0, target < pageCount else { return }
        page = target
        cursor = 0
        showCandidates()
    }

    private func moveCursor(_ delta: Int) {
        guard total > 0 else { return }
        let global = page * pageSize + cursor + delta
        guard global >= 0, global < total else { return }
        page = global / pageSize
        cursor = global % pageSize
        showCandidates()
    }

    /// 按会话给的 frame 上屏、更新编辑区和候选框。
    private func apply(_ frame: UnsafePointer<WowtypeFrame>?) {
        if let frame, let commit = frame.pointee.commit {
            insert(String(cString: commit))
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
        total = Int(wowtype_session_candidate_total(session))
        if page * pageSize >= max(total, 1) {
            page = 0
            cursor = 0
        }
        if let frame = wowtype_session_frame(session), isComposing {
            let preedit = String(cString: frame.pointee.preedit)
            let byteCursor = Int(frame.pointee.preedit_cursor)
            client?.setMarkedText(preedit, cursor: utf16Offset(preedit, byteOffset: byteCursor))
        } else {
            client?.setMarkedText("", cursor: 0)
        }
        showCandidates()
    }

    private func showCandidates() {
        guard isComposing, total > 0 else {
            client?.showCandidates(nil)
            return
        }
        // 只读这一页：候选可能有上千个
        let start = page * pageSize
        let end = min(start + pageSize, total)
        var texts: [String] = []
        texts.reserveCapacity(end - start)
        for i in start..<end {
            var info = WowtypeCandidateInfo()
            info.size = UInt32(MemoryLayout<WowtypeCandidateInfo>.size)
            if wowtype_session_candidate_info(session, i, &info) == 0, let text = info.text {
                texts.append(String(cString: text))
            }
        }
        cursor = min(cursor, max(texts.count - 1, 0))
        client?.showCandidates(CandidatePage(texts: texts, cursor: cursor, pageIndex: page,
                                             pageCount: pageCount))
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
