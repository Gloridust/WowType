// v + 空格的工具栏（剪贴板、常用语、符号、表情）和表情面板，照 Linux 外壳做（fcitx5-addon/src/wowtype_engine.cpp
// 的 openTool、handleToolKey、openEmojiPanel、handleEmojiPanelKey），说明见 docs/CONFIG.md「v + 空格：工具栏」。
//
// 会话还不管这些（docs/ABI.md 的 handled）：外壳自己记状态、自己摆候选框。工具栏是竖排一列（一页 9 个，
// 数字键选这一页的第几个），表情面板是 6 列的网格（一屏 6 行，数字键选光标所在行的第几个）。
//
// 不依赖 AppKit。系统剪贴板由外壳读（Composer.sampleClipboard），读到的交给核心记（ClipboardHistory）。

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

/// 工具栏、表情面板里的一项。
struct ToolItem: Equatable {
    /// 候选框里显示的（换行显示成 ⏎，太长的截断）
    var shown: String
    /// 选了上屏的
    var commit: String
}

struct ToolState {
    var panel: ToolPanel
    var items: [ToolItem] = []
    /// 光标在 items 里的位置（不分页）
    var cursor = 0
    /// 表情面板的搜索词（打拼音或英文）
    var query = ""
}

enum ToolLimits {
    /// 工具栏一页几个
    static let pageSize = 9
    /// 表情面板一屏几行（每行 CandidatePage.columns 个，和展开面板一样 6 × 6）
    static let gridRows = 6
    /// 表情面板最多列这么多个（不搜索时是全部 emoji）
    static let maxEmoji = 2000
    static let menu = ["剪贴板", "常用语", "符号", "表情"]
    /// 列表里一行最多显示几个字
    static let lineChars = 40
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

/// 最近用过的 emoji（最近的在前，最多 18 个，正好三行），表情面板里排最前。存在数据目录的 emoji-recent.txt，
/// 一行一个，和 Linux 的 ~/.local/share/wowtype/emoji-recent.txt 一样。一个进程一份，所有输入框共用。
public final class RecentEmoji {
    public static let shared = RecentEmoji()
    public static let limit = 18

    /// 存在哪；nil 只记在内存里。第一次用到时才读。
    public var path: String? {
        didSet {
            list = []
            loaded = false
        }
    }

    private var list: [String] = []
    private var loaded = false

    public init(path: String? = nil) {
        self.path = path
    }

    public var items: [String] {
        load()
        return list
    }

    public func remember(_ emoji: String) {
        guard !emoji.isEmpty else { return }
        load()
        list.removeAll { $0 == emoji }
        list.insert(emoji, at: 0)
        if list.count > RecentEmoji.limit {
            list.removeLast(list.count - RecentEmoji.limit)
        }
        guard let path, let f = fopen(path, "w") else { return }
        fputs(list.map { $0 + "\n" }.joined(), f)
        fclose(f)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let path, let text = readFile(path) else { return }
        list = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init).filter { !$0.isEmpty }
        if list.count > RecentEmoji.limit {
            list.removeLast(list.count - RecentEmoji.limit)
        }
    }
}

extension Composer {
    /// 开着的工具栏 / 表情面板；nil 是没开。
    public var openPanel: ToolPanel? { tool?.panel }

    // MARK: 打开、关上

    /// 打字途中只打了一个 v 再按空格：打开工具栏（vim、vscode 这些照常打字，v1+2*3 照常算算式）。
    /// 设置里关了、双拼（v 是双拼的键）时不开。
    func opensToolbar(_ key: KeyInput) -> Bool {
        guard key.keysym == 0x20, config.toolbar, !config.shuangpin, input == "v", selectedText.isEmpty,
              wowtype_session_frame(session)?.pointee.panel != 1
        else {
            return false
        }
        wowtype_session_reset(session, 0)
        openTool(.menu)
        return true
    }

    /// 打开工具栏的一页（菜单、剪贴板、常用语）。
    func openTool(_ panel: ToolPanel) {
        var state = ToolState(panel: panel)
        switch panel {
        case .menu:
            state.items = ToolLimits.menu.map { ToolItem(shown: $0, commit: "") }
        case .clipboard:
            if config.clipboardHistory {
                sampleClipboard?()
                state.items = readCandidates(wowtype_clipboard_history()).map {
                    ToolItem(shown: toolLine($0.text), commit: $0.commit)
                }
            }
        case .phrases:
            if let engine {
                // 自定义词按 custom.tsv 的顺序：「编码　词」
                state.items = readCandidates(wowtype_engine_custom_phrases(engine.handle)).map {
                    ToolItem(shown: $0.code.isEmpty ? toolLine($0.text) : $0.code + "\u{3000}" + toolLine($0.text),
                             commit: $0.commit)
                }
            }
        case .emoji(let symbols):
            openEmoji(symbols: symbols)
            return
        }
        tool = state
        refresh()
    }

    /// 表情面板快捷键：开着就关上。打了一半的拼音拿来当搜索词（xiao + 快捷键 → 笑相关的 emoji）；
    /// 已经选了词的，先把打的原样上屏（和回车一样）。
    func toggleEmojiPanel() {
        if tool?.panel.isEmoji == true {
            closeTool()
            return
        }
        var query = ""
        if isComposing {
            if selectedText.isEmpty {
                // 只要字母（隔音符、数字不算）
                query = String(String.UnicodeScalarView(remaining.unicodeScalars.filter(\.isASCIILetter))).lowercased()
                wowtype_session_reset(session, 0)
            } else {
                commitInput()
            }
        }
        openEmoji(symbols: false, query: query)
    }

    func openEmoji(symbols: Bool, query: String = "") {
        tool = ToolState(panel: .emoji(symbols: symbols), query: query)
        searchEmoji()
        refresh()
    }

    func closeTool() {
        guard tool != nil else { return }
        tool = nil
        refresh()
    }

    /// 按搜索词重新列表情面板，光标回到第一个。
    private func searchEmoji() {
        guard var state = tool, case .emoji(let symbols) = state.panel else { return }
        var texts: [String] = []
        var seen = Set<String>()
        func add(_ text: String) {
            if seen.insert(text).inserted {
                texts.append(text)
            }
        }
        if state.query.isEmpty && symbols {
            readCandidates(wowtype_symbol_list()).forEach { add($0.text) }
        } else {
            if state.query.isEmpty {
                recentEmoji.items.forEach(add)
            }
            // 拼音（经引擎转成中文词）、英文、符号名一起找；引擎还没载入好时只按英文和符号名
            readCandidates(wowtype_engine_emoji_search(engine?.handle, state.query, ToolLimits.maxEmoji))
                .forEach { add($0.text) }
        }
        state.items = texts.map { ToolItem(shown: $0, commit: $0) }
        state.cursor = 0
        tool = state
    }

    // MARK: 按键

    /// 工具栏或表情面板开着时的按键。返回 false 的只有带 Control / Option / Command 的组合键：
    /// 收起面板，交给应用（复制粘贴等）。别的键都吃掉，免得打进应用。
    func handleToolKey(_ key: KeyInput) -> Bool {
        guard let state = tool else { return false }
        if !key.modifiers.isDisjoint(with: [.control, .option, .command]) {
            closeTool()
            return false
        }
        if state.panel.isEmoji {
            handleEmojiKey(key, state)
        } else {
            handleListKey(key, state)
        }
        return true
    }

    private func handleListKey(_ key: KeyInput, _ state: ToolState) {
        var state = state
        let n = state.items.count
        let size = ToolLimits.pageSize
        let pageStart = state.cursor / size * size
        switch key.keysym {
        case Keysym.escape:
            closeTool()
            return
        case Keysym.backspace:
            // 退格返回上一层，在菜单里就关上
            if state.panel == .menu {
                closeTool()
            } else {
                openTool(.menu)
            }
            return
        case 0x20, Keysym.returnKey, Keysym.keypadEnter:
            if n == 0 {
                closeTool()
            } else {
                selectTool(min(state.cursor, n - 1))
            }
            return
        case Keysym.down, Keysym.right:
            state.cursor = min(state.cursor + 1, max(n - 1, 0))
        case Keysym.up, Keysym.left:
            state.cursor = max(state.cursor - 1, 0)
        case Keysym.pageDown, 0x3d, 0x2e, 0x5d: // = . ]
            if pageStart + size < n {
                state.cursor = pageStart + size
            }
        case Keysym.pageUp, 0x2d, 0x2c, 0x5b: // - , [
            state.cursor = pageStart >= size ? pageStart - size : 0
        default:
            if key.isDigit, let c = key.ascii, c > 0x30, pageStart + Int(c - 0x31) < n {
                selectTool(pageStart + Int(c - 0x31))
                return
            }
        }
        tool = state
        refresh()
    }

    private func handleEmojiKey(_ key: KeyInput, _ state: ToolState) {
        var state = state
        let n = state.items.count
        let columns = CandidatePage.columns
        switch key.keysym {
        case Keysym.escape:
            closeTool()
            return
        case Keysym.backspace:
            // 删搜索词的最后一个字母，删空了再按就关上
            if state.query.isEmpty {
                closeTool()
                return
            }
            state.query.removeLast()
            tool = state
            searchEmoji()
            refresh()
            return
        case 0x20, Keysym.returnKey, Keysym.keypadEnter:
            if n == 0 {
                closeTool()
            } else {
                commitTool(min(state.cursor, n - 1))
            }
            return
        default:
            break
        }
        if key.isLetter, let c = key.ascii {
            state.query.append(Character(UnicodeScalar(c | 0x20)))
            tool = state
            searchEmoji()
            refresh()
            return
        }
        guard n > 0 else { return }
        let screen = columns * ToolLimits.gridRows
        var cursor = state.cursor
        switch key.keysym {
        case Keysym.left:
            cursor = max(cursor - 1, 0)
        case Keysym.right:
            cursor = min(cursor + 1, n - 1)
        case Keysym.up:
            // 第一行再往上：不动（不像展开面板那样收起）
            if cursor >= columns {
                cursor -= columns
            }
        case Keysym.down:
            if cursor + columns < n {
                cursor += columns
            } else if cursor / columns + 1 < (n + columns - 1) / columns {
                cursor = n - 1 // 最后一行不满时落到最后一个
            }
        case Keysym.pageDown, 0x3d: // =
            cursor = min(n - 1, cursor + screen)
        case Keysym.pageUp, 0x2d: // -
            cursor = cursor >= screen ? cursor - screen : cursor % columns
        default:
            if key.isDigit, let c = key.ascii {
                let digit = Int(c) - 0x30
                let index = cursor / columns * columns + digit - 1
                if digit >= 1 && digit <= columns && index < n {
                    commitTool(index)
                }
            }
            return
        }
        state.cursor = cursor
        tool = state
        refresh()
    }

    /// 选工具栏里的第 index 项：菜单进下一层，剪贴板、常用语、表情上屏。
    func selectTool(_ index: Int) {
        guard let state = tool, index >= 0, index < state.items.count else { return }
        guard state.panel == .menu else {
            commitTool(index)
            return
        }
        switch index {
        case 0: openTool(.clipboard)
        case 1: openTool(.phrases)
        case 2: openEmoji(symbols: true)
        default: openEmoji(symbols: false)
        }
    }

    private func commitTool(_ index: Int) {
        guard let state = tool, index < state.items.count else { return }
        let text = state.items[index].commit
        tool = nil
        insert(text)
        if case .emoji(symbols: false) = state.panel {
            recentEmoji.remember(text)
        }
        refresh()
    }

    // MARK: 画

    /// 照工具栏 / 表情面板的状态画编辑区和候选框。
    func drawTool(_ state: ToolState) {
        let n = state.items.count
        guard case .emoji(let symbols) = state.panel else {
            client?.setMarkedText("", cursor: 0)
            let size = ToolLimits.pageSize
            let start = n == 0 ? 0 : min(state.cursor, n - 1) / size * size
            let end = min(n, start + size)
            client?.showCandidates(CandidatePage(
                texts: state.items[start..<end].map(\.shown), cursor: state.cursor - start,
                hasPrev: start > 0, hasNext: end < n, expanded: false, aux: toolHint(state), vertical: true))
            return
        }
        // 搜索词放在编辑区
        client?.setMarkedText(state.query, cursor: state.query.utf16.count)
        let name = symbols ? "符号" : "表情"
        let hint = state.query.isEmpty ? "\(name)：打拼音或英文搜索，Esc 关闭"
            : n == 0 ? "\(name)：没找到「\(state.query)」" : "\(name)：\(state.query)"
        let screen = CandidatePage.columns * ToolLimits.gridRows
        let start = n == 0 ? 0 : min(state.cursor, n - 1) / screen * screen
        let end = min(n, start + screen)
        client?.showCandidates(CandidatePage(
            texts: state.items[start..<end].map(\.shown), cursor: state.cursor - start,
            hasPrev: start > 0, hasNext: end < n, expanded: true, aux: hint))
    }

    private func toolHint(_ state: ToolState) -> String {
        let empty = state.items.isEmpty
        switch state.panel {
        case .menu:
            return "工具栏：数字键选择，Esc 关闭"
        case .clipboard:
            if !empty {
                return "剪贴板：选一条上屏，退格返回"
            }
            return config.clipboardHistory ? "剪贴板：还没有记录，复制过的文字会出现在这里"
                : "剪贴板：没打开，在设置（wowtype.conf）里写 ClipboardHistory=True"
        case .phrases:
            return empty ? "常用语：还没有，在菜单「编辑自定义词」里添加" : "常用语：选一条上屏，退格返回"
        case .emoji:
            return ""
        }
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

/// 列表里一行显示的样子：换行换成 ⏎，制表符、回车换成空格，超过 40 个字截断加 …
func toolLine(_ text: String) -> String {
    var out = ""
    var count = 0
    for c in text {
        if count == ToolLimits.lineChars {
            out += "…"
            break
        }
        switch c {
        case "\n", "\r\n": out += "⏎"
        case "\t", "\r": out += " "
        default: out.append(c)
        }
        count += 1
    }
    return out
}

private extension Unicode.Scalar {
    var isASCIILetter: Bool {
        (value >= 0x61 && value <= 0x7a) || (value >= 0x41 && value <= 0x5a)
    }
}
