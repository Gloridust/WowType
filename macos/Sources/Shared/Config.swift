// 设置：~/Library/Application Support/WowType/wowtype.conf。
//
// 键名、取值、默认值和 Linux 的 ~/.config/fcitx5/conf/wowtype.conf 一样（fcitx5-addon/src/wowtype_engine.h
// 的 WowtypeConfig，说明见 docs/CONFIG.md），一份配置两边都能用。文件不存在、少写了哪一项就用默认值；
// 不认识的键（工具栏、语音这些 macOS 还没有的）不管。互译的 API Key 不在这里（这个文件谁都能读），
// 在同一个目录的 translate.key（0600，见 TranslateKeyFile）。
//
// 不依赖 Foundation / AppKit：按键测试在 Linux 上也编。

import CWowtype
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public struct WowtypeConfig: Equatable {
    public enum ShiftToggle: String, CaseIterable {
        case both = "Both", left = "Left", right = "Right", off = "Off"
    }

    public enum SelectKeys: String, CaseIterable {
        case off = "Off", semicolon = "Semicolon", semicolonQuote = "SemicolonQuote"
    }

    /// 双拼方案在配置文件里的名字（和 Linux 一样），核心也认小写、别名。
    public static let shuangpinSchemes = ["Ziranma", "Xiaohe", "Microsoft", "Sogou", "ABC", "Ziguang", "PinyinJiajia"]

    /// 互译语言（和 Linux 的 WowtypeTranslateTarget、核心的 translate::LANGUAGES 一样）。
    public static let translateTargets = ["en", "ja", "ko", "fr", "de", "es", "ru", "pt", "it", "vi", "th", "id", "ar"]

    public var horizontal = true
    public var pageSize = 9
    public var pageKeysMinus = true
    public var pageKeysBracket = false
    public var pageKeysComma = false
    public var pageKeysTab = false
    public var fuzzy = false
    public var fuzzyZh = true
    public var fuzzyCh = true
    public var fuzzySh = true
    public var fuzzyNL = false
    public var fuzzyFH = false
    public var fuzzyRL = false
    public var fuzzyAn = true
    public var fuzzyEn = true
    public var fuzzyIn = true
    public var fuzzyIan = true
    public var fuzzyUan = true
    public var fuzzyUn = false
    public var typoCorrection = true
    public var rareExtChars = false
    public var shuangpin = false
    public var shuangpinScheme = "Ziranma"
    public var shiftToggle = ShiftToggle.both
    public var traditional = false
    public var halfwidthPunct = false
    public var selectKeys = SelectKeys.off
    public var pickChar = true
    public var dateTime = true
    public var calculator = true
    public var emojiSuggest = true
    public var autoSpace = false
    public var autoSpaceLetters = true
    public var autoSpaceDigits = true
    /// 词库文件，空串用安装包里的雾凇词库；文件不在也用自带的
    public var lexicon = ""
    /// 候选字号（磅），只有 macOS 有：Linux 上字号跟着 fcitx5 主题
    public var candidateFontSize = 17
    /// 互译（Shift 在 中 → 英 → 译 之间切）
    public var translate = false
    public var translateTarget = "en"
    /// 翻译服务（OpenAI 格式，如 https://api.openai.com/v1）和模型
    public var translateBaseUrl = ""
    public var translateModel = ""
    /// 译文用正式语气（默认聊天口吻）
    public var translateFormal = false
    /// 用本地模型（HY-MT）。和 Linux 一样，配置文件里没写这一项时是 False
    public var translateLocal = false
    /// 本地模型文件，留空用数据目录下 models/HY-MT1.5-1.8B-Q4_K_M.gguf
    public var translateLocalModel = ""
    /// llama-server 的路径，留空自己找
    public var translateLlamaServer = ""
    /// 本地模型闲置几分钟后释放内存，0–240，0 不释放
    public var translateIdleMinutes = 5

    public init() {}

    // MARK: 给核心的值

    /// 模糊音分组的位掩码（和核心的 syllable::fuzzy、Linux 的 applyConfig 一致）。
    public var fuzzyGroups: UInt32 {
        let groups: [(Bool, UInt32)] = [
            (fuzzyZh, 1), (fuzzyCh, 2), (fuzzySh, 4), (fuzzyNL, 8), (fuzzyFH, 16), (fuzzyRL, 32),
            (fuzzyAn, 64), (fuzzyEn, 128), (fuzzyIn, 256), (fuzzyIan, 512), (fuzzyUan, 1024), (fuzzyUn, 2048),
        ]
        return groups.reduce(0) { $0 | ($1.0 ? $1.1 : 0) }
    }

    public var pageKeys: UInt32 {
        (pageKeysMinus ? UInt32(WOWTYPE_PAGE_KEYS_MINUS) : 0)
            | (pageKeysBracket ? UInt32(WOWTYPE_PAGE_KEYS_BRACKET) : 0)
            | (pageKeysComma ? UInt32(WOWTYPE_PAGE_KEYS_COMMA) : 0)
            | (pageKeysTab ? UInt32(WOWTYPE_PAGE_KEYS_TAB) : 0)
    }

    public var selectKeysValue: Int32 {
        switch selectKeys {
        case .off: return Int32(WOWTYPE_SELECT_KEYS_OFF)
        case .semicolon: return Int32(WOWTYPE_SELECT_KEYS_SEMICOLON)
        case .semicolonQuote: return Int32(WOWTYPE_SELECT_KEYS_SEMICOLON_QUOTE)
        }
    }

    /// wowtype_autospace 的 flags：1 汉字和字母之间、2 汉字和数字之间；总开关关着是 0
    public var autoSpaceFlags: Int32 {
        guard autoSpace else { return 0 }
        return (autoSpaceLetters ? 1 : 0) | (autoSpaceDigits ? 2 : 0)
    }

    // MARK: 读写

    /// 读配置文件；读不到（还没建）就是默认值。
    public static func load(path: String) -> WowtypeConfig {
        guard let text = readFile(path) else {
            return WowtypeConfig()
        }
        return parse(text)
    }

    /// 解析 fcitx5 的 INI 格式：一行一个 Key=Value，# 开头是注释，值可以带双引号。
    /// 只认最外层的键（[分组] 下面的不是 WowType 的设置）。
    public static func parse(_ text: String) -> WowtypeConfig {
        var config = WowtypeConfig()
        var inGroup = false
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = trim(Substring(raw))
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }
            if line.hasPrefix("[") {
                inGroup = true
                continue
            }
            guard !inGroup, let eq = line.firstIndex(of: "=") else {
                continue
            }
            let key = trim(line[..<eq])
            let value = unquote(trim(line[line.index(after: eq)...]))
            config.set(key, value)
        }
        return config
    }

    private mutating func set(_ key: String, _ value: String) {
        switch key {
        case "CandidateLayout":
            if let v = matchName(value, ["Horizontal", "Vertical"]) { horizontal = v == "Horizontal" }
        case "PageSize":
            if let n = Int(value) { pageSize = min(max(n, 3), 9) }
        case "PageKeysMinusEqual": setBool(&pageKeysMinus, value)
        case "PageKeysBracket": setBool(&pageKeysBracket, value)
        case "PageKeysCommaPeriod": setBool(&pageKeysComma, value)
        case "PageKeysTab": setBool(&pageKeysTab, value)
        case "Fuzzy": setBool(&fuzzy, value)
        case "FuzzyZh": setBool(&fuzzyZh, value)
        case "FuzzyCh": setBool(&fuzzyCh, value)
        case "FuzzySh": setBool(&fuzzySh, value)
        case "FuzzyNL": setBool(&fuzzyNL, value)
        case "FuzzyFH": setBool(&fuzzyFH, value)
        case "FuzzyRL": setBool(&fuzzyRL, value)
        case "FuzzyAn": setBool(&fuzzyAn, value)
        case "FuzzyEn": setBool(&fuzzyEn, value)
        case "FuzzyIn": setBool(&fuzzyIn, value)
        case "FuzzyIan": setBool(&fuzzyIan, value)
        case "FuzzyUan": setBool(&fuzzyUan, value)
        case "FuzzyUn": setBool(&fuzzyUn, value)
        case "TypoCorrection": setBool(&typoCorrection, value)
        case "RareExtChars": setBool(&rareExtChars, value)
        case "Shuangpin": setBool(&shuangpin, value)
        case "ShuangpinScheme":
            if !value.isEmpty { shuangpinScheme = matchName(value, WowtypeConfig.shuangpinSchemes) ?? value }
        case "ShiftToggle":
            if let v = matchName(value, ShiftToggle.allCases.map(\.rawValue)) { shiftToggle = ShiftToggle(rawValue: v)! }
        case "Traditional": setBool(&traditional, value)
        case "PunctuationStyle":
            if let v = matchName(value, ["Fullwidth", "Halfwidth"]) { halfwidthPunct = v == "Halfwidth" }
        case "SelectKeys":
            if let v = matchName(value, SelectKeys.allCases.map(\.rawValue)) { selectKeys = SelectKeys(rawValue: v)! }
        case "PickChar": setBool(&pickChar, value)
        case "DateTime": setBool(&dateTime, value)
        case "Calculator": setBool(&calculator, value)
        case "EmojiSuggest": setBool(&emojiSuggest, value)
        case "AutoSpace": setBool(&autoSpace, value)
        case "AutoSpaceLetters": setBool(&autoSpaceLetters, value)
        case "AutoSpaceDigits": setBool(&autoSpaceDigits, value)
        case "Lexicon": lexicon = value
        case "CandidateFontSize":
            if let n = Int(value) { candidateFontSize = min(max(n, 10), 40) }
        case "Translate": setBool(&translate, value)
        case "TranslateTarget":
            if let v = matchName(value, WowtypeConfig.translateTargets) { translateTarget = v }
        case "TranslateBaseUrl": translateBaseUrl = value
        case "TranslateModel": translateModel = value
        case "TranslateFormal": setBool(&translateFormal, value)
        case "TranslateLocal": setBool(&translateLocal, value)
        case "TranslateLocalModel": translateLocalModel = value
        case "TranslateLlamaServer": translateLlamaServer = value
        case "TranslateIdleMinutes":
            if let n = Int(value) { translateIdleMinutes = min(max(n, 0), 240) }
        default:
            break
        }
    }

    /// 第一次打开设置时写出来的文件：每项都是默认值，带上说明。
    public static func template() -> String {
        let d = WowtypeConfig()
        func b(_ v: Bool) -> String { v ? "True" : "False" }
        return """
        # WowType 设置（键名和 Linux 的 wowtype.conf 一样，见 docs/CONFIG.md）。
        # 改完保存，下一次按键时生效；删掉一行就是用默认值。注释要单独写一行。

        # 候选排列：Horizontal 横排、Vertical 竖排
        CandidateLayout=Horizontal
        # 每页候选个数，3–9
        PageSize=\(d.pageSize)
        # 候选字号（磅），10–40，只有 macOS 有
        CandidateFontSize=\(d.candidateFontSize)
        # 翻页键（PgUp PgDn 一直能用）
        PageKeysMinusEqual=\(b(d.pageKeysMinus))
        PageKeysBracket=\(b(d.pageKeysBracket))
        PageKeysCommaPeriod=\(b(d.pageKeysComma))
        PageKeysTab=\(b(d.pageKeysTab))
        # 分号、引号选词：Off、Semicolon（; 选第 2 个）、SemicolonQuote（再加 ' 选第 3 个）
        SelectKeys=Off
        # 以词定字：打拼音时 [ 上屏候选的第一个字、] 最后一个字
        PickChar=\(b(d.pickChar))

        # 模糊音总开关，打开后下面各组分别生效
        Fuzzy=\(b(d.fuzzy))
        FuzzyZh=\(b(d.fuzzyZh))
        FuzzyCh=\(b(d.fuzzyCh))
        FuzzySh=\(b(d.fuzzySh))
        FuzzyNL=\(b(d.fuzzyNL))
        FuzzyFH=\(b(d.fuzzyFH))
        FuzzyRL=\(b(d.fuzzyRL))
        FuzzyAn=\(b(d.fuzzyAn))
        FuzzyEn=\(b(d.fuzzyEn))
        FuzzyIn=\(b(d.fuzzyIn))
        FuzzyIan=\(b(d.fuzzyIan))
        FuzzyUan=\(b(d.fuzzyUan))
        FuzzyUn=\(b(d.fuzzyUn))
        # 按错键自动纠正
        TypoCorrection=\(b(d.typoCorrection))
        # 候选末尾也列出扩展 B 区以后的生僻字（常见字体显示不了，默认关）
        RareExtChars=\(b(d.rareExtChars))

        # 双拼；方案：Ziranma 自然码、Xiaohe 小鹤、Microsoft 微软、Sogou 搜狗、ABC 智能 ABC、
        # Ziguang 紫光、PinyinJiajia 拼音加加
        Shuangpin=\(b(d.shuangpin))
        ShuangpinScheme=\(d.shuangpinScheme)

        # 单按哪个 Shift 切中英文：Both、Left、Right、Off
        ShiftToggle=Both
        # 输出繁体字
        Traditional=\(b(d.traditional))
        # 标点：Fullwidth 中文标点、Halfwidth 英文标点
        PunctuationStyle=Fullwidth
        # 打 riqi、shijian、xingqi 时给出当前日期时间
        DateTime=\(b(d.dateTime))
        # v 开头算算式（v1+2*3，只在全拼下）
        Calculator=\(b(d.calculator))
        # 打字时推荐 emoji
        EmojiSuggest=\(b(d.emojiSuggest))
        # 汉字和英文、数字之间自动加空格（总开关）；下面两项分别管字母、数字
        AutoSpace=\(b(d.autoSpace))
        AutoSpaceLetters=\(b(d.autoSpaceLetters))
        AutoSpaceDigits=\(b(d.autoSpaceDigits))

        # 词库文件（拼音<TAB>词<TAB>频次），留空用自带的雾凇词库；文件不在也用自带的
        Lexicon=

        # 互译：打开后单按 Shift 在 中 → 英 → 译 之间切（没配好翻译时只在中英之间切）。
        # 「译」里打的中文攒在候选框里，停 0.5 秒发去翻译，回车上屏译文。打的字会发给下面的服务。
        Translate=\(b(d.translate))
        # 译成哪种语言：en 英、ja 日、ko 韩、fr 法、de 德、es 西、ru 俄、pt 葡、it 意、vi 越、th 泰、id 印尼、ar 阿
        TranslateTarget=\(d.translateTarget)
        # 翻译服务（OpenAI 格式的 chat/completions），如 https://api.openai.com/v1；本机的 Ollama 是 http://127.0.0.1:11434/v1
        # API Key 不写在这里：菜单里「设置互译 API Key…」，存在同一个目录的 translate.key（只有自己能读）
        TranslateBaseUrl=
        TranslateModel=
        # 译文用正式语气（默认聊天口吻）
        TranslateFormal=\(b(d.translateFormal))
        # 用本地模型（腾讯 HY-MT 1.5 1.8B，离线）代替上面的服务。模型要自己下载（不是开源许可，
        # 不适用于欧盟、英国和韩国，见 docs/CONFIG.md），放到数据目录的 models/HY-MT1.5-1.8B-Q4_K_M.gguf，
        # 或者在 TranslateLocalModel 写它的路径；还要装 llama.cpp（brew install llama.cpp）
        TranslateLocal=\(b(d.translateLocal))
        TranslateLocalModel=
        # llama-server 的路径，留空在 /opt/homebrew/bin、/usr/local/bin 等处找
        TranslateLlamaServer=
        # 本地模型闲置几分钟后释放内存，0–240，0 不释放
        TranslateIdleMinutes=\(d.translateIdleMinutes)

        """
    }
}

// MARK: 小工具

private func trim(_ s: Substring) -> String {
    var s = s
    while let c = s.first, c == " " || c == "\t" { s.removeFirst() }
    while let c = s.last, c == " " || c == "\t" { s.removeLast() }
    return String(s)
}

/// fcitx5 写文件时，带空格、引号的值会加双引号并转义。
private func unquote(_ value: String) -> String {
    guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
        return value
    }
    var out = ""
    var escaped = false
    for c in value.dropFirst().dropLast() {
        if escaped {
            out.append(c == "n" ? "\n" : c)
            escaped = false
        } else if c == "\\" {
            escaped = true
        } else {
            out.append(c)
        }
    }
    return out
}

/// 枚举值不分大小写（fcitx5 写的是 Horizontal，手写 horizontal 也认）；不认识返回 nil，保持默认。
private func matchName(_ value: String, _ names: [String]) -> String? {
    names.first { $0.lowercased() == value.lowercased() }
}

private func setBool(_ target: inout Bool, _ value: String) {
    switch value.lowercased() {
    case "true", "1", "yes", "on": target = true
    case "false", "0", "no", "off": target = false
    default: break
    }
}

private func readFile(_ path: String) -> String? {
    guard let f = fopen(path, "rb") else {
        return nil
    }
    defer { fclose(f) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = fread(&buffer, 1, buffer.count, f)
        if n <= 0 { break }
        bytes.append(contentsOf: buffer[0..<n])
    }
    return String(decoding: bytes, as: UTF8.self)
}
