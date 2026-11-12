// v + 空格的工具栏（剪贴板、常用语、符号、表情）和表情面板，说明见 docs/CONFIG.md「v + 空格：工具栏」。
//
// 状态、按键、上屏都在会话里（和 Linux 同一份）：这里只是把会话给的条目、提示、搜索词画出来，
// 读系统剪贴板交给核心（ClipboardHistory），以及最近用过的 emoji 存在哪（RecentEmoji）。
// 工具栏是竖排一列（一页 9 个），表情面板是 6 列的网格（一屏 6 行）。
//
// 不依赖 AppKit。

import CWowtype
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// 开着的面板。
public enum ToolPanel: Equatable {
    /// v + 空格的工具栏：剪贴板、常用语、符号、表情
    case menu
    case clipboard
    case phrases
    /// 表情面板；symbols 是从工具栏「符号」进来的（不搜索时列全部符号，选的不记进最近用过）
    case emoji(symbols: Bool)

    public var isEmoji: Bool {
        if case .emoji = self { return true }
        return false
    }
}

/// 剪贴板历史：在核心里，只在内存，最多 20 条，最新的在前。输入法自己不碰系统剪贴板，外壳读到了交进来。
public enum ClipboardHistory {
    /// 记下一条（空白、超过 16 KB 的不记）；记下了返回 true。
    @discardableResult
    public static func remember(_ text: String) -> Bool {
        wowtype_clipboard_remember(text) == 1
    }

    public static func clear() {
        wowtype_clipboard_clear()
    }

    /// 记着的，最新的在前。
    public static var items: [String] {
        readCandidates(wowtype_clipboard_history()).map(\.commit)
    }
}

/// 最近用过的 emoji（最近的在前，最多 18 个，正好三行），表情面板里排最前。在核心里，一个进程一份，
/// 所有输入框共用；存在数据目录的 emoji-recent.txt，一行一个，和 Linux 的一样。
public final class RecentEmoji {
    public static let shared = RecentEmoji(memoryOnly: false)

    /// 存在哪；nil 只记在内存里（并清空）。
    public var path: String? {
        didSet { wowtype_recent_emoji_path(path ?? "") }
    }

    private init(memoryOnly: Bool) {}

    /// 换一个存的地方（nil：只记在内存里，并清空；测试用）。
    public init(path: String? = nil) {
        self.path = path
        wowtype_recent_emoji_path(path ?? "")
    }

    public var items: [String] {
        readCandidates(wowtype_recent_emoji_list()).map(\.text)
    }
}

extension Composer {
    /// 开着的工具栏 / 表情面板；nil 是没开。
    public var openPanel: ToolPanel? {
        switch wowtype_session_open_panel(session) {
        case WOWTYPE_TOOL_MENU: return .menu
        case WOWTYPE_TOOL_CLIPBOARD: return .clipboard
        case WOWTYPE_TOOL_PHRASES: return .phrases
        case WOWTYPE_TOOL_SYMBOLS: return .emoji(symbols: true)
        case WOWTYPE_TOOL_EMOJI: return .emoji(symbols: false)
        default: return nil
        }
    }

    /// 打开工具栏的一页或表情面板（菜单、按钮用；v + 空格会话自己开）。
    func openTool(_ panel: ToolPanel) {
        let raw: Int32
        switch panel {
        case .menu: raw = WOWTYPE_TOOL_MENU
        case .clipboard: raw = WOWTYPE_TOOL_CLIPBOARD
        case .phrases: raw = WOWTYPE_TOOL_PHRASES
        case .emoji(let symbols): raw = symbols ? WOWTYPE_TOOL_SYMBOLS : WOWTYPE_TOOL_EMOJI
        }
        if panel == .clipboard && config.clipboardHistory {
            sampleClipboard?()
        }
        apply(wowtype_session_open_tool(session, raw))
    }

    /// 表情面板快捷键：开着就关上；打了一半的拼音拿来当搜索词，已经选了词的先上屏（会话做）。
    func toggleEmojiPanel() {
        apply(wowtype_session_toggle_emoji_panel(session))
    }

    func closeTool() {
        guard openPanel != nil else { return }
        apply(wowtype_session_open_tool(session, WOWTYPE_TOOL_NONE))
    }

    /// 工具栏或表情面板开着时的按键（会话做）。返回 false 的只有带 Control / Option / Command 的组合键：
    /// 会话收起面板，交给应用（复制粘贴等）。别的键都吃掉，免得打进应用。
    func handleToolKey(_ key: KeyInput) -> Bool {
        if openPanel == .menu && config.clipboardHistory {
            sampleClipboard?() // 下一步可能进「剪贴板」页
        }
        if sendToSession(key) {
            return true
        }
        refresh()
        return false
    }

    /// 照会话给的工具栏 / 表情面板画编辑区（表情的搜索词）和候选框。
    func drawTool() {
        guard let frame = wowtype_session_frame(session) else { return }
        let f = frame.pointee
        let query = String(cString: f.preedit)
        client?.setMarkedText(query, cursor: query.utf16.count)
        var texts: [String] = []
        for i in 0..<f.cand_count {
            if let text = wowtype_session_candidate(session, i) {
                texts.append(String(cString: text))
            }
        }
        let aux = f.aux.map { String(cString: $0) }
        let emoji = f.panel == WOWTYPE_PANEL_EMOJI
        client?.showCandidates(CandidatePage(
            texts: texts, cursor: Int(f.cand_cursor), hasPrev: f.has_prev != 0, hasNext: f.has_next != 0,
            expanded: emoji, aux: aux, vertical: !emoji))
    }
}

/// 核心给的候选集合（wowtype_candidates_*）读出来，读完释放。commit 是选了上屏的，code 是编码（拼音）。
func readCandidates(_ raw: OpaquePointer?) -> [(text: String, commit: String, code: String)] {
    guard let raw else { return [] }
    defer { wowtype_candidates_free(raw) }
    var out: [(text: String, commit: String, code: String)] = []
    for i in 0..<wowtype_candidates_len(raw) {
        guard let text = wowtype_candidates_text(raw, i) else { continue }
        let shown = String(cString: text)
        let commit = wowtype_candidates_commit(raw, i).map { String(cString: $0) } ?? shown
        let code = wowtype_candidates_pinyin(raw, i).map { String(cString: $0) } ?? ""
        out.append((shown, commit, code))
    }
    return out
}
