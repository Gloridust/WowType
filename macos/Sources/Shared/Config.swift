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

    /// 从别的输入法切到 WowType、这个进程里第一次用时是中文、英文，还是不动（Last），见 spec/config.json 的 InitialMode
    public enum InitialMode: String, CaseIterable {
        case chinese = "Chinese", english = "English", last = "Last"
    }

    /// 换到别的应用、别的窗口时是不动（Same），还是定成中文、英文（#254），见 spec/config.json 的 WindowMode
    public enum WindowMode: String, CaseIterable {
        case same = "Same", chinese = "Chinese", english = "English"
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

    /// 设置窗口的主题（SettingsTheme）：跟随系统，或者固定浅色 / 深色。只管设置窗口，输入法不读；
    /// 名字和 Linux 设置的 SETTINGS_THEMES、Windows 设置窗口的一样（见 spec/config.json）
    public enum SettingsTheme: String, CaseIterable {
        case system = "System", light = "Light", dark = "Dark"

        public var name: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }
    }

    /// 设置窗口的强调色（SettingsAccent）。三端用同一张表（spec/config.json 的 SettingsAccent），颜色不自己算：
    /// color 是色板本身（侧栏的底色、悬停、统计的图），strong 是上面放白字的底（选中的导航、按钮、开关，
    /// 和白色的对比度至少 4.7:1；浅色背景上当字用也是它），light 是深色背景上当字用的颜色（至少 4.5:1）。
    public struct AccentPreset: Equatable {
        public let value: String
        public let name: String
        public let color: UInt32
        public let strong: UInt32
        public let light: UInt32
    }

    public static let accentPresets: [AccentPreset] = [
        AccentPreset(value: "Green", name: "绿色", color: 0x0EAF76, strong: 0x0A8358, light: 0x1AB37D),
        AccentPreset(value: "Blue", name: "蓝色", color: 0x3584E4, strong: 0x2D70C2, light: 0x68A3EB),
        AccentPreset(value: "Purple", name: "紫色", color: 0x9141AC, strong: 0x9141AC, light: 0xBD8DCD),
        AccentPreset(value: "Orange", name: "橙色", color: 0xE66100, strong: 0xB84E00, light: 0xEC8840),
        AccentPreset(value: "Pink", name: "粉色", color: 0xD56199, strong: 0xAA4E7A, light: 0xDD81AD),
    ]

    /// 现在的强调色；文件里写的认不出时已经是默认的绿色
    public var accent: AccentPreset {
        WowtypeConfig.accentPresets.first { $0.value == settingsAccent } ?? WowtypeConfig.accentPresets[0]
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

    /// 设置里的「翻译引擎」：本地翻译、哔哩哔哩、自定义翻译服务（和 Linux 设置的 TRANSLATE_ENGINES 一样，
    /// 见 spec/config.json 的 translateEngines）。不是单独的设置项，从 TranslateLocal 和 TranslateBaseUrl 推出来，
    /// 见 translateEngine。
    public enum TranslateEngine: String, CaseIterable {
        case local, bilibili, custom

        /// 下拉框里的名字
        public var name: String {
            switch self {
            case .local: return "本地翻译（离线）"
            case .bilibili: return "哔哩哔哩（免费）"
            case .custom: return "自定义翻译服务"
            }
        }

        /// 选中时下拉框那一行的说明
        public var note: String {
            switch self {
            case .local: return "不联网、不用账号，打的字不出这台电脑；一句话等 1–3 秒"
            case .bilibili: return "哔哩哔哩的 Index-Translate，不用注册、不用 API Key；要联网，一句话不到 1 秒"
            case .custom: return "填你自己的翻译接口（DeepSeek、通义千问、Ollama……），要联网"
            }
        }
    }

    /// 哔哩哔哩 Index-Translate 的免费公开接口（不用 API Key），和 Linux 设置的 BILIBILI_*、核心的
    /// translate::BILIBILI_* 一样（见 spec/config.json 的 translateBilibili）。核心看到这个主机就用 Index-Translate
    /// 的提示词、模型空着用 2B、不带 Key
    public static let bilibiliURL = "https://index-translate.bilibili.com/v1"
    public static let bilibiliHost = "index-translate.bilibili.com"
    public static let bilibiliDefaultModel = "Index-Translate-2B"
    public static let bilibiliModels: [(id: String, name: String)] = [
        ("Index-Translate-2B", "Index-Translate-2B（最快）"),
        ("Index-Translate-9B", "Index-Translate-9B"),
        ("Index-Translate-35B-A3B", "Index-Translate-35B-A3B（预览）"),
    ]
    public static let bilibiliPrivacy = "要翻译的文字会发到哔哩哔哩的服务器（index-translate.bilibili.com）"

    /// 网址里的主机名（小写，不带协议、用户名、端口；IPv6 去掉方括号），和核心的 url_host 一样。没写协议也行
    public static func urlHost(_ url: String) -> String {
        var chars = Array(url.lowercased().filter { $0 != " " && $0 != "\t" && $0 != "\r" && $0 != "\n" })
        var i = 0
        while i + 2 < chars.count {
            if chars[i] == ":" && chars[i + 1] == "/" && chars[i + 2] == "/" {
                chars = Array(chars[(i + 3)...])
                break
            }
            i += 1
        }
        if let end = chars.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            chars = Array(chars[..<end])
        }
        if let at = chars.lastIndex(of: "@") {
            chars = Array(chars[(at + 1)...])
        }
        if chars.first == "[" {
            let end = chars.firstIndex(of: "]") ?? chars.count
            return String(chars[1..<end])
        }
        if let colon = chars.firstIndex(of: ":") {
            chars = Array(chars[..<colon])
        }
        return String(chars)
    }

    /// 接口地址是哔哩哔哩的吗
    public static func isBilibili(_ url: String) -> Bool {
        urlHost(url) == bilibiliHost
    }

    /// 现在用的翻译引擎：TranslateLocal 是本地；否则接口地址是哔哩哔哩的就是哔哩哔哩，别的都是自定义
    public var translateEngine: TranslateEngine {
        if translateLocal { return .local }
        return WowtypeConfig.isBilibili(translateBaseUrl) ? .bilibili : .custom
    }

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
    /// 输入框里的拼音用空格分音节（ni hao），不用 '；网页代码块里留下半截拼音时打开（#247）
    public var inlineSpaceSeparator = false
    public var inputScheme = InputScheme.quanpin
    public var shuangpinScheme = "Ziranma"
    /// 双拼时编辑区显示打的键（uivs），不翻成全拼（#122）
    public var shuangpinShowKeys = false
    /// 双拼的简拼：每个键都是声母时也当成只打了声母（sm -> 什么，#268）
    public var shuangpinAbbrev = true
    /// 五笔打满四码、只有一个字词时直接上屏
    public var wubiAutoCommit = true
    /// 五笔候选后面显示还要打的码
    public var wubiHint = true
    public var shiftToggle = ShiftToggle.both
    /// 切到 WowType 时的模式（换窗口不算）；关了 Shift 切换、也没另设切换键时总是中文
    public var initialMode = InitialMode.chinese
    /// 换到别的应用、别的窗口时的中 / 英（#254）；Same 是每个应用记着自己的模式（和以前一样）
    public var windowMode = WindowMode.same
    public var traditional = false
    public var halfwidthPunct = false
    /// 中文标点自动配对：打 ( [ < { " ' 上屏成对的（）【】《》「」“”‘’，光标放到中间（应用要能按位置改字才开）
    public var autoPairPunct = false
    public var selectKeys = SelectKeys.off
    public var pickChar = true
    /// 联想：上屏以后给出常跟在后面的词（Tab 进联想行再选；数字、空格照常）
    public var association = false
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
    /// 跨设备复制粘贴（docs/SYNC.md）：一台设备上复制的文字，在配过对的另一台上直接粘贴。默认关；
    /// 配对在设置窗口里做，组密钥在数据目录的 sync.json，中转服务的访问口令在 sync-relay.key
    public var clipboardSync = false
    /// 同一个局域网里直接传
    public var clipboardSyncLan = true
    /// 自己部署的中转服务地址，留空不用
    public var clipboardSyncRelayUrl = ""
    /// 这台设备的名字，留空用电脑的名字
    public var clipboardSyncDeviceName = ""
    /// 收到的也放进系统剪贴板（能直接 Command+V）
    public var clipboardSyncPaste = true
    /// 语音输入：按住 voiceKey 说话，松开出字（模型在设置窗口里下载）
    public var voice = true
    /// 语音键，fcitx5 键名：Alt_R（右 Option）、Control_R、F8…；留空不用
    public var voiceKey = "Alt_R"
    /// 点按说话时没声音多久自动结束，毫秒，0–60000；0 不自动结束（再点一下语音键结束，最长录 2 分钟）。#285
    public var voiceSilenceTimeout = 1500
    /// 语音识别的结果同时复制到剪贴板
    public var voiceCopy = false
    /// 打开表情面板的快捷键，nil 不用快捷键。Linux 默认 Super+period；macOS 上 Command 组合键
    /// 多半到不了输入法，默认 Control+period（Super 也当 Control，见 Shortcut）
    public var emojiKey: Shortcut? = .emojiDefault
    /// 另设的切换中 / 英文、进出「译」的快捷键（#143、#87），nil 不用。设了进出「译」的键时
    /// 单按 Shift 只在中 ↔ 英之间切；两个一样时算进出「译」
    public var toggleKey: Shortcut?
    public var translateModeKey: Shortcut?
    /// 自动检查更新：输入法每天最多查一次 GitHub 上的新版本（有新版时输入法菜单里多一项），设置窗口打开时也查
    public var checkUpdate = true
    /// Beta 计划：检查更新也算 GitHub 上的预发布版（pre-release）
    public var betaUpdates = false
    /// 打字统计（TypingStats，默认关）：开了才在本机按天记计数（字数、按键次数），不记打的内容
    public var typingStats = false
    /// 开发者模式（DeveloperMode，默认关）：开了以后把每次上屏打的输入、当时的候选、选了第几个明文记在本机
    /// （docs/DEVLOG.md），调排序用
    public var developerMode = false
    /// 设置窗口的主题、强调色（只管设置窗口，输入法不读）
    public var settingsTheme = SettingsTheme.system
    public var settingsAccent = "Green"
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
    /// 双击 Shift 单次互译（#191）：单按 Shift 只切中英，双击 Shift（或按互译键）进「译」翻一句就回来
    public var translateOneShot = false
    /// 用本地模型（HY-MT），默认是。配置文件里没写这一项、又填了 TranslateBaseUrl 时是 False（见 parse，三端一样）
    public var translateLocal = true
    /// 本地模型文件，留空用数据目录下 models/Hy-MT3-1.8B-Q4_K_M.gguf
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
        "PageKeysMinusEqual", "PageKeysBracket", "PageKeysCommaPeriod", "PageKeysTab", "SelectKeys", "PickChar",
        "Association",
        "Fuzzy", "FuzzyZh", "FuzzyCh", "FuzzySh", "FuzzyNL", "FuzzyFH", "FuzzyRL",
        "FuzzyAn", "FuzzyEn", "FuzzyIn", "FuzzyIan", "FuzzyUan", "FuzzyUn",
        "FuzzyAnAi", "FuzzyHuangWang", "FuzzyUnIong", "FuzzyEngOng",
        "TypoCorrection", "RareExtChars", "InlineSpaceSeparator", "InputScheme", "ShuangpinScheme", "ShuangpinShowKeys",
        "ShuangpinAbbrev", "WubiAutoCommit", "WubiHint", "ShiftToggle", "InitialMode", "WindowMode",
        "Traditional",
        "PunctuationStyle", "AutoPairPunct", "DateTime", "Calculator", "EmojiSuggest", "AutoSpace", "AutoSpaceLetters",
        "AutoSpaceDigits", "Lexicon", "Toolbar", "ClipboardHistory",
        "ClipboardSync", "ClipboardSyncLan", "ClipboardSyncRelayUrl", "ClipboardSyncDeviceName", "ClipboardSyncPaste",
        "Voice", "VoiceKey", "VoiceSilenceTimeout",
        "VoiceCopy", "EmojiKey",
        "ToggleKey", "TranslateModeKey", "CheckUpdate", "BetaUpdates", "TypingStats", "DeveloperMode",
        "SettingsTheme", "SettingsAccent",
        "Translate", "TranslateTarget", "TranslateBaseUrl", "TranslateModel", "TranslateFormal", "TranslateOneShot",
        "TranslateLocal", "TranslateLocalModel", "TranslateLlamaServer", "TranslateIdleMinutes",
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
        "InlineSpaceSeparator": \.inlineSpaceSeparator,
        "ShuangpinShowKeys": \.shuangpinShowKeys, "ShuangpinAbbrev": \.shuangpinAbbrev, "WubiAutoCommit": \.wubiAutoCommit, "WubiHint": \.wubiHint,
        "Traditional": \.traditional, "AutoPairPunct": \.autoPairPunct, "PickChar": \.pickChar, "Association": \.association,
        "DateTime": \.dateTime, "Calculator": \.calculator, "EmojiSuggest": \.emojiSuggest,
        "AutoSpace": \.autoSpace, "AutoSpaceLetters": \.autoSpaceLetters, "AutoSpaceDigits": \.autoSpaceDigits,
        "Toolbar": \.toolbar, "ClipboardHistory": \.clipboardHistory, "Voice": \.voice, "VoiceCopy": \.voiceCopy,
        "ClipboardSync": \.clipboardSync, "ClipboardSyncLan": \.clipboardSyncLan,
        "ClipboardSyncPaste": \.clipboardSyncPaste,
        "Translate": \.translate, "TranslateFormal": \.translateFormal, "TranslateOneShot": \.translateOneShot,
        "TranslateLocal": \.translateLocal,
        "CheckUpdate": \.checkUpdate, "BetaUpdates": \.betaUpdates, "TypingStats": \.typingStats,
        "DeveloperMode": \.developerMode,
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
        case "InitialMode":
            if let v = matchName(value, InitialMode.allCases.map(\.rawValue)) { initialMode = InitialMode(rawValue: v)! }
        case "WindowMode":
            if let v = matchName(value, WindowMode.allCases.map(\.rawValue)) { windowMode = WindowMode(rawValue: v)! }
        case "PunctuationStyle":
            if let v = matchName(value, ["Fullwidth", "Halfwidth"]) { halfwidthPunct = v == "Halfwidth" }
        case "SelectKeys":
            if let v = matchName(value, SelectKeys.allCases.map(\.rawValue)) { selectKeys = SelectKeys(rawValue: v)! }
        case "Lexicon": lexicon = value
        case "CandidateFontSize":
            if let n = Int(value) { candidateFontSize = min(max(n, 10), 40) }
        case "VoiceKey": voiceKey = value
        case "VoiceSilenceTimeout":
            if let n = Int(value) { voiceSilenceTimeout = min(max(n, 0), 60000) }
        case "EmojiKey":
            // 留空是不用快捷键；写错了保持默认
            if value.isEmpty {
                emojiKey = nil
            } else if let key = Shortcut(name: value) {
                emojiKey = key
            }
        case "ToggleKey", "TranslateModeKey":
            // 留空是不用；写错了保持原样
            let path: WritableKeyPath<WowtypeConfig, Shortcut?> = key == "ToggleKey" ? \.toggleKey : \.translateModeKey
            if value.isEmpty {
                self[keyPath: path] = nil
            } else if let shortcut = Shortcut(name: value) {
                self[keyPath: path] = shortcut
            }
        case "SettingsTheme":
            if let v = matchName(value, SettingsTheme.allCases.map(\.rawValue)) { settingsTheme = SettingsTheme(rawValue: v)! }
        case "SettingsAccent":
            if let v = matchName(value, WowtypeConfig.accentPresets.map(\.value)) { settingsAccent = v }
        case "TranslateTarget":
            if let v = matchName(value, WowtypeConfig.translateTargets) { translateTarget = v }
        case "TranslateBaseUrl": translateBaseUrl = value
        case "ClipboardSyncRelayUrl": clipboardSyncRelayUrl = value
        case "ClipboardSyncDeviceName": clipboardSyncDeviceName = value
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
        case "InitialMode": return initialMode.rawValue
        case "WindowMode": return windowMode.rawValue
        case "PunctuationStyle": return halfwidthPunct ? "Halfwidth" : "Fullwidth"
        case "SelectKeys": return selectKeys.rawValue
        case "Lexicon": return lexicon
        case "CandidateFontSize": return String(candidateFontSize)
        case "VoiceKey": return voiceKey
        case "VoiceSilenceTimeout": return String(voiceSilenceTimeout)
        case "EmojiKey": return emojiKey?.name ?? ""
        case "ToggleKey": return toggleKey?.name ?? ""
        case "TranslateModeKey": return translateModeKey?.name ?? ""
        case "SettingsTheme": return settingsTheme.rawValue
        case "SettingsAccent": return settingsAccent
        case "TranslateTarget": return translateTarget
        case "TranslateBaseUrl": return translateBaseUrl
        case "ClipboardSyncRelayUrl": return clipboardSyncRelayUrl
        case "ClipboardSyncDeviceName": return clipboardSyncDeviceName
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
    /// 改完拿回 Linux 照样能用。文件里没有、又不是默认值的键：有模板里那样注释掉的一行（# 键=默认值）就地换成
    /// 生效的，没有就补在最后一个设置后面（[分组] 前面）。和默认值一样的键不往里补，以后改了默认值没改过的人跟着变。
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
        /// 注释掉的设置行（# PageSize=9）在哪一行：这个键要写进去时就地换成生效的
        var commented: [String: Int] = [:]
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
            if firstGroup == nil, let key = WowtypeConfig.commentedKey(body), commented[key] == nil {
                commented[key] = i
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

        // 文件里没有的键读出来是默认值；TranslateLocal 没写时跟着 TranslateBaseUrl 走（见 parse），按读回来的值比。
        // 有注释掉的那一行（模板里的 # 键=默认值）就地换掉，免得同一个键一行注释着默认值、文件末尾又写一行
        var implied = WowtypeConfig()
        implied.translateLocal = WowtypeConfig.impliedTranslateLocal(baseUrl: translateBaseUrl)
        var missing: [String] = []
        for key in WowtypeConfig.keys {
            guard !seen.contains(key), let v = value(forKey: key), v != implied.value(forKey: key) else {
                continue
            }
            let entry = key + "=" + quote(v) + (crlf ? "\r" : "")
            if let i = commented[key] {
                lines[i] = entry
            } else {
                missing.append(entry)
            }
        }

        // 0.3.12 及以前的双拼开关（parse 读过了）：删掉，方案只看 InputScheme（这些行都在 [分组] 前面）。
        // 放在就地换注释行后面：删行会挪动 commented 记的行号
        for i in oldShuangpin.reversed() {
            lines.remove(at: i)
        }
        firstGroup = firstGroup.map { $0 - oldShuangpin.count }
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

    /// 注释掉的设置行（# PageSize=9、#PageSize=9）是哪个键；别的注释、不是注释的行是 nil。
    static func commentedKey(_ body: String) -> String? {
        guard body.hasPrefix("#") else { return nil }
        let rest = body.dropFirst()
        guard let eq = rest.firstIndex(of: "=") else { return nil }
        let key = trim(rest[..<eq])
        return WowtypeConfig.keys.contains(key) ? key : nil
    }

    /// 第一次打开设置时写出来的文件：带说明，每项都是注释掉的默认值（# PageSize=9），一项都不生效。
    /// 设置窗口只把改过的键写进来（就地换掉那一行），以后改了默认值，没改过的人跟着变。
    public static func template() -> String {
        defaultsDocument().split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            line.isEmpty || line.hasPrefix("#") ? String(line) : "# " + String(line)
        }.joined(separator: "\n")
    }

    /// 模板的原文：说明 + 每项「键=默认值」（template 再把设置行注释掉）。
    private static func defaultsDocument() -> String {
        let d = WowtypeConfig()
        func b(_ v: Bool) -> String { v ? "True" : "False" }
        return """
        # WowType 设置（键名和 Linux 的 wowtype.conf 一样，见 docs/CONFIG.md）。
        # 前面带 # 的设置行是默认值，不生效；要改哪一项，去掉那一行前面的 # 再改值。
        # 改完保存，下一次按键时生效；删掉一行就是用默认值。注释要单独写一行。
        # 设置窗口只写和默认值不一样的项，以后默认值变了，没改过的项跟着变。

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
        # 联想：上屏以后给出常跟在后面的词，按 Tab 进联想行再用空格、数字选（不按 Tab 时数字、空格照常）
        Association=\(b(d.association))

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
        # 输入框里的拼音用空格分音节（ni hao），不用 '；网页代码块里留下半截拼音时打开
        InlineSpaceSeparator=\(b(d.inlineSpaceSeparator))

        # 输入方案：Quanpin 全拼、Shuangpin 双拼、Wubi86 五笔 86
        InputScheme=\(d.inputScheme.rawValue)
        # 双拼方案：Ziranma 自然码、Xiaohe 小鹤、Microsoft 微软、Sogou 搜狗、ABC 智能 ABC、
        # Ziguang 紫光、PinyinJiajia 拼音加加
        ShuangpinScheme=\(d.shuangpinScheme)
        # 双拼时编辑区显示打的键（不翻成全拼）
        ShuangpinShowKeys=\(b(d.shuangpinShowKeys))
        # 双拼简拼：只打声母也出词（sm 出「什么」），按双拼读得通的排在前面
        ShuangpinAbbrev=\(b(d.shuangpinAbbrev))
        # 五笔打满四码、只有一个字词时直接上屏
        WubiAutoCommit=\(b(d.wubiAutoCommit))
        # 五笔候选后面显示还要打的码
        WubiHint=\(b(d.wubiHint))

        # 单按哪个 Shift 切中英文：Both、Left、Right、Off
        ShiftToggle=Both
        # 从别的输入法切到 WowType、开机后第一次用时：Chinese 中文、English 英文、Last 和上次一样（每个应用自己记）。
        # 换窗口、换应用不算；关了 Shift 切换（ShiftToggle 是 Off）、也没设 ToggleKey 时总是中文
        InitialMode=\(d.initialMode.rawValue)
        # 换到别的应用、别的窗口时：Same 和上次一样（每个应用自己记）、Chinese 中文、English 英文。
        # 从别的输入法切回来时按 InitialMode
        WindowMode=\(d.windowMode.rawValue)
        # 输出繁体字
        Traditional=\(b(d.traditional))
        # 标点：Fullwidth 中文标点、Halfwidth 英文标点
        PunctuationStyle=Fullwidth
        # 中文标点自动配对：打 ( [ < { " ' 上屏成对的（）【】《》「」“”‘’，光标放到中间；在里面打完再按右半边跳过补好的那个，
        # 里面空着时退格两个一起删。应用说不清光标在哪（比如终端）时不配对
        AutoPairPunct=\(b(d.autoPairPunct))
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
        # 跨设备复制粘贴：一台设备上复制的文字，在配过对的另一台上直接粘贴（配对在设置窗口「输入」页做）。
        # 内容端到端加密；同一个局域网里直接传，不在一个局域网时走自己部署的中转服务（留空不用）
        ClipboardSync=\(b(d.clipboardSync))
        ClipboardSyncLan=\(b(d.clipboardSyncLan))
        ClipboardSyncRelayUrl=
        ClipboardSyncDeviceName=
        # 收到的也放进系统剪贴板（能直接 Command+V）；关掉只出现在 v + 空格的「剪贴板」里
        ClipboardSyncPaste=\(b(d.clipboardSyncPaste))

        # 语音输入：按住语音键说话，松开出字（点按一下也行，说完停一下自动结束）。模型在设置窗口「语音」页下载
        Voice=\(b(d.voice))
        # 语音键：Alt_R 右 Option、Control_R 右 Control、F8、F9、F10；留空不用
        VoiceKey=\(d.voiceKey)
        # 点按说话时没声音多久自动结束，毫秒：1500（1.5 秒）、3000、5000、10000、30000；
        # 0 不自动结束，再点一下语音键结束（一次最长录 2 分钟）。长按说话松开就结束，不看这一项
        VoiceSilenceTimeout=\(d.voiceSilenceTimeout)
        # 说的话上屏的同时复制到剪贴板
        VoiceCopy=\(b(d.voiceCopy))
        # 打开表情面板的快捷键，键名同 fcitx5：Control+period、Control+semicolon、Control+Shift+E；留空不用。
        # Command 组合键多半到不了输入法，写 Super 的当 Control
        EmojiKey=\(d.emojiKey?.name ?? "")
        # 另设一个切换中 / 英文的快捷键，比如 Control+Shift+space；留空不用（单按 Shift 照常）。
        # 系统的快捷键（Control+space 选上一个输入法）先被系统拿走，WowType 收不到
        ToggleKey=\(d.toggleKey?.name ?? "")
        # 进出「译」的快捷键，比如 Control+Shift+Y；留空不用。设了以后单按 Shift 只在中英之间切
        TranslateModeKey=\(d.translateModeKey?.name ?? "")
        # 自动检查更新：输入法每天最多查一次 GitHub 上的新版本，有新版时输入法菜单里多一项；设置窗口打开时也查
        CheckUpdate=\(b(d.checkUpdate))
        # Beta 计划：检查更新也算预发布版（新功能先到，可能不稳定）；关掉以后装上的预发布版不退回，等正式版追上来
        BetaUpdates=\(b(d.betaUpdates))
        # 打字统计：只在本机按天记字数、按键次数这些计数，不记打的内容；默认关，关着时什么都不记
        TypingStats=\(b(d.typingStats))
        # 开发者模式：把每次上屏打的输入、当时的候选、选了第几个明文记进数据目录的 devlog.jsonl（调排序用）；默认关
        DeveloperMode=\(b(d.developerMode))
        # 设置窗口的主题：System 跟随系统、Light 浅色、Dark 深色（只管设置窗口，不管候选框）
        SettingsTheme=\(d.settingsTheme.rawValue)
        # 设置窗口的强调色：Green 绿色、Blue 蓝色、Purple 紫色、Orange 橙色、Pink 粉色
        SettingsAccent=\(d.settingsAccent)

        # 词库文件（拼音<TAB>词<TAB>频次），留空用自带的雾凇词库；文件不在也用自带的
        Lexicon=

        # 互译：打开后单按 Shift 在 中 → 英 → 译 之间切（没配好翻译时只在中英之间切；设了 TranslateModeKey 时用它进出）。
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
        # 双击 Shift 单次互译：打开后单按 Shift 只在中英之间切，0.35 秒内连按两下 Shift（或按互译键）
        # 进「译」只翻一句，译文上屏（或 Esc、单按 Shift 放弃）后回到原来的模式。关着时双击 Shift 不切换
        TranslateOneShot=\(b(d.translateOneShot))
        # 用本地模型（腾讯混元 Hy-MT3 1.8B，离线）翻译，默认 True；False 用上面的服务。
        # 删掉这一行时：上面填了 TranslateBaseUrl 就当 False（以前的设置照旧用服务），没填就是 True。
        # 模型和运行它的 llama-server 在设置窗口「翻译」页一键下载，放在数据目录的 models/ 和 llama/
        # （模型不是开源许可，不适用于欧盟、英国和韩国，见 docs/CONFIG.md）
        TranslateLocal=\(b(d.translateLocal))
        # 模型文件的位置，留空用 models/Hy-MT3-1.8B-Q4_K_M.gguf
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
