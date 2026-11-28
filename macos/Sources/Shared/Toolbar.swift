// v + 空格的工具栏（剪贴板、常用语、符号、表情）和表情面板，说明见 docs/CONFIG.md「v + 空格：工具栏」。
//
// 状态、按键、上屏都在会话里（和 Linux 同一份）：这里只是把会话给的条目、提示、搜索词画出来，
// 读系统剪贴板交给核心（ClipboardHistory），以及最近用过的 emoji 存在哪（RecentEmoji）。
// 工具栏是竖排一列（一页 9 个），表情面板是 6 列的网格（一屏 6 行）。
//
// 不依赖 AppKit。

import CWowtype
import Foundation
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

/// 剪贴板历史的一条（设置窗口列出来用）。
public struct ClipboardEntry: Equatable {
    public let text: String
    /// 记下（最近一次复制）的时间，Unix 秒
    public let time: Int
    /// 复制时在用的应用，不知道是空串
    public let app: String
    /// 别的设备复制过来的：那台设备的名字
    public let device: String

    public init(text: String, time: Int, app: String = "", device: String = "") {
        self.text = text
        self.time = time
        self.app = app
        self.device = device
    }

    /// 从哪来的：别的设备的是「来自 那台」，本机的是应用名
    public var source: String { device.isEmpty ? app : "来自 \(device)" }
}

/// 剪贴板历史（docs/CONFIG.md「剪贴板历史」）：在核心里。输入法进程每秒看一次系统剪贴板，变了交给
/// observe；设置里开着时存在数据目录的 clipboard-history.json（只有自己能读，最多 200 条），
/// 设置窗口那个进程读同一个文件、删条目。关着时只在内存里（跨设备收到的）。
public enum ClipboardHistory {
    public static let fileName = "clipboard-history.json"

    public static let warning = "打开以后，WowType 每秒看一次剪贴板，把复制过的文字存在这台 Mac 上"
        + "（最多 200 条，只有你自己能读），打 v 再按空格、或者在这一页里能找回来。\n\n"
        + "密码管理器标了「不要记」的（1Password、钥匙串这类）不记；没标的密码会被记下并显示出来，"
        + "可以到这一页删掉那一条。\n\n记录不上传。关掉开关时全部删掉。"

    public static let info = "打开后每秒看一次剪贴板，复制过的文字都记下来（最多 200 条，每条最多 16 KB；"
        + "图片、文件不记），最新的在前，同一段复制两次只留一条。\n\n"
        + "打字时打 v 再按空格，选「剪贴板」，数字键上屏，Control+Delete 删掉光标处那一条。"
        + "这一页能搜索、复制回剪贴板、删除。\n\n"
        + "记录存在 ~/Library/Application Support/WowType/clipboard-history.json，只有自己能读；"
        + "超过「保留多久」的自动删掉，关掉开关时全部删掉。跨设备复制粘贴收到的也在这里。"

    /// 「保留多久」的选项（ClipboardHistoryDays）
    public static let keepChoices: [(String, Int)] = [("1 天", 1), ("7 天", 7), ("30 天", 30), ("一直留着", 0)]

    /// 存在哪、留几天（0 不按时间删）。path 是 nil：只记在内存里，原来存在文件里的连文件一起删掉。返回有几条。
    @discardableResult
    public static func configure(path: String?, keepDays: Int) -> Int {
        Int(wowtype_clipboard_configure(path ?? "", Int32(clamping: keepDays)))
    }

    /// 系统剪贴板现在是 text（复制的不是文字时传空串）；和上次报的一样就不记。记下了返回 true。
    @discardableResult
    public static func observe(_ text: String, app: String = "") -> Bool {
        wowtype_clipboard_observe(text, app) == 1
    }

    /// 等于 observe(text)。
    @discardableResult
    public static func remember(_ text: String) -> Bool {
        wowtype_clipboard_remember(text) == 1
    }

    public static func clear() {
        wowtype_clipboard_clear()
    }

    /// 删掉文字是 text 的那条；删掉了返回 true。
    @discardableResult
    public static func forget(_ text: String) -> Bool {
        wowtype_clipboard_forget(text) == 1
    }

    /// 记着的文字，最新的在前。
    public static var items: [String] {
        readCandidates(wowtype_clipboard_history()).map(\.commit)
    }

    /// 全部记录，最新的在前。
    public static var entries: [ClipboardEntry] {
        guard let raw = wowtype_clipboard_entries_json(),
              let data = String(cString: raw).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let text = item["text"] as? String else { return nil }
            return ClipboardEntry(text: text, time: (item["time"] as? NSNumber)?.intValue ?? 0,
                                  app: item["app"] as? String ?? "", device: item["device"] as? String ?? "")
        }
    }

    /// 列表里的一行：换行显示成 ⏎，连着的空格、制表符并成一个，太长的截断（和 Linux 设置界面的一样）。
    public static func preview(_ text: String, limit: Int = 120) -> String {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
        var shown = ""
        var lastBlank = false
        for ch in lines {
            let blank = ch == " " || ch == "\t"
            if blank && lastBlank { continue }
            shown.append(blank ? " " : ch)
            lastBlank = blank
        }
        guard shown.count > limit else { return shown }
        return String(shown.prefix(limit - 1)) + "…"
    }

    /// 「刚才」「5 分钟前」「3 小时前」「07:00」「昨天 14:02」「11月20日 14:02」「2025年11月20日」（和 Linux 的一样）。
    public static func when(_ time: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let ago = Int(now.timeIntervalSince1970) - time
        if ago < 60 { return "刚才" }
        if ago < 3600 { return "\(ago / 60) 分钟前" }
        let then = Date(timeIntervalSince1970: TimeInterval(time))
        let sameDay = calendar.isDate(then, inSameDayAs: now)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: then)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if ago < 12 * 3600 || sameDay {
            return !sameDay || ago < 6 * 3600 ? "\(ago / 3600) 小时前" : clock
        }
        if calendar.isDate(then, inSameDayAs: now.addingTimeInterval(-86400)) {
            return "昨天 \(clock)"
        }
        if parts.year == calendar.component(.year, from: now) {
            return "\(parts.month ?? 0)月\(parts.day ?? 0)日 \(clock)"
        }
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
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
