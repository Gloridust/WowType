// 设置：~/Library/Application Support/WowType/wowtype.conf。
//
// 键名、取值、默认值和 Linux 的 ~/.config/fcitx5/conf/wowtype.conf 一样，一份配置两边都能用。
// 以 spec/config.json 为准（设置契约，说明见 docs/CONFIG.md）：改键名、默认值、范围、可选值要先改规格，
// macos/test.sh 对照。文件不存在、少写了哪一项就用默认值；
// 不认识的键（语音这些 macOS 还没有的）不管。只有 EmojiKey 的默认值不一样（见 Shortcut）。
// 互译的 API Key 不在这里（这个文件谁都能读），在同一个目录的 translate.key（0600，见 TranslateKeyFile）。
// 设置窗口用 serialized / merged 写回去，只改认识的键，别的行原样留着。
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

    /// 打字途中方向键做什么（#129），见 spec/config.json 的 ArrowKeys
    public enum ArrowKeys: String, CaseIterable {
        case candidates = "Candidates", caret = "Caret"
    }

    /// 输入方案：全拼、双拼、五笔 86（见 spec/config.json 的 InputScheme）
    public enum InputScheme: String, CaseIterable {
        case quanpin = "Quanpin", shuangpin = "Shuangpin", wubi86 = "Wubi86"

        /// 设置窗口里的名字（和 Linux 设置的 INPUT_SCHEMES、fcitx5 的 EnumI18n 一样）
        public var name: String {
            switch self {
            case .quanpin: return "拼音输入"
            case .shuangpin: return "双拼输入"
            case .wubi86: return "五笔输入"
            }
        }
    }

    /// 双拼方案在配置文件里的名字（和 Linux 一样），核心也认小写、别名。
    public static let shuangpinSchemes = ["Ziranma", "Xiaohe", "Microsoft", "Sogou", "ABC", "Ziguang", "PinyinJiajia"]

    /// 互译语言：设置窗口里的名字、配置文件里的代码（和 Linux 的 WowtypeTranslateTarget、
    /// 设置界面的 TRANSLATE_LANGUAGES、核心的 translate::LANGUAGES 一样）。
    public static let translateLanguages: [(String, String)] = [
        ("英语", "en"), ("日语", "ja"), ("韩语", "ko"), ("法语", "fr"), ("德语", "de"), ("西班牙语", "es"),
        ("俄语", "ru"), ("葡萄牙语", "pt"), ("意大利语", "it"), ("越南语", "vi"), ("泰语", "th"),
        ("印尼语", "id"), ("阿拉伯语", "ar"),
    ]

    public static let translateTargets = translateLanguages.map { $0.1 }

    /// 常见的 OpenAI 格式翻译服务：名字、接口地址、模型框空着时建议的模型（和 Linux 设置的 TRANSLATE_PROVIDERS 一样）。
    /// 最后一项是自己填地址。
    public static let translateProviders: [(name: String, url: String, model: String)] = [
        ("OpenAI", "https://api.openai.com/v1", ""),
        ("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat"),
        ("通义千问（阿里云百炼）", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
        ("Kimi（月之暗面）", "https://api.moonshot.cn/v1", "moonshot-v1-8k"),
        ("智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", "glm-4-flash"),
        ("硅基流动", "https://api.siliconflow.cn/v1", ""),
        ("OpenRouter", "https://openrouter.ai/api/v1", ""),
        ("Ollama（本机）", "http://127.0.0.1:11434/v1", ""),
        ("其他（自己填地址）", "", ""),
    ]

    public var horizontal = true
    public var arrowKeys = ArrowKeys.candidates
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
    public var fuzzyAnAi = false
    public var fuzzyHuangWang = false
    public var fuzzyUnIong = false
    public var fuzzyEngOng = false
    public var typoCorrection = true
    public var rareExtChars = false
    public var inputScheme = InputScheme.quanpin
    public var shuangpinScheme = "Ziranma"
    /// 双拼时编辑区显示打的键（uivs），不翻成全拼（#122）
    public var shuangpinShowKeys = false
    /// 五笔打满四码、只有一个字词时直接上屏
    public var wubiAutoCommit = true
    /// 五笔候选后面显示还要打的码
    public var wubiHint = true
    public var shiftToggle = ShiftToggle.both
    public var traditional = false
    public var halfwidthPunct = false
    public var selectKeys = SelectKeys.off
    public var pickChar = true
    /// 联想：选词上屏后给出接下来可能打的词（#89）。默认关：汉字后面直接打数字会选成联想的词
    public var prediction = false
    public var dateTime = true
    public var calculator = true
    public var emojiSuggest = true
    public var autoSpace = false
    public var autoSpaceLetters = true
    public var autoSpaceDigits = true
    /// v + 空格打开工具栏（剪贴板、常用语、符号、表情；双拼、五笔时不开）
    public var toolbar = true
    /// 记录剪贴板历史（只在内存里，最多 20 条）。默认关：可能把复制的密码也记下来
    public var clipboardHistory = false
    /// 语音输入：按住 voiceKey 说话，松开出字（模型在设置窗口里下载）
    public var voice = true
    /// 语音键，fcitx5 键名：Alt_R（右 Option）、Control_R、F8…；留空不用
    public var voiceKey = "Alt_R"
    /// 语音识别的结果同时复制到剪贴板
    public var voiceCopy = false
    /// 打开表情面板的快捷键，nil 不用快捷键。Linux 默认 Super+period；macOS 上 Command 组合键
    /// 多半到不了输入法，默认 Control+period（Super 也当 Control，见 Shortcut）
    public var emojiKey: Shortcut? = .emojiDefault
    /// 另设一个切换中 / 英文的快捷键（#143），nil 不用；单按 Shift 照常
    public var toggleKey: Shortcut?
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
    /// 用本地模型（HY-MT），默认是。配置文件里没写这一项、又填了 TranslateBaseUrl 时是 False（见 parse，三端一样）
    public var translateLocal = true
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
            (fuzzyAnAi, 4096), (fuzzyHuangWang, 8192), (fuzzyUnIong, 16384), (fuzzyEngOng, 32768),
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

    public var arrowKeysValue: Int32 {
        switch arrowKeys {
        case .candidates: return Int32(WOWTYPE_ARROW_KEYS_CANDIDATES)
        case .caret: return Int32(WOWTYPE_ARROW_KEYS_CARET)
        }
    }

    public var shuangpin: Bool { inputScheme == .shuangpin }
    public var wubi: Bool { inputScheme == .wubi86 }

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
    /// 只认最外层的键（[分组] 下面的不是 WowType 的设置）。同一个键写了几次，算最后一次。
    public static func parse(_ text: String) -> WowtypeConfig {
        var config = WowtypeConfig()
        var inGroup = false
        var sawTranslateLocal = false
        var sawInputScheme = false
        var oldShuangpin = false
        // Swift 把 \r\n 当成一个字符，用 isNewline 才认得出 Windows 换行
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
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
            if key == "Shuangpin" {
                // 0.3.12 及以前的双拼开关：只在没有 InputScheme 时算，见下面；存盘时删掉（见 serialized）
                oldShuangpin = value == "True"
                continue
            }
            config.setValue(value, forKey: key)
            sawTranslateLocal = sawTranslateLocal || key == "TranslateLocal"
            sawInputScheme = sawInputScheme || key == "InputScheme"
        }
        if !sawTranslateLocal {
            config.translateLocal = impliedTranslateLocal(baseUrl: config.translateBaseUrl)
        }
        if !sawInputScheme, oldShuangpin {
            config.inputScheme = .shuangpin
        }
        return config
    }

    /// 文件里没写 TranslateLocal 时它是什么：0.3.10 及以前没有这一项，已经填好翻译接口（TranslateBaseUrl）的
    /// 接着用接口（False），没填的用默认的本地模型。三端一样（插件的 loadWowtypeConfig、Linux 设置的 read_config），
    /// 见 spec/config.json。
    static func impliedTranslateLocal(baseUrl: String) -> Bool {
        baseUrl.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }
    }

    /// 认识的键，顺序同模板（文件里没有、又不是默认值的键照这个顺序补在后面）。
    public static let keys = [
        "CandidateLayout", "ArrowKeys", "PageSize", "CandidateFontSize",
        "PageKeysMinusEqual", "PageKeysBracket", "PageKeysCommaPeriod", "PageKeysTab", "SelectKeys", "PickChar", "Prediction",
        "Fuzzy", "FuzzyZh", "FuzzyCh", "FuzzySh", "FuzzyNL", "FuzzyFH", "FuzzyRL",
        "FuzzyAn", "FuzzyEn", "FuzzyIn", "FuzzyIan", "FuzzyUan", "FuzzyUn",
        "FuzzyAnAi", "FuzzyHuangWang", "FuzzyUnIong", "FuzzyEngOng",
        "TypoCorrection", "RareExtChars", "InputScheme", "ShuangpinScheme", "ShuangpinShowKeys",
        "WubiAutoCommit", "WubiHint", "ShiftToggle",
        "Traditional",
        "PunctuationStyle", "DateTime", "Calculator", "EmojiSuggest", "AutoSpace", "AutoSpaceLetters",
        "AutoSpaceDigits", "Lexicon", "Toolbar", "ClipboardHistory", "Voice", "VoiceKey", "VoiceCopy", "EmojiKey",
        "ToggleKey",
        "Translate", "TranslateTarget", "TranslateBaseUrl", "TranslateModel", "TranslateFormal", "TranslateLocal",
        "TranslateLocalModel", "TranslateLlamaServer", "TranslateIdleMinutes",
    ]

    /// 开关类的键（True / False）
    private static let boolKeys: [String: WritableKeyPath<WowtypeConfig, Bool>] = [
        "PageKeysMinusEqual": \.pageKeysMinus, "PageKeysBracket": \.pageKeysBracket,
        "PageKeysCommaPeriod": \.pageKeysComma, "PageKeysTab": \.pageKeysTab,
        "Fuzzy": \.fuzzy, "FuzzyZh": \.fuzzyZh, "FuzzyCh": \.fuzzyCh, "FuzzySh": \.fuzzySh,
        "FuzzyNL": \.fuzzyNL, "FuzzyFH": \.fuzzyFH, "FuzzyRL": \.fuzzyRL, "FuzzyAn": \.fuzzyAn,
        "FuzzyEn": \.fuzzyEn, "FuzzyIn": \.fuzzyIn, "FuzzyIan": \.fuzzyIan, "FuzzyUan": \.fuzzyUan,
        "FuzzyUn": \.fuzzyUn, "FuzzyAnAi": \.fuzzyAnAi, "FuzzyHuangWang": \.fuzzyHuangWang,
        "FuzzyUnIong": \.fuzzyUnIong, "FuzzyEngOng": \.fuzzyEngOng,
        "TypoCorrection": \.typoCorrection, "RareExtChars": \.rareExtChars,
        "ShuangpinShowKeys": \.shuangpinShowKeys, "WubiAutoCommit": \.wubiAutoCommit, "WubiHint": \.wubiHint,
        "Traditional": \.traditional, "PickChar": \.pickChar, "Prediction": \.prediction,
        "DateTime": \.dateTime, "Calculator": \.calculator, "EmojiSuggest": \.emojiSuggest,
        "AutoSpace": \.autoSpace, "AutoSpaceLetters": \.autoSpaceLetters, "AutoSpaceDigits": \.autoSpaceDigits,
        "Toolbar": \.toolbar, "ClipboardHistory": \.clipboardHistory, "Voice": \.voice, "VoiceCopy": \.voiceCopy,
        "Translate": \.translate, "TranslateFormal": \.translateFormal, "TranslateLocal": \.translateLocal,
    ]

    /// 按文件里的写法改一项。不认识的键、认不出的值不管（保持原值）。
    public mutating func setValue(_ value: String, forKey key: String) {
        if let path = WowtypeConfig.boolKeys[key] {
            setBool(&self[keyPath: path], value)
            return
        }
        switch key {
        case "CandidateLayout":
            if let v = matchName(value, ["Horizontal", "Vertical"]) { horizontal = v == "Horizontal" }
        case "ArrowKeys":
            if let v = matchName(value, ArrowKeys.allCases.map(\.rawValue)) { arrowKeys = ArrowKeys(rawValue: v)! }
        case "PageSize":
            if let n = Int(value) { pageSize = min(max(n, 3), 9) }
        case "InputScheme":
            if let v = matchName(value, InputScheme.allCases.map(\.rawValue)) { inputScheme = InputScheme(rawValue: v)! }
        case "ShuangpinScheme":
            if let v = matchName(value, WowtypeConfig.shuangpinSchemes) { shuangpinScheme = v }
        case "ShiftToggle":
            if let v = matchName(value, ShiftToggle.allCases.map(\.rawValue)) { shiftToggle = ShiftToggle(rawValue: v)! }
        case "PunctuationStyle":
            if let v = matchName(value, ["Fullwidth", "Halfwidth"]) { halfwidthPunct = v == "Halfwidth" }
        case "SelectKeys":
            if let v = matchName(value, SelectKeys.allCases.map(\.rawValue)) { selectKeys = SelectKeys(rawValue: v)! }
        case "Lexicon": lexicon = value
        case "CandidateFontSize":
            if let n = Int(value) { candidateFontSize = min(max(n, 10), 40) }
        case "VoiceKey": voiceKey = value
        case "EmojiKey":
            // 留空是不用快捷键；写错了保持默认
            if value.isEmpty {
                emojiKey = nil
            } else if let key = Shortcut(name: value) {
                emojiKey = key
            }
        case "ToggleKey":
            // 留空是不用；写错了保持原样
            if value.isEmpty {
                toggleKey = nil
            } else if let shortcut = Shortcut(name: value) {
                toggleKey = shortcut
            }
        case "TranslateTarget":
            if let v = matchName(value, WowtypeConfig.translateTargets) { translateTarget = v }
        case "TranslateBaseUrl": translateBaseUrl = value
        case "TranslateModel": translateModel = value
        case "TranslateLocalModel": translateLocalModel = value
        case "TranslateLlamaServer": translateLlamaServer = value
        case "TranslateIdleMinutes":
            if let n = Int(value) { translateIdleMinutes = min(max(n, 0), 240) }
        default:
            break
        }
    }

    /// 这一项在文件里的写法（True / False、枚举名、数字、原样的路径）；不认识的键是 nil。
    public func value(forKey key: String) -> String? {
        if let path = WowtypeConfig.boolKeys[key] {
            return self[keyPath: path] ? "True" : "False"
        }
        switch key {
        case "CandidateLayout": return horizontal ? "Horizontal" : "Vertical"
        case "ArrowKeys": return arrowKeys.rawValue
        case "PageSize": return String(pageSize)
        case "InputScheme": return inputScheme.rawValue
        case "ShuangpinScheme": return shuangpinScheme
        case "ShiftToggle": return shiftToggle.rawValue
        case "PunctuationStyle": return halfwidthPunct ? "Halfwidth" : "Fullwidth"
        case "SelectKeys": return selectKeys.rawValue
        case "Lexicon": return lexicon
        case "CandidateFontSize": return String(candidateFontSize)
        case "VoiceKey": return voiceKey
        case "EmojiKey": return emojiKey?.name ?? ""
        case "ToggleKey": return toggleKey?.name ?? ""
        case "TranslateTarget": return translateTarget
        case "TranslateBaseUrl": return translateBaseUrl
        case "TranslateModel": return translateModel
        case "TranslateLocalModel": return translateLocalModel
        case "TranslateLlamaServer": return translateLlamaServer
        case "TranslateIdleMinutes": return String(translateIdleMinutes)
        default: return nil
        }
    }

    /// 把设置写进配置文件的原文，返回新的原文。
    ///
    /// 只动认识的键：值读出来已经一样的那行原样不动（大小写、引号、两边的空格都留着），不一样的只换 = 后面的值。
    /// 注释、空行、不认识的键（语音这些 macOS 还没有的）、[分组] 原样留着，所以 Linux 拷过来的文件
    /// 改完拿回 Linux 照样能用。文件里没有、又不是默认值的键补在最后一个设置后面（[分组] 前面）。
    /// 只删一种行：0.3.12 及以前的 Shuangpin 开关（三端存盘都不写它）。
    /// text 是 nil 或空的（还没有文件）时从带说明的模板开始。
    public func serialized(into text: String?) -> String {
        guard let text, text.contains(where: { !$0.isWhitespace }) else {
            return serialized(into: WowtypeConfig.template())
        }
        // 按 \n 拆（\r\n 在 Swift 里是一个字符，要按码位拆），每行末尾的 \r 留着
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var seen = Set<String>()
        var firstGroup: Int?
        var crlf = false
        var oldShuangpin: [Int] = []
        for i in lines.indices {
            var line = lines[i]
            let cr = line.hasSuffix("\r")
            if cr {
                line.removeLast()
                crlf = true
            }
            let body = trim(Substring(line))
            if body.hasPrefix("[") {
                firstGroup = firstGroup ?? i
            }
            if firstGroup != nil || body.isEmpty || body.hasPrefix("#") || body.hasPrefix(";") {
                continue
            }
            guard let eq = line.firstIndex(of: "=") else {
                continue
            }
            let key = trim(line[..<eq])
            if key == "Shuangpin" {
                oldShuangpin.append(i)
                continue
            }
            guard let wanted = value(forKey: key) else {
                continue
            }
            seen.insert(key)
            // 这一行单独读出来（从默认值开始）已经是要的值：不动。认不出的值读出来是默认值，
            // 要的正好是默认值也不动；前面同一个键的行都已经是要的值，所以整份读出来还是对的。
            var probe = WowtypeConfig()
            probe.setValue(unquote(trim(line[line.index(after: eq)...])), forKey: key)
            if probe.value(forKey: key) == wanted {
                continue
            }
            var start = line.index(after: eq)
            while start < line.endIndex, line[start] == " " || line[start] == "\t" {
                start = line.index(after: start)
            }
            lines[i] = String(line[..<start]) + quote(wanted) + (cr ? "\r" : "")
        }

        // 0.3.12 及以前的双拼开关（parse 读过了）：删掉，方案只看 InputScheme（这些行都在 [分组] 前面）
        for i in oldShuangpin.reversed() {
            lines.remove(at: i)
        }
        firstGroup = firstGroup.map { $0 - oldShuangpin.count }

        // 文件里没有的键读出来是默认值；TranslateLocal 没写时跟着 TranslateBaseUrl 走（见 parse），按读回来的值比
        var implied = WowtypeConfig()
        implied.translateLocal = WowtypeConfig.impliedTranslateLocal(baseUrl: translateBaseUrl)
        let missing = WowtypeConfig.keys.compactMap { key -> String? in
            guard !seen.contains(key), let v = value(forKey: key), v != implied.value(forKey: key) else {
                return nil
            }
            return key + "=" + quote(v) + (crlf ? "\r" : "")
        }
        if !missing.isEmpty {
            // 补在最后一个设置后面：跳过 [分组]（或文件末尾）前面的空行
            var at = firstGroup ?? lines.count
            while at > 0, trim(Substring(lines[at - 1])).isEmpty || lines[at - 1] == "\r" {
                at -= 1
            }
            lines.insert(contentsOf: missing, at: at)
        }
        return lines.joined(separator: "\n")
    }

    /// 设置窗口保存时用：只把 base → self 改过的键写进文件现在的原文。窗口开着时文件在别处改了
    /// （文本编辑、Linux 同步过来），别处改的键不会被窗口里的旧值盖掉。
    public func merged(changesFrom base: WowtypeConfig, into text: String?) -> String {
        var target = text.map(WowtypeConfig.parse) ?? WowtypeConfig()
        for key in WowtypeConfig.keys {
            if let mine = value(forKey: key), mine != base.value(forKey: key) {
                target.setValue(mine, forKey: key)
            }
        }
        return target.serialized(into: text)
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
        # 打字途中方向键做什么：Candidates 都用来选词（横排左右键选词、上键上一页、下键展开；
        # 竖排上下键选词、左右键翻页），Caret 上下键选词、左右键在拼音里移动光标
        ArrowKeys=Candidates
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
        # 联想：上屏后给出接下来可能打的词，按数字键选；空格、回车、退格照常输入
        Prediction=\(b(d.prediction))

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
        FuzzyAnAi=\(b(d.fuzzyAnAi))
        FuzzyHuangWang=\(b(d.fuzzyHuangWang))
        FuzzyUnIong=\(b(d.fuzzyUnIong))
        FuzzyEngOng=\(b(d.fuzzyEngOng))
        # 按错键自动纠正
        TypoCorrection=\(b(d.typoCorrection))
        # 候选末尾也列出扩展 B 区以后的生僻字（常见字体显示不了，默认关）
        RareExtChars=\(b(d.rareExtChars))

        # 输入方案：Quanpin 全拼、Shuangpin 双拼、Wubi86 五笔 86
        InputScheme=\(d.inputScheme.rawValue)
        # 双拼方案：Ziranma 自然码、Xiaohe 小鹤、Microsoft 微软、Sogou 搜狗、ABC 智能 ABC、
        # Ziguang 紫光、PinyinJiajia 拼音加加
        ShuangpinScheme=\(d.shuangpinScheme)
        # 双拼时编辑区显示打的键（不翻成全拼）
        ShuangpinShowKeys=\(b(d.shuangpinShowKeys))
        # 五笔打满四码、只有一个字词时直接上屏
        WubiAutoCommit=\(b(d.wubiAutoCommit))
        # 五笔候选后面显示还要打的码
        WubiHint=\(b(d.wubiHint))

        # 单按哪个 Shift 切中英文：Both、Left、Right、Off
        ShiftToggle=Both
        # 输出繁体字
        Traditional=\(b(d.traditional))
        # 标点：Fullwidth 中文标点、Halfwidth 英文标点
        PunctuationStyle=Fullwidth
        # 打 riqi、shijian、xingqi 时给出当前日期时间
        DateTime=\(b(d.dateTime))
        # v 开头算算式（v1+2*3；双拼、五笔时是大写 V）
        Calculator=\(b(d.calculator))
        # 打字时推荐 emoji
        EmojiSuggest=\(b(d.emojiSuggest))
        # 汉字和英文、数字之间自动加空格（总开关）；下面两项分别管字母、数字
        AutoSpace=\(b(d.autoSpace))
        AutoSpaceLetters=\(b(d.autoSpaceLetters))
        AutoSpaceDigits=\(b(d.autoSpaceDigits))

        # 只打一个 v 再按空格打开工具栏：剪贴板、常用语、符号、表情（双拼、五笔时不开）
        Toolbar=\(b(d.toolbar))
        # 工具栏里记剪贴板历史（只在内存里，最多 20 条）。可能把复制的密码也记下来，默认关
        ClipboardHistory=\(b(d.clipboardHistory))

        # 语音输入：按住语音键说话，松开出字（点按一下也行，说完停一下自动结束）。模型在设置窗口「语音」页下载
        Voice=\(b(d.voice))
        # 语音键：Alt_R 右 Option、Control_R 右 Control、F8、F9、F10；留空不用
        VoiceKey=\(d.voiceKey)
        # 说的话上屏的同时复制到剪贴板
        VoiceCopy=\(b(d.voiceCopy))
        # 打开表情面板的快捷键，键名同 fcitx5：Control+period、Control+semicolon、Control+Shift+E；留空不用。
        # Command 组合键多半到不了输入法，写 Super 的当 Control
        EmojiKey=\(d.emojiKey?.name ?? "")
        # 另设一个切换中 / 英文的快捷键：Control+space、Control+Shift+space；留空不用（单按 Shift 照常）。
        # Control+space 是 macOS 切换输入法的快捷键，要先在「系统设置 → 键盘 → 键盘快捷键 → 输入法」里关掉
        ToggleKey=\(d.toggleKey?.name ?? "")

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
        # 用本地模型（腾讯 HY-MT 1.5 1.8B，离线）翻译，默认 True；False 用上面的服务。
        # 删掉这一行时：上面填了 TranslateBaseUrl 就当 False（以前的设置照旧用服务），没填就是 True。
        # 模型和运行它的 llama-server 在设置窗口「翻译」页一键下载，放在数据目录的 models/ 和 llama/
        # （模型不是开源许可，不适用于欧盟、英国和韩国，见 docs/CONFIG.md）
        TranslateLocal=\(b(d.translateLocal))
        # 模型文件的位置，留空用 models/HY-MT1.5-1.8B-Q4_K_M.gguf
        TranslateLocalModel=
        # llama-server 的位置，留空先用设置里下载的，再在 /opt/homebrew/bin、/usr/local/bin 等处找
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

/// 写文件时：值里有空白、换行，或者本身就被引号包着，照 fcitx5 的写法加双引号并转义（unquote 读回来一样）。
private func quote(_ value: String) -> String {
    let special: Set<Character> = [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]
    let wrapped = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
    guard wrapped || value.contains(where: { special.contains($0) }) else {
        return value
    }
    var out = "\""
    for c in value {
        switch c {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        default: out.append(c)
        }
    }
    return out + "\""
}

/// 枚举值区分大小写，和 fcitx5 一样（horizontal 不认）；不认识返回 nil，保持默认。三端一样，见 spec/config.json。
private func matchName(_ value: String, _ names: [String]) -> String? {
    names.contains(value) ? value : nil
}

/// 开关只认 True / False，和 fcitx5 一样；别的写法（true、1、yes）保持默认。
private func setBool(_ target: inout Bool, _ value: String) {
    switch value {
    case "True": target = true
    case "False": target = false
    default: break
    }
}

/// 读整个文本文件；打不开返回 nil。
func readFile(_ path: String) -> String? {
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
