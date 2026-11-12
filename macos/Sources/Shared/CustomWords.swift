// 自定义词（常用语）：~/Library/Application Support/WowType/custom.tsv，格式同 Linux 的
// ~/.local/share/wowtype/custom.tsv：一行一个「编码<TAB>词[<TAB>频次]」，# 开头是注释。
//
// 设置窗口的「自定义词」页用：加词、删词、导入、导出，规则照 Linux 设置界面（settings/wowtype-config 的
// read_custom_words / parse_custom_words / merge_custom_words / normalize_code）。比 Linux 多一点：
// 没动过的行（注释、频次列）原样写回去。
//
// 不依赖 Foundation：按键测试在 Linux 上也编。

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

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
    /// 合法拼音音节（和 core/src/syllable.rs 的 SYLLABLES、Linux 设置界面的 SYLLABLES 一致）
    static let syllables: Set<String> = Set("""
    a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu ca cai can cang cao
    ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui
    chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei den deng di dia dian diao die
    ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng fiao fo fou fu ga gai
    gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei
    hen heng hm hng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing
    jiong jiu ju juan jue jun jv jvan jve jvn ka kai kan kang kao ke kei ken keng kong kou ku kua kuai
    kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo
    long lou lu luan lun luo lv lve ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo
    mou mu na nai nan nang nao ne nei nen neng ng ni nian niang niao nie nin ning niu nong nou nu nuan
    nun nuo nv nve o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian
    qiang qiao qie qin qing qiong qiu qu quan que qun qv qvan qve qvn ran rang rao re ren reng ri rong
    rou ru rua ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei shen
    sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan
    tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng
    wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun xv xvan xve xvn ya yan yang yao
    ye yi yin ying yo yong you yu yuan yue yun yv yvan yve yvn za zai zan zang zao ze zei zen zeng zha
    zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo
    zi zong zou zu zuan zui zun zuo
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// 自定义词的编码：拼音整理成空格分开的音节；不是拼音但全是字母的（mail）原样小写。都不是返回 nil。
    public static func normalizeCode(_ text: String) -> String? {
        if let pinyin = normalizePinyin(text) {
            return pinyin
        }
        let code = strip(Substring(text)).lowercased().filter { $0 != "'" }
        guard !code.isEmpty, code.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else {
            return nil
        }
        return code
    }

    /// 把打的拼音整理成空格分开的音节：Ni Hǎo、nihao、ni'hao、ni3hao3 → ni hao。不合法返回 nil。
    public static func normalizePinyin(_ text: String) -> String? {
        var plain = String.UnicodeScalarView()
        for scalar in strip(Substring(text)).lowercased().unicodeScalars {
            if let base = toneless[scalar] {
                plain.append(base)
            } else if (scalar == "\u{308}" || scalar == ":") && plain.last == "u" {
                plain.removeLast()  // u + 分音符（没合成一个字的 ü）、u: 都是 v
                plain.append("v")
            } else if ("0"..."9").contains(scalar) || (0x300...0x36F).contains(scalar.value) {
                continue  // 数字声调、单独的声调符号
            } else {
                plain.append(scalar)
            }
        }
        var result: [String] = []
        let tokens = String(plain).split(whereSeparator: { $0 == "'" || $0 == "’" || $0.isWhitespace })
        for token in tokens.map(String.init) {
            if syllables.contains(token) {
                result.append(token)
            } else if token == "r" && !result.isEmpty {
                result.append(token)  // 儿化
            } else if let parts = splitSyllables(token) {
                result += parts
            } else {
                return nil
            }
        }
        return result.isEmpty ? nil : result.joined(separator: " ")
    }

    /// nihao → [ni, hao]：音节数最少，一样多时前面的取长的。切不开返回 nil。
    static func splitSyllables(_ text: String) -> [String]? {
        let chars = Array(text)
        let n = chars.count
        // best[i]：从 i 切到最后最少几个音节、第一个多长
        var best = [(count: Int, length: Int)?](repeating: nil, count: n + 1)
        best[n] = (0, 0)
        if n > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for length in stride(from: min(6, n - i), through: 1, by: -1) {
                    guard let rest = best[i + length], syllables.contains(String(chars[i..<i + length])) else {
                        continue
                    }
                    if best[i] == nil || rest.count + 1 < best[i]!.count {
                        best[i] = (rest.count + 1, length)
                    }
                }
            }
        }
        guard best[0] != nil else { return nil }
        var parts: [String] = []
        var i = 0
        while i < n {
            let length = best[i]!.length
            parts.append(String(chars[i..<i + length]))
            i += length
        }
        return parts
    }

    /// 带声调的字母 → 不带的（ü 是 v）
    private static let toneless: [Unicode.Scalar: Unicode.Scalar] = {
        var map: [Unicode.Scalar: Unicode.Scalar] = [:]
        let table: [(Unicode.Scalar, String)] = [("a", "āáǎà"), ("e", "ēéěèê"), ("i", "īíǐì"), ("o", "ōóǒò"),
                                                 ("u", "ūúǔù"), ("v", "üǖǘǚǜ"), ("n", "ńňǹ"), ("m", "ḿ")]
        for (base, marked) in table {
            for scalar in marked.unicodeScalars {
                map[scalar] = base
            }
        }
        return map
    }()
}

// MARK: 从词库猜拼音

extension CustomWords {
    /// 在词库原文（拼音<TAB>词<TAB>频次）里找词的拼音：整个词有就取频次最高的那条，没有就一个字一个字找。
    /// 猜不出（有词库里没有的字、英文）返回 nil。和 Linux 设置界面的 PinyinGuesser 一样。
    public static func guessPinyin(_ word: String, lexicon: UnsafeRawBufferPointer) -> String? {
        guard !word.isEmpty, lexicon.count > 0 else { return nil }
        if let found = lookup(word, lexicon) {
            return normalizePinyin(found)
        }
        var readings: [String] = []
        for char in word {
            guard let reading = lookup(String(char), lexicon) else { return nil }
            readings.append(reading)
        }
        return normalizePinyin(readings.joined(separator: " "))
    }

    private static func lookup(_ word: String, _ data: UnsafeRawBufferPointer) -> String? {
        let needle = Array(("\t" + word + "\t").utf8)
        let bytes = data.bindMemory(to: UInt8.self)
        var best: String?
        var bestFreq = -1.0
        var from = 0
        while let pos = find(needle, in: bytes, from: from) {
            var start = pos
            while start > 0, bytes[start - 1] != 0x0A {
                start -= 1
            }
            var end = pos + needle.count
            while end < bytes.count, bytes[end] != 0x0A {
                end += 1
            }
            let freqText = strip(Substring(String(decoding: bytes[(pos + needle.count)..<end], as: UTF8.self)))
            let freq = Double(freqText) ?? 0
            if freq > bestFreq {
                best = String(decoding: bytes[start..<pos], as: UTF8.self)
                bestFreq = freq
            }
            from = end
        }
        return best
    }

    private static func find(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Int? {
        guard let base = bytes.baseAddress, from < bytes.count, needle.count <= bytes.count - from else {
            return nil
        }
        #if canImport(Darwin)
        let hit = needle.withUnsafeBytes { n in
            memmem(base + from, bytes.count - from, n.baseAddress, n.count)
        }
        guard let hit else { return nil }
        return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        #else
        var i = from
        let last = bytes.count - needle.count
        while i <= last {
            guard let p = memchr(base + i, Int32(needle[0]), last - i + 1) else { return nil }
            i = base.distance(to: p.assumingMemoryBound(to: UInt8.self))
            if memcmp(base + i, needle, needle.count) == 0 {
                return i
            }
            i += 1
        }
        return nil
        #endif
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
