// 自定义词（常用语）：~/Library/Application Support/WowType/custom.tsv，格式同 Linux 的
// ~/.local/share/wowtype/custom.tsv：一行一个「编码<TAB>词[<TAB>频次]」，# 开头是注释。
//
// 设置窗口的「自定义词」页用：加词、删词、导入、导出，规则照 Linux 设置界面（settings/wowtype-config 的
// read_custom_words / parse_custom_words / merge_custom_words / normalize_code）。比 Linux 多一点：
// 没动过的行（注释、频次列）原样写回去。
//
// 不依赖 Foundation：按键测试在 Linux 上也编。编码整理（拼音切音节）、猜拼音用核心的。

import CWowtype

public struct CustomWords: Equatable {
    public struct Entry: Equatable {
        /// 编码：拼音（空格分开音节）或 mail 这类字母
        public var code: String
        /// 词，转义原样（文件里的 \n 表示换行）
        public var word: String

        public init(code: String, word: String) {
            self.code = code
            self.word = word
        }
    }

    private enum Line: Equatable {
        case entry(Entry, raw: String)
        case other(String)
    }

    private var lines: [Line]

    /// 新文件开头的说明（和 Linux 设置界面写的一样）
    public static let header = """
    # WowType 自定义词：编码<TAB>词。编码是拼音（空格分开音节），也可以是 mail 这类字母；
    # 词里写 \\n 表示换行。由 WowType 设置维护，也可以手动编辑。
    """

    /// 读文件的原文；nil（还没有文件）是只有说明的空表。
    public init(text: String?) {
        guard let text else {
            lines = CustomWords.header.split(separator: "\n").map { .other(String($0)) }
            return
        }
        var body = Substring(text)
        if body.hasPrefix("\u{FEFF}") {
            body = body.dropFirst()
        }
        // 按 \n 拆（\r\n 在 Swift 里是一个字符，要按码位拆），每行末尾的 \r 留着
        var parts = body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" {
            parts.removeLast()
        }
        lines = parts.map { raw in
            if let entry = CustomWords.entry(raw) {
                return .entry(entry, raw: raw)
            }
            return .other(raw)
        }
    }

    /// 文件里的词，按文件顺序（后加的在后面）。
    public var entries: [Entry] {
        lines.compactMap {
            if case .entry(let entry, _) = $0 { return entry }
            return nil
        }
    }

    /// 写回文件的原文：没动过的行原样，新加的是「编码<TAB>词」。
    public var text: String {
        lines.map {
            switch $0 {
            case .entry(_, let raw): return raw
            case .other(let raw): return raw
            }
        }.joined(separator: "\n") + "\n"
    }

    /// 加一个词（同一个词原来有就换成新编码，挪到最后）。返回原来有没有这个词。
    @discardableResult
    public mutating func add(code: String, word: String) -> Bool {
        let replaced = !remove(word: word).isEmpty
        let entry = Entry(code: code, word: word)
        lines.append(.entry(entry, raw: code + "\t" + word))
        return replaced
    }

    /// 删掉这个词（文件里写了几行都删），返回删掉的。
    @discardableResult
    public mutating func remove(word: String) -> [Entry] {
        var removed: [Entry] = []
        lines.removeAll {
            guard case .entry(let entry, _) = $0, entry.word == word else { return false }
            removed.append(entry)
            return true
        }
        return removed
    }

    /// 导入：同一个词用新的编码。返回 (新增几个, 更新几个)。
    public mutating func merge(_ incoming: [Entry]) -> (added: Int, updated: Int) {
        var added = 0
        var updated = 0
        for item in incoming {
            let old = entries.filter { $0.word == item.word }
            if old == [item] {
                continue
            }
            if old.isEmpty {
                added += 1
            } else {
                updated += 1
            }
            add(code: item.code, word: item.word)
        }
        return (added, updated)
    }

    /// 导入的文件：编码整理过（Ni Hǎo → ni hao），编码不对的行不要。
    public static func parseImport(_ text: String) -> [Entry] {
        CustomWords(text: text).entries.compactMap { entry in
            normalizeCode(entry.code).map { Entry(code: $0, word: entry.word) }
        }
    }

    /// 加词时检查词：不能空，不能有 TAB 和换行（换行写成 \\n）。
    public static func isValidWord(_ word: String) -> Bool {
        !word.isEmpty && !word.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" })
    }

    /// 一行：不是空行、注释，至少两列，第二列不空。两列都去掉两边的空白。
    private static func entry(_ raw: String) -> Entry? {
        var line = Substring(raw)
        if line.hasSuffix("\r") {
            line = line.dropLast()
        }
        if line.hasPrefix("#") || !line.contains(where: { !$0.isWhitespace }) {
            return nil
        }
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 2 else { return nil }
        let word = strip(cols[1])
        guard !word.isEmpty else { return nil }
        return Entry(code: strip(cols[0]), word: word)
    }
}

// MARK: 编码

extension CustomWords {
    /// 自定义词的编码：拼音整理成空格分开的音节；不是拼音但全是字母的（mail）原样小写。都不是返回 nil。
    /// 规则和音节表在核心里（wowtype_custom_code），Linux 的加载也照那份。
    public static func normalizeCode(_ text: String) -> String? {
        wowtype_custom_code(text, 0).map { String(cString: $0) }
    }

    /// 把打的拼音整理成空格分开的音节：Ni Hǎo、nihao、ni'hao、ni3hao3 → ni hao。不合法返回 nil。
    public static func normalizePinyin(_ text: String) -> String? {
        wowtype_custom_code(text, 1).map { String(cString: $0) }
    }
}

// MARK: 从词库猜拼音

extension CustomWords {
    /// 在词库原文（拼音<TAB>词<TAB>频次）里找词的拼音：整个词有就取频次最高的那条，没有就一个字一个字找。
    /// 猜不出（有词库里没有的字、英文）返回 nil。核心做（wowtype_guess_pinyin），和 Linux 设置界面的
    /// PinyinGuesser 规则一样。
    public static func guessPinyin(_ word: String, lexicon: UnsafeRawBufferPointer) -> String? {
        guard !word.isEmpty, let base = lexicon.baseAddress, lexicon.count > 0 else { return nil }
        return wowtype_guess_pinyin(base.assumingMemoryBound(to: CChar.self), lexicon.count, word)
            .map { String(cString: $0) }
    }
}

// MARK: 小工具

/// 去掉两边的空白（空格、TAB、回车）
private func strip(_ s: Substring) -> String {
    var s = s
    while let c = s.first, c.isWhitespace { s.removeFirst() }
    while let c = s.last, c.isWhitespace { s.removeLast() }
    return String(s)
}
