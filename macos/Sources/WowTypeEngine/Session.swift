// 输入会话的 Swift 封装：一个输入控制器一个会话，只在主线程上用。
//
// 按键行为全在核心的 session.rs 里（WOWTYPE_SESSION_KEYS_ALL：选词、翻页、标点、中英文模式都交给
// 会话）。这里只做 fcitx5 外壳在会话外面做的事（WowTypeKit 的 SessionGroup / PrevCharTracker）：
// 调会话前把引擎、上文、共用的中英文模式交给它，调完把上屏的字攒起来、记上文和学习次数。
// 和 core/tests/session_full_keys.rs 里的 `shell` 模块一一对应。
import CWowTypeCore
import WowTypeKit

/// 会话这一刻的样子（编辑区、候选、模式），拷出来的值，不引用核心里的内存。
public struct SessionSnapshot: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable {
        public var text: String
        public var label: String
    }

    public var composing: Bool
    public var preedit: MarkedTextLayout
    public var aux: String
    public var candidates: [Candidate]
    public var cursor: Int
    /// 0 表示列表，大于 0 表示展开的网格每行几个。
    public var columns: Int
    public var vertical: Bool
    public var hasPrevPage: Bool
    public var hasNextPage: Bool
    public var asciiMode: Bool

    public static let empty = SessionSnapshot(
        composing: false, preedit: MarkedTextLayout(text: "", plainBytes: 0, cursorBytes: 0), aux: "",
        candidates: [], cursor: 0, columns: 0, vertical: false, hasPrevPage: false, hasNextPage: false,
        asciiMode: false)
}

@MainActor
public final class Session {
    // deinit 不在主线程隔离里（isolated deinit 要 macOS 15.4），所以标成 nonisolated(unsafe)；
    // 会话只被这个对象持有，deinit 时没有别的地方在用它。
    nonisolated(unsafe) private let raw: OpaquePointer
    private let group: SessionGroup
    private var commit = ""
    private var tracker = PrevCharTracker()
    private var vertical = false

    private static let keys = UInt32(WOWTYPE_SESSION_KEYS_ALL)

    public init(group: SessionGroup = .shared) {
        self.group = group
        var config = Self.parse("").config
        guard let s = wowtype_session_new(nil, &config) else { fatalError("wowtype_session_new 返回空") }
        raw = s
    }

    deinit { wowtype_session_free(raw) }

    private static func parse(_ ini: String) -> (config: WowtypeSessionConfig, bad: Int) {
        var config = WowtypeSessionConfig()
        config.size = UInt32(MemoryLayout<WowtypeSessionConfig>.size)
        let bad = wowtype_session_config_parse(ini, keys, &config)
        return (config, Int(bad))
    }

    /// 读入设置全文（只取和会话有关的键）。返回认不出的行数。
    @discardableResult
    public func configure(_ ini: String) -> Int {
        let parsed = Self.parse(ini)
        var config = parsed.config
        wowtype_session_configure(raw, &config)
        vertical = config.vertical != 0
        if config.shift_toggle == Int32(WOWTYPE_SHIFT_TOGGLE_OFF) {
            // 关了单按 Shift 就没法切回中文：回到中文（和 fcitx5 外壳一样）
            group.english = false
        }
        return parsed.bad
    }

    /// 每次调会话前：引擎、上文、共用的中英文模式。
    private func sync(_ engine: Engine?) {
        wowtype_session_set_engine(raw, engine?.raw)
        wowtype_session_set_context(raw, group.recent)
        wowtype_session_set_mode(raw, group.english ? Int32(WOWTYPE_MODE_ENGLISH) : Int32(WOWTYPE_MODE_CHINESE))
    }

    /// 每次调会话后：攒上屏的字、记上文和学习次数、记下中英文模式。返回这次上屏的字。
    /// 只读 frame 的字段，读完才调别的会话函数（frame 在下一次调用前有效）。
    private func after(_ frame: UnsafePointer<WowtypeFrame>?, engine: Engine?) -> (handled: Bool, commit: String?) {
        guard let f = frame?.pointee else { return (false, nil) }
        group.english = f.mode == Int32(WOWTYPE_MODE_ENGLISH)
        let text = f.commit.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        if let text {
            commit += text
            if let context = group.didCommit(text, learned: f.learned != 0, hasEngine: engine != nil) {
                engine?.setContext(context)
            }
        }
        return (f.handled != 0, text)
    }

    /// 返回 true 表示会话用掉了这个键（false：交给应用）。
    public func process(_ event: WowKeyEvent, engine: Engine?) -> Bool {
        sync(engine)
        let wasComposing = isComposing
        var key = event.cValue(prev: tracker.prev)
        let (handled, text) = after(wowtype_session_key(raw, &key), engine: engine)
        tracker.update(event, committed: text, handled: handled, wasComposing: wasComposing)
        return handled
    }

    /// 词库载入好了、设置或自定义词改了：候选重算。
    public func refresh(engine: Engine?) {
        wowtype_session_set_engine(raw, nil)
        sync(engine)
    }

    /// 鼠标点选这一屏的第 index 个。
    @discardableResult
    public func select(_ index: Int, engine: Engine?) -> Bool {
        guard index >= 0 else { return false }
        sync(engine)
        let (handled, text) = after(wowtype_session_select(raw, index), engine: engine)
        tracker.didCommit(text)
        return handled
    }

    /// 鼠标滚轮 / 翻页按钮：翻页键交给会话；这一屏没变时返回 false。
    @discardableResult
    public func page(_ delta: Int) -> Bool {
        guard delta != 0, isComposing else { return false }
        let before = screen(wowtype_session_frame(raw))
        var key = WowtypeKey()
        key.size = UInt32(MemoryLayout<WowtypeKey>.size)
        key.keysym = delta < 0 ? XKeysym.pageUp : XKeysym.pageDown
        return screen(wowtype_session_key(raw, &key)) != before
    }

    private func screen(_ frame: UnsafePointer<WowtypeFrame>?) -> [Int] {
        guard let f = frame?.pointee else { return [] }
        return [Int(f.cand_offset), Int(f.cand_count), Int(f.cand_cursor), Int(f.panel)]
    }

    /// 失去焦点：清空编辑区，不上屏。
    public func reset() {
        _ = wowtype_session_reset(raw, 0)
        group.requestSaveIfUnsaved()
    }

    /// 应用要求结束输入、切换输入法：已选的词 + 原始字母上屏。
    public func commitComposition(engine: Engine?) {
        sync(engine)
        let (_, text) = after(wowtype_session_reset(raw, 1), engine: engine)
        tracker.didCommit(text)
        group.requestSaveIfUnsaved()
    }

    /// 要上屏的文字，取一次就清空。
    public func takeCommit() -> String? {
        guard !commit.isEmpty else { return nil }
        defer { commit = "" }
        return commit
    }

    /// 该不该存用户词库（几个会话共用一个计数），取一次就清零。
    public func takeSaveRequest() -> Bool {
        group.takeSaveRequest()
    }

    public var isComposing: Bool {
        guard let input = wowtype_session_input(raw) else { return false }
        return input.pointee != 0
    }

    public func snapshot() -> SessionSnapshot {
        guard let f = wowtype_session_frame(raw)?.pointee else { return .empty }
        // 先把 frame 里的字符串拷出来，再调别的会话函数
        let text = string(f.preedit)
        let aux = string(f.aux)
        let offset = Int(f.cand_offset)
        let count = Int(f.cand_count)
        let cursor = Int(f.cand_cursor)
        let grid = f.panel == Int32(WOWTYPE_PANEL_GRID)
        let hasPrev = f.has_prev != 0, hasNext = f.has_next != 0
        let cursorBytes = Int(f.preedit_cursor)
        let plainBytes = string(wowtype_session_selected_text(raw)).utf8.count

        var items: [SessionSnapshot.Candidate] = []
        items.reserveCapacity(count)
        var info = WowtypeCandidateInfo()
        for i in 0..<count {
            info.size = UInt32(MemoryLayout<WowtypeCandidateInfo>.size)
            guard wowtype_session_candidate_info(raw, offset + i, &info) == 0 else { break }
            items.append(.init(text: CandidateLabels.display(string(info.text)),
                               label: CandidateLabels.label(index: i, grid: grid, offset: offset, cursor: cursor)))
        }
        return SessionSnapshot(
            composing: !text.isEmpty,
            preedit: MarkedTextLayout(text: text, plainBytes: plainBytes, cursorBytes: cursorBytes),
            aux: aux,
            candidates: items,
            cursor: cursor,
            columns: grid && !items.isEmpty ? Int(WOWTYPE_GRID_COLS) : 0,
            vertical: vertical,
            hasPrevPage: hasPrev,
            hasNextPage: hasNext,
            asciiMode: group.english)
    }

    private func string(_ p: UnsafePointer<CChar>?) -> String {
        p.map { String(cString: $0) } ?? ""
    }
}
