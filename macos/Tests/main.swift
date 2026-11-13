// macOS 外壳的按键测试：用一个假的输入框（FakeClient）把按键喂给 Composer，看上屏、编辑区、候选框。
// 不依赖 AppKit，Linux 和 macOS 都能跑（macos/test.sh）。
//
//   harness <lexicon.tsv> [english.txt]
//
// 没给词库时自己写一份小词库（shi 有 3 页候选，测翻页）。

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class FakeClient: TextClient {
    var committed = ""
    var marked = ""
    var markedCursor = 0
    var page: CandidatePage?
    /// false：像开着安全输入的密码框，不翻译
    var allowsTranslation = true

    func insertText(_ text: String) {
        committed += text
        marked = ""
    }

    func setMarkedText(_ text: String, cursor: Int) {
        marked = text
        markedCursor = cursor
    }

    func showCandidates(_ page: CandidatePage?) {
        self.page = page
    }

    var previousCharacter: UInt32 {
        committed.unicodeScalars.last?.value ?? 0
    }
}

var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

func type(_ composer: Composer, _ text: String) {
    for c in text {
        _ = composer.handle(.char(c))
    }
}

func writeFile(_ path: String, _ text: String) {
    guard let f = fopen(path, "w") else {
        print("FAIL 写文件 \(path)")
        exit(1)
    }
    fputs(text, f)
    fclose(f)
}

/// 测试用的小词库：你好、ni/hao 的单字、略（lve），加上 shi 的 24 个字（9 个一页，3 页）。
func writeTestLexicon() -> String {
    var lines = ["nihao\t你好\t50000", "ni\t你\t40000", "ni\t尼\t3000", "hao\t好\t40000", "hao\t号\t5000",
                 "shishi\t事实\t8000", "lve\t略\t30000", "kai xin\t开心\t30000"]
    let shi = Array("是十时事市使实式试世师史石示视适识施室势诗释湿")
    for (i, ch) in shi.enumerated() {
        lines.append("shi\t\(ch)\t\(60000 - i * 1000)")
    }
    let path = "/tmp/wowtype-macos-harness-\(getpid()).tsv"
    guard let f = fopen(path, "w") else {
        print("FAIL 写测试词库 \(path)")
        exit(1)
    }
    fputs(lines.joined(separator: "\n") + "\n", f)
    fclose(f)
    return path
}

let args = CommandLine.arguments
let ownLexicon = args.count <= 1
let lexicon = ownLexicon ? writeTestLexicon() : args[1]
guard let engine = Engine(lexicon: lexicon) else {
    print("FAIL 载入词库 \(lexicon)")
    exit(1)
}
if args.count > 2 {
    engine.loadEnglish(args[2])
} else {
    let english = "/tmp/wowtype-macos-harness-\(getpid()).en.txt"
    writeFile(english, "hello\niPhone\n")
    engine.loadEnglish(english)
    unlink(english)
}
if ownLexicon {
    // 已经读进内存了；词库旁边的快照也一起删
    unlink(lexicon)
    unlink(lexicon + ".wcache")
}
check(Engine.abiVersion > 0, "ABI 版本 \(Engine.abiVersion)")

func fresh() -> (Composer, FakeClient) {
    let client = FakeClient()
    return (Composer(engine: engine, client: client), client)
}

do {
    let (c, client) = fresh()
    type(c, "nihao")
    check(c.isComposing, "打 nihao 进编辑区")
    check(client.marked == "ni'hao", "编辑区分音节", client.marked)
    check(client.markedCursor == client.marked.utf16.count, "光标在编辑区末尾", "\(client.markedCursor)")
    check(client.page?.texts.first == "你好", "第一个候选是你好", "\(client.page?.texts ?? [])")
    _ = c.handle(.char(" "))
    check(client.committed == "你好", "空格上屏第一个", client.committed)
    check(!c.isComposing && client.marked.isEmpty && client.page == nil, "上屏后清空编辑区和候选框")
}

do {
    let (c, client) = fresh()
    type(c, "shi")
    let texts = client.page?.texts ?? []
    check(texts.count > 1, "shi 有多个候选", "\(texts)")
    _ = c.handle(.char("2"))
    check(texts.count > 1 && client.committed == texts[1], "数字 2 选第二个", client.committed)
}

do {
    let (c, client) = fresh()
    type(c, "shi")
    let all = c.allCandidates()
    check(all.count > c.pageSize, "shi 不止一页", "\(all.count)")
    check(client.page?.texts.count == c.pageSize && client.page?.hasNext == true && client.page?.hasPrev == false,
          "第一页 9 个，后面还有", "\(client.page?.texts.count ?? 0)")
    if all.count > c.pageSize {
        _ = c.handle(.char("="))
        check(client.page?.hasPrev == true, "= 翻到第二页")
        check(client.page?.texts.first == all[c.pageSize], "第二页从第 10 个开始",
              "\(client.page?.texts.first ?? "") vs \(all[c.pageSize])")
        _ = c.handle(.char("-"))
        check(client.page?.texts.first == all[0] && client.committed.isEmpty, "- 翻回第一页，不当标点上屏",
              client.committed)
        _ = c.handle(.char("-"))
        check(client.committed.isEmpty && c.isComposing, "第一页再按 - 吃掉（不上屏减号）", client.committed)
        _ = c.handle(.key(Keysym.pageDown))
        _ = c.handle(.char("1"))
        check(client.committed == all[c.pageSize], "第二页按 1 选第二页的第一个", client.committed)
    }
}

do {
    let (c, client) = fresh()
    type(c, "shi")
    let all = c.allCandidates()
    // 一直按右键：光标越过一页时候选框跟着翻页（fcitx5 那边出过「光标到了下一页、框还停在第一页」）
    for _ in 0..<(c.pageSize + 2) {
        _ = c.handle(.key(Keysym.right))
    }
    if all.count > c.pageSize + 2 {
        check(client.page?.hasPrev == true && client.page?.cursor == 2, "右键越过一页自动翻页",
              "\(client.page?.cursor ?? -1)")
        _ = c.handle(.char(" "))
        check(client.committed == all[c.pageSize + 2], "空格选光标所在的", client.committed)
    }
}

do {
    // 横排时下键展开面板：一行 6 个，下键走一行，空格选光标处的，上键在第一行收起
    let (c, client) = fresh()
    type(c, "shi")
    let all = c.allCandidates()
    _ = c.handle(.key(Keysym.down))
    let cols = CandidatePage.columns
    check(client.page?.expanded == true, "下键展开面板")
    check(client.page?.texts.count == min(all.count, 6 * cols), "面板一屏最多 36 个",
          "\(client.page?.texts.count ?? 0)")
    _ = c.handle(.key(Keysym.down))
    check(client.page?.cursor == cols, "面板里下键走一行", "\(client.page?.cursor ?? -1)")
    _ = c.handle(.char("2"))
    check(client.committed == all[cols + 1], "面板里数字选光标所在行的第几个", client.committed)
    type(c, "shi")
    _ = c.handle(.key(Keysym.down))
    _ = c.handle(.key(Keysym.up))
    check(client.page?.expanded == false && c.isComposing, "第一行再按上键收起面板")
    _ = c.handle(.key(Keysym.down))
    // 刚选过的字会被学习往前排，重新取一次候选
    let first = c.allCandidates().first ?? ""
    _ = c.handle(.char(","))
    check(client.committed.hasSuffix(first + "，"), "面板开着按逗号：收起、上屏候选再上屏逗号", client.committed)
}

do {
    // lue 和 lve 一样（反馈 #102）
    let (c, client) = fresh()
    type(c, "lue")
    check(client.page?.texts.first == "略", "lue 出略", "\(client.page?.texts ?? [])")
}

do {
    // 没在打字时：^ 省略号、_ 破折号、引号左右交替（反馈 #102）
    let (c, client) = fresh()
    _ = c.handle(.char("^", .shift))
    _ = c.handle(.char("_", .shift))
    check(client.committed == "……——", "^ _", client.committed)
    _ = c.handle(.char("\"", .shift))
    type(c, "nihao")
    _ = c.handle(.char("\"", .shift))
    check(client.committed == "……——“你好”", "双引号左右交替（打字途中按引号先上屏候选）", client.committed)
}

do {
    let (c, client) = fresh()
    type(c, "nih")
    _ = c.handle(.key(Keysym.backspace))
    check(c.input == "ni", "退格删一个字母", c.input)
    _ = c.handle(.key(Keysym.escape))
    check(!c.isComposing && client.committed.isEmpty, "Esc 清空不上屏")
}

do {
    let (c, client) = fresh()
    type(c, "nihao")
    _ = c.handle(.key(Keysym.returnKey))
    check(client.committed == "nihao", "回车上屏原始字母", client.committed)
}

do {
    let (c, client) = fresh()
    type(c, "nihao")
    _ = c.handle(.char(","))
    check(client.committed == "你好，", "打字途中按逗号：先上屏候选再上屏中文逗号", client.committed)
    _ = c.handle(.char("."))
    check(client.committed == "你好，。", "没在打字时句号是中文句号", client.committed)
}

do {
    let (c, client) = fresh()
    // 以词定字：[ 取首选的第一个字，] 取最后一个字
    type(c, "nihao")
    _ = c.handle(.char("["))
    check(client.committed == "你", "以词定字 [ 取第一个字", client.committed)
    type(c, "nihao")
    _ = c.handle(.char("]"))
    check(client.committed == "你好", "以词定字 ] 取最后一个字", client.committed)
}

do {
    let (c, client) = fresh()
    // @ # % 没有中文写法，交给应用；{ } 是直角引号
    check(!c.handle(.char("@", .shift)), "@ 交给应用")
    check(!c.handle(.char("%", .shift)), "% 交给应用")
    _ = c.handle(.char("{", .shift))
    type(c, "nihao")
    _ = c.handle(.char("}", .shift))
    check(client.committed == "「你好」", "{ } 是直角引号", client.committed)
    type(c, "nihao")
    _ = c.handle(.char("@", .shift))
    check(client.committed == "「你好」你好@", "打字途中按 @：先上屏候选再上屏半角 @", client.committed)
}

do {
    let (c, client) = fresh()
    // 数字交给了应用，光标前是数字：后面的符号也交给应用原样上屏（20:22、3,000）
    client.committed = "20"
    check(!c.handle(.char(":")), "数字后的冒号交给应用", client.committed)
    client.committed += ":22"
    check(!c.handle(.char(",")), "数字后的逗号交给应用", client.committed)
    client.committed += ","
    check(client.committed == "20:22,", "数字后的符号不换成中文标点", client.committed)
    type(c, "nihao")
    _ = c.handle(.char(":"))
    check(client.committed == "20:22,你好：", "汉字后面的冒号还是中文冒号", client.committed)
}

do {
    let (c, client) = fresh()
    // 不在打字时数字、快捷键交给应用
    check(!c.handle(.char("1")), "数字交给应用")
    check(!c.handle(.char("c", .command)), "Command+C 交给应用")
    check(client.committed.isEmpty, "没有上屏")
}

do {
    // 没在打字时的大写字母和 Linux 一样进编辑区（大写原样保留），出英文候选
    let (c, client) = fresh()
    check(c.handle(.char("H", .shift)) && c.isComposing, "大写字母开始编辑区", c.input)
    type(c, "ello")
    check(c.input == "Hello", "大写原样保留", c.input)
    check(c.allCandidates().contains("Hello"), "Hello 有英文候选", "\(c.allCandidates().prefix(5))")
    _ = c.handle(.key(Keysym.returnKey))
    check(client.committed == "Hello", "回车上屏 Hello", client.committed)
    _ = c.handle(.char("A", [.shift, .caps]))
    check(c.input == "A", "Caps Lock 下的大写也进编辑区", c.input)
}

do {
    let (c, client) = fresh()
    type(c, "ni")
    // 单按 Shift：打到一半切英文，字母原样上屏
    check(c.shiftChanged(down: true, otherModifiers: false, now: 1.0) == false, "按下 Shift 不切")
    check(c.shiftChanged(down: false, otherModifiers: false, now: 1.2), "0.2 秒内松开算单按")
    check(c.mode == .english && client.committed == "ni", "切英文并上屏 ni", client.committed)
    check(!c.handle(.char("a")), "英文模式字母交给应用")
    _ = c.shiftChanged(down: true, otherModifiers: false, now: 2.0)
    _ = c.handle(.char("A", .shift))
    check(!c.shiftChanged(down: false, otherModifiers: false, now: 2.1), "Shift+A 不算单按")
    _ = c.shiftChanged(down: true, otherModifiers: false, now: 3.0)
    check(!c.shiftChanged(down: false, otherModifiers: false, now: 3.8), "按太久不算单按")
    _ = c.shiftChanged(down: true, otherModifiers: false, now: 4.0)
    check(c.shiftChanged(down: false, otherModifiers: false, now: 4.1) && c.mode == .chinese, "再单按切回中文")
}

do {
    let (c, client) = fresh()
    type(c, "nihao")
    c.commitComposition()
    check(client.committed == "nihao" && !c.isComposing, "切走输入法时原样上屏", client.committed)
}

do {
    // NSEvent 的字段 → KeyInput
    let a = translateKeyDown(keyCode: 0, characters: "a", charactersIgnoringModifiers: "a", cocoaFlags: 0)
    check(a == .char("a"), "a")
    let bang = translateKeyDown(keyCode: 18, characters: "!", charactersIgnoringModifiers: "1", cocoaFlags: 1 << 17)
    check(bang == .char("!", .shift), "Shift+1 是 !")
    let cmdC = translateKeyDown(keyCode: 8, characters: "c", charactersIgnoringModifiers: "c", cocoaFlags: 1 << 20)
    check(cmdC == .char("c", .command), "Command+C")
    let optE = translateKeyDown(keyCode: 14, characters: "´", charactersIgnoringModifiers: "e", cocoaFlags: 1 << 19)
    check(optE == .char("e", .option), "Option+E 不用组合出来的字符")
    let del = translateKeyDown(keyCode: VirtualKey.backspace, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", cocoaFlags: 0)
    check(del == .key(Keysym.backspace), "退格")
    let arrow = translateKeyDown(keyCode: VirtualKey.down, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", cocoaFlags: 1 << 23)
    check(arrow == .key(Keysym.down), "方向键（带 numericPad / function 标志）")
    check(utf16Offset("你好a", byteOffset: 6) == 2, "UTF-8 偏移转 UTF-16")
}

do {
    // 词库还没载入（外壳在后台读词库）：字母交给应用，载入以后照常打字
    let client = FakeClient()
    let c = Composer(engine: nil, client: client)
    check(!c.handle(.char("n")) && !c.isComposing, "没有词库时字母交给应用")
    check(!c.handle(.char(",")), "没有词库时标点也交给应用")
    c.setEngine(engine)
    type(c, "nihao")
    _ = c.handle(.char(" "))
    check(client.committed == "你好", "载入词库后照常打字", client.committed)
}

do {
    let (c, _) = fresh()
    var commits: [String] = []
    c.onCommit = { commits.append($0) }
    type(c, "nihao")
    _ = c.handle(.char(" "))
    _ = c.handle(.char(","))
    // 只上屏标点不算学到了词，不回调（外壳按回调攒次数存学习数据）
    check(commits == ["你好"], "上屏回调", "\(commits)")
}

do {
    // NSEvent → KeyInput：Control+Delete（Mac 的 Delete 是退格）、Fn+Control+Delete（向前删除）
    let ctrlBs = translateKeyDown(keyCode: VirtualKey.backspace, characters: "\u{7f}",
                                  charactersIgnoringModifiers: "\u{7f}", cocoaFlags: 1 << 18)
    check(ctrlBs == .key(Keysym.backspace, .control), "Control+Delete 是 Ctrl+退格")
    let ctrlFwd = translateKeyDown(keyCode: VirtualKey.forwardDelete, characters: "\u{f728}",
                                   charactersIgnoringModifiers: "\u{f728}", cocoaFlags: 1 << 18 | 1 << 23)
    check(ctrlFwd == .key(Keysym.delete, .control), "Fn+Control+Delete 是 Ctrl+向前删除")

    // 分几次选出来的词（尼 + 号）用一次就学会；学错了光标停在它上面按 Control+Delete 忘掉
    let (c, client) = fresh()
    var forgets = 0
    c.onForget = { forgets += 1 }
    type(c, "nihao")
    if let ni = client.page?.texts.firstIndex(of: "尼") {
        c.select(ni)
        if let hao = client.page?.texts.firstIndex(of: "号") {
            c.select(hao)
        }
    }
    check(client.committed == "尼号", "选 尼 再选 号 上屏 尼号", client.committed)
    client.committed = ""
    type(c, "nihao")
    let learned = client.page?.texts ?? []
    if let at = learned.firstIndex(of: "尼号") {
        for _ in 0..<at {
            _ = c.handle(.key(Keysym.right))
        }
    }
    check(learned.contains("尼号") && client.page?.texts[client.page?.cursor ?? 0] == "尼号",
          "学会以后 nihao 有 尼号，光标挪到它上面", "\(learned)")
    let marked = client.marked
    check(c.handle(.key(Keysym.backspace, .control)), "Control+Delete 吃掉")
    check(forgets == 1 && client.committed.isEmpty && client.marked == marked && c.input == "nihao",
          "忘掉以后马上存，编辑区不动", "\(forgets) \(client.committed) \(client.marked)")
    let after = client.page?.texts ?? []
    let was = learned.firstIndex(of: "尼号") ?? 0
    check((after.firstIndex(of: "尼号") ?? Int.max) > was, "忘掉以后 尼号 不再排在原来的位置", "\(learned) -> \(after)")
    _ = c.handle(.key(Keysym.escape))
    check(!c.handle(.key(Keysym.backspace, .control)), "没在打字时 Control+Delete 交给应用")
}

// MARK: 设置（wowtype.conf）

/// 照设置配好引擎和会话；测完把引擎改回默认（所有测试共用一个引擎）。
func withConfig(_ change: (inout WowtypeConfig) -> Void, _ body: (Composer, FakeClient) -> Void) {
    var config = WowtypeConfig()
    change(&config)
    let problems = engine.apply(config, conversion: "core/data/s2t.tsv")
    if !problems.isEmpty {
        print("     \(problems)")
    }
    let (c, client) = fresh()
    c.apply(config)
    body(c, client)
    engine.apply(WowtypeConfig())
}

do {
    // 默认值和 Linux 的 WowtypeConfig 一样
    let d = WowtypeConfig()
    check(d.horizontal && d.pageSize == 9 && d.pageKeys == 1, "默认横排、每页 9 个、- = 翻页")
    check(!d.fuzzy && d.fuzzyGroups == 1 | 2 | 4 | 64 | 128 | 256 | 512 | 1024, "默认模糊音关，分组同核心默认", "\(d.fuzzyGroups)")
    check(d.typoCorrection && !d.rareExtChars && !d.shuangpin && d.shuangpinScheme == "Ziranma", "默认纠错开、双拼关（自然码）")
    check(d.shiftToggle == .both && !d.traditional && !d.halfwidthPunct && d.selectKeys == .off, "默认 Shift 切换、简体、全角标点")
    check(d.pickChar && d.dateTime && d.calculator && d.emojiSuggest && d.autoSpaceFlags == 0 && d.lexicon.isEmpty,
          "默认以词定字、日期、计算器、emoji 推荐开，自动空格关，自带词库")
    check(WowtypeConfig.parse(WowtypeConfig.template()) == d, "写出来的设置模板读回来是默认值")
    check(WowtypeConfig.load(path: "/nonexistent/wowtype.conf") == d, "没有设置文件用默认值")

    let text = """
    # 注释
    CandidateLayout=Vertical
    PageSize=20
    Fuzzy=True
    FuzzyNL=True
    FuzzyZh=False
      TypoCorrection = False
    Shuangpin=True
    ShuangpinScheme=Xiaohe
    ShiftToggle=Right
    PunctuationStyle=Halfwidth
    SelectKeys=SemicolonQuote
    PageKeysBracket=True
    PageKeysMinusEqual=False
    AutoSpace=True
    AutoSpaceDigits=False
    Lexicon="~/dicts/my lexicon.tsv"
    CandidateFontSize=20
    Voice=True
    Traditional=maybe
    [Hotkey]
    PageSize=4
    """
    let c = WowtypeConfig.parse(text)
    check(!c.horizontal && c.pageSize == 9, "竖排；每页个数超出 3–9 取 9；[分组] 里的不算", "\(c.pageSize)")
    check(c.fuzzy && c.fuzzyGroups == (1 | 2 | 4 | 64 | 128 | 256 | 512 | 1024) & ~1 | 8, "模糊音分组", "\(c.fuzzyGroups)")
    check(!c.typoCorrection, "键值两边的空格不算")
    check(c.shuangpin && c.shuangpinScheme == "Xiaohe", "双拼方案", c.shuangpinScheme)
    // 和 fcitx5 一样区分大小写，认不出的回到默认（三端一样，见 spec/config.json 的 readRules）
    check(WowtypeConfig.parse("ShuangpinScheme=xiaohe").shuangpinScheme == "Ziranma"
          && WowtypeConfig.parse("ShuangpinScheme=Dvorak").shuangpinScheme == "Ziranma", "双拼方案写错、大小写不对用默认")
    check(c.shiftToggle == .right && c.halfwidthPunct && c.selectKeys == .semicolonQuote, "枚举值")
    check(c.pageKeys == 2, "翻页键", "\(c.pageKeys)")
    check(c.autoSpaceFlags == 1, "自动空格只加字母", "\(c.autoSpaceFlags)")
    check(c.lexicon == "~/dicts/my lexicon.tsv" && c.candidateFontSize == 20, "带引号的值、字号", c.lexicon)
    check(!c.traditional, "认不出的值保持默认")
    check(WowtypeConfig.parse("PageSize=5\r\nFuzzy=True\r\n") == { var w = WowtypeConfig(); w.pageSize = 5; w.fuzzy = true; return w }(),
          "Windows 换行（\\r\\n）")
}

withConfig({ $0.shuangpin = true; $0.shuangpinScheme = "Xiaohe" }) { c, client in
    // 小鹤双拼：ni = ni，hao = hc
    type(c, "nihc")
    check(client.page?.texts.first == "你好", "小鹤双拼 nihc 出你好", "\(client.page?.texts ?? [])")
    _ = c.handle(.char(" "))
    check(client.committed == "你好", "双拼空格上屏", client.committed)
}

withConfig({ $0.shuangpin = true }) { c, client in
    // 默认方案自然码：hao = hk
    type(c, "nihk")
    check(client.page?.texts.first == "你好", "自然码 nihk 出你好", "\(client.page?.texts ?? [])")
}

do {
    var config = WowtypeConfig()
    config.shuangpin = true
    config.shuangpinScheme = "Dvorak"
    check(!engine.apply(config).isEmpty, "不认识的双拼方案报出来（改用自然码）")
    engine.apply(WowtypeConfig())
}

withConfig({ _ in }) { c, client in
    type(c, "nihk")
    check(client.page?.texts.first != "你好", "关掉双拼后 nihk 不是你好", "\(client.page?.texts ?? [])")
}

// 纠错也会把 si 纠成 shi，测模糊音时关掉
withConfig({ $0.fuzzy = true; $0.typoCorrection = false }) { c, _ in
    // s = sh 默认开：si 也能出 是
    type(c, "si")
    check(c.allCandidates().contains("是"), "模糊音 si 出是", "\(c.allCandidates().prefix(9))")
}

withConfig({ $0.fuzzy = true; $0.fuzzySh = false; $0.typoCorrection = false }) { c, _ in
    type(c, "si")
    check(!c.allCandidates().contains("是"), "关掉 s=sh 这一组 si 不出是", "\(c.allCandidates().prefix(9))")
}

withConfig({ $0.typoCorrection = false }) { c, _ in
    type(c, "si")
    check(!c.allCandidates().contains("是"), "模糊音默认关", "\(c.allCandidates().prefix(9))")
}

withConfig({ _ in }) { c, _ in
    type(c, "si")
    check(c.allCandidates().contains("是"), "纠错默认开（si 纠成 shi）", "\(c.allCandidates().prefix(9))")
}

withConfig({ $0.pageSize = 5 }) { c, client in
    type(c, "shi")
    check(client.page?.texts.count == 5 && c.pageSize == 5, "每页 5 个", "\(client.page?.texts.count ?? 0)")
}

withConfig({ $0.horizontal = false }) { c, client in
    // 竖排：下键移光标，不展开面板
    type(c, "shi")
    _ = c.handle(.key(Keysym.down))
    check(client.page?.expanded == false && client.page?.cursor == 1, "竖排下键移光标", "\(client.page?.cursor ?? -1)")
}

withConfig({ $0.selectKeys = .semicolon }) { c, client in
    type(c, "shi")
    let second = client.page?.texts[1] ?? ""
    _ = c.handle(.char(";"))
    check(client.committed == second, "分号选第 2 个", client.committed)
}

withConfig({ $0.pageKeysMinus = false; $0.pageKeysBracket = true }) { c, client in
    // [ ] 翻页时以词定字让给翻页；- 不再翻页，打字途中按 - 先上屏候选再上屏
    type(c, "shi")
    let all = c.allCandidates()
    _ = c.handle(.char("]"))
    check(client.page?.texts.first == all[c.pageSize] && client.committed.isEmpty, "] 翻页", "\(client.page?.texts.first ?? "")")
    _ = c.handle(.char("-"))
    check(client.committed.hasSuffix("-") || client.committed.hasSuffix("－"), "- 不翻页", client.committed)
}

withConfig({ $0.pickChar = false }) { c, client in
    type(c, "nihao")
    _ = c.handle(.char("["))
    check(client.committed == "你好【", "关掉以词定字：[ 先上屏候选再出【", client.committed)
}

withConfig({ $0.halfwidthPunct = true }) { c, client in
    // 半角：没在打字时标点交给应用（应用原样上屏）；打字途中先上屏候选再上屏半角标点
    if !c.handle(.char(",")) {
        client.committed += ","
    }
    type(c, "nihao")
    _ = c.handle(.char("."))
    check(client.committed == ",你好.", "半角标点", client.committed)
}

withConfig({ $0.shiftToggle = .right }) { c, _ in
    _ = c.shiftChanged(down: true, otherModifiers: false, now: 1.0, right: false)
    check(!c.shiftChanged(down: false, otherModifiers: false, now: 1.1, right: false) && c.mode == .chinese, "只用右 Shift：左 Shift 不切")
    _ = c.shiftChanged(down: true, otherModifiers: false, now: 2.0, right: true)
    check(c.shiftChanged(down: false, otherModifiers: false, now: 2.1, right: true) && c.mode == .english, "右 Shift 切英文")
    var off = c.config
    off.shiftToggle = .off
    c.apply(off)
    check(c.mode == .chinese, "关掉 Shift 切换时回到中文")
    _ = c.shiftChanged(down: true, otherModifiers: false, now: 3.0, right: true)
    check(!c.shiftChanged(down: false, otherModifiers: false, now: 3.1, right: true), "关掉以后单按 Shift 不切")
}

withConfig({ $0.autoSpace = true }) { c, client in
    // 汉字后面打数字、汉字前面是字母：补一个空格
    client.committed = "第"
    check(c.handle(.char("5")), "汉字后面的数字自己上屏")
    client.committed += "章abc"
    type(c, "nihao")
    _ = c.handle(.char(" "))
    check(client.committed == "第 5章abc 你好", "自动加空格", client.committed)
    _ = c.shiftChanged(down: true, otherModifiers: false, now: 1.0)
    _ = c.shiftChanged(down: false, otherModifiers: false, now: 1.1)
    check(c.handle(.char("x")) && client.committed.hasSuffix("你好 x"), "英文模式汉字后面的字母补空格", client.committed)
    check(!c.handle(.char("y")), "字母后面的字母照常交给应用")
}

withConfig({ _ in }) { c, client in
    client.committed = "第"
    check(!c.handle(.char("5")), "自动加空格默认关")
}

withConfig({ $0.traditional = true }) { c, _ in
    type(c, "shi")
    let all = c.allCandidates()
    check(all.contains("時") && !all.contains("时"), "繁体输出", "\(all.prefix(9))")
}

withConfig({ _ in }) { c, _ in
    type(c, "shi")
    check(c.allCandidates().contains("时"), "关掉繁体回到简体")
}

do {
    // 设置窗口写回 wowtype.conf：只改认识的键，别的行原样留着；读回来就是写进去的设置
    let d = WowtypeConfig()
    check(d.serialized(into: nil) == WowtypeConfig.template(), "没有设置文件：写出来的是模板")
    check(Set(WowtypeConfig.keys).count == WowtypeConfig.keys.count
          && WowtypeConfig.keys.allSatisfy { d.value(forKey: $0) != nil }, "每个键都有写法")
    let template = WowtypeConfig.template()
    check(WowtypeConfig.keys.allSatisfy { template.contains("\n" + $0 + "=") }, "模板里每个键都有")
    // 加了新设置（模板里多了一行）却没加进 keys / setValue / value(forKey:)：设置窗口写不回去
    let templateKeys = template.split(separator: "\n").compactMap { line -> String? in
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
        return String(line[..<eq])
    }
    check(Set(templateKeys) == Set(WowtypeConfig.keys) && templateKeys.allSatisfy { d.value(forKey: $0) != nil },
          "模板里的键都能写回去", "\(Set(templateKeys).symmetricDifference(WowtypeConfig.keys))")
    check(d.value(forKey: "CheckUpdate") == nil, "不认识的键没有写法")

    // 每一项都改成不是默认值：写出来读回来一样（不管从模板、空文件还是只有注释的文件开始）
    var all = WowtypeConfig()
    for key in WowtypeConfig.keys {
        if d.value(forKey: key) == "True" { all.setValue("False", forKey: key) }
        if d.value(forKey: key) == "False" { all.setValue("True", forKey: key) }
    }
    all.horizontal = false
    all.arrowKeys = .caret
    all.pageSize = 4
    all.candidateFontSize = 22
    all.shuangpinScheme = "PinyinJiajia"
    all.shiftToggle = .off
    all.halfwidthPunct = true
    all.selectKeys = .semicolonQuote
    all.lexicon = "/Users/me/词库 \"新\"\\v2.tsv"
    all.emojiKey = Shortcut(name: "Control+Shift+E")
    all.toggleKey = Shortcut(name: "Control+space")
    all.voiceKey = "F8"
    all.translateTarget = "ja"
    all.translateBaseUrl = "http://127.0.0.1:11434/v1"
    all.translateModel = "qwen 2.5"
    all.translateLocalModel = "/Users/me/模型/HY-MT.gguf"
    all.translateLlamaServer = "/opt/homebrew/bin/llama-server"
    all.translateIdleMinutes = 30
    check(WowtypeConfig.keys.allSatisfy { all.value(forKey: $0) != d.value(forKey: $0) }, "每一项都改了")
    for (name, base) in [("模板", nil), ("空文件", ""), ("只有注释", "# 我的设置\n")] as [(String, String?)] {
        let out = all.serialized(into: base)
        check(WowtypeConfig.parse(out) == all, "每一项改过的设置写进\(name)再读回来一样", out)
        check(all.serialized(into: out) == out, "再写一次不变（\(name)）")
    }
    check(all.serialized(into: "# 我的设置\n").hasPrefix("# 我的设置\nCandidateLayout=Vertical\nArrowKeys=Caret\nPageSize=4\n"),
          "文件里没有的键照模板顺序补在后面")
    check(all.serialized(into: nil).contains("Lexicon=\"/Users/me/词库 \\\"新\\\"\\\\v2.tsv\""),
          "带空格、引号的值加引号转义", all.serialized(into: nil))

    // Linux 拷过来的文件：注释、不认识的键、[分组]、大小写、引号、空格都在
    let linux = """
    # 自己写的注释
    CandidateLayout=horizontal
    PageSize=20
      TypoCorrection = False
    Voice=True
    VoiceKey=Alt_R
    TranslateBaseUrl=https://api.deepseek.com/v1
    Lexicon="~/dicts/my lexicon.tsv"
    Traditional=maybe
    ShuangpinScheme=xiaohe

    [Hotkey]
    PageSize=4

    """
    let parsed = WowtypeConfig.parse(linux)
    check(parsed.serialized(into: linux) == linux, "设置没改：文件一个字都不动")

    var changed = parsed
    changed.pageSize = 5
    changed.typoCorrection = true
    changed.fuzzy = true
    changed.fuzzyNL = true
    changed.traditional = true
    let out = changed.serialized(into: linux)
    check(WowtypeConfig.parse(out) == changed, "改过的设置读回来一样", out)
    check(out.contains("\nPageSize=5\n") && out.contains("\n  TypoCorrection = True\n")
          && out.contains("\nTraditional=True\n"), "改的行只换值，前面的空格留着", out)
    check(out.contains("CandidateLayout=horizontal\n") && out.contains("Lexicon=\"~/dicts/my lexicon.tsv\"\n")
          && out.contains("ShuangpinScheme=xiaohe\n"), "没改的行原样（大小写、引号）", out)
    check(out.hasPrefix("# 自己写的注释\n") && out.contains("Voice=True\nVoiceKey=Alt_R\nTranslateBaseUrl=https://api.deepseek.com/v1\n"),
          "注释和不认识的键留着", out)
    check(out.hasSuffix("ShuangpinScheme=xiaohe\nFuzzy=True\nFuzzyNL=True\n\n[Hotkey]\nPageSize=4\n"),
          "新加的键补在 [分组] 前面，分组原样", out)

    var back = changed
    back.traditional = false
    let unparsable = back.serialized(into: linux)
    check(unparsable.contains("\nTraditional=maybe\n") && WowtypeConfig.parse(unparsable) == back,
          "认不出的值：要的是默认值就不动", unparsable)

    // 同一个键写了两次：都改；Windows 换行留着
    let twice = "PageSize=5\r\nFuzzy=False\r\nPageSize=7\r\n"
    var three = WowtypeConfig.parse(twice)
    three.pageSize = 3
    three.traditional = true
    check(three.serialized(into: twice) == "PageSize=3\r\nFuzzy=False\r\nPageSize=3\r\nTraditional=True\r\n",
          "重复的键都改，\\r\\n 留着", three.serialized(into: twice))

    // 窗口开着时文件在别处改了：窗口只写自己改的键
    let opened = "PageSize=7\nFuzzy=False\nVoice=True\n"
    let base = WowtypeConfig.parse(opened)
    var window = base
    window.pageSize = 4
    let edited = "PageSize=7\nFuzzy=True\nVoice=True\nTraditional=True\n"
    let merged = window.merged(changesFrom: base, into: edited)
    let mergedConfig = WowtypeConfig.parse(merged)
    check(merged == "PageSize=4\nFuzzy=True\nVoice=True\nTraditional=True\n", "合并：别处改的留着，窗口改的写上", merged)
    check(mergedConfig.pageSize == 4 && mergedConfig.fuzzy && mergedConfig.traditional, "合并后读回来")
    check(window.merged(changesFrom: base, into: nil) == window.serialized(into: nil), "文件被删了：从模板写")
}

do {
    // custom.tsv：没动的行原样写回去，加词、删词、导入照 Linux 设置界面的规则
    let text = "# 我的常用语\r\nni hao\t你好呀\t100\nmail\thello@example.com\n\n坏行\nzhang san\t \nbjdx\t北京大学\n"
    var words = CustomWords(text: text)
    check(words.entries == [.init(code: "ni hao", word: "你好呀"), .init(code: "mail", word: "hello@example.com"),
                            .init(code: "bjdx", word: "北京大学")], "读自定义词", "\(words.entries)")
    check(words.text == text, "没改：原样写回去（注释、频次、坏行都在）", words.text)
    check(CustomWords(text: "\u{FEFF}mail\ta@b.c").text == "mail\ta@b.c\n", "去掉 BOM，补上末尾换行")

    check(!words.add(code: "gs", word: "公司名"), "加新词")
    check(words.add(code: "ni hao ya", word: "你好呀"), "加已有的词：换编码")
    check(words.text == "# 我的常用语\r\nmail\thello@example.com\n\n坏行\nzhang san\t \nbjdx\t北京大学\ngs\t公司名\nni hao ya\t你好呀\n",
          "换编码的词挪到最后", words.text)
    check(words.remove(word: "北京大学") == [.init(code: "bjdx", word: "北京大学")] && words.remove(word: "没有") == [],
          "删词")
    check(!words.text.contains("北京大学") && words.text.hasPrefix("# 我的常用语\r\n"), "删掉的行没了，注释还在")

    let incoming = CustomWords.parseImport("# 注释\nNi Hǎo Ya\t你好呀\nzhang'san\t张三\nMAIL\thello@example.com\n123\t数字\nxyz?\t问号\n")
    check(incoming == [.init(code: "ni hao ya", word: "你好呀"), .init(code: "zhang san", word: "张三"),
                       .init(code: "mail", word: "hello@example.com")], "导入时整理编码，不对的不要", "\(incoming)")
    var imported = CustomWords(text: "mail\thello@example.com\nni hao\t你好呀\n")
    let counts = imported.merge(incoming)
    check(counts.added == 1 && counts.updated == 1, "导入：新增 1 个，更新 1 个，一样的不算", "\(counts)")
    check(imported.entries.map(\.word) == ["hello@example.com", "你好呀", "张三"], "导入后的顺序", "\(imported.entries)")

    let empty = CustomWords(text: nil)
    check(empty.entries.isEmpty && empty.text == CustomWords.header + "\n", "新文件只有说明")
    var fresh = empty
    fresh.add(code: "gs", word: "公司")
    check(CustomWords(text: fresh.text).entries == [.init(code: "gs", word: "公司")], "新文件加词读回来")
    check(CustomWords.isValidWord("四川省\\n宜宾市") && !CustomWords.isValidWord("a\tb")
          && !CustomWords.isValidWord("a\nb") && !CustomWords.isValidWord(""), "词里不能有 TAB、换行")

    for (input, want) in [("nihao", "ni hao"), ("Ni Hǎo", "ni hao"), ("ni3hao3", "ni hao"), ("xi'an", "xi an"),
                          ("xian", "xian"), ("Lǜ shī", "lv shi"), ("nu:", "nv"), ("nu\u{308}3", "nv"),
                          ("hua r", "hua r"), ("zhongguo", "zhong guo"), ("Biáng biáng miàn", "biang biang mian")] {
        check(CustomWords.normalizePinyin(input) == want, "拼音整理 \(input)", CustomWords.normalizePinyin(input) ?? "nil")
    }
    check(CustomWords.normalizePinyin("mail") == nil && CustomWords.normalizeCode("mail") == "mail"
          && CustomWords.normalizeCode("Addr") == "addr" && CustomWords.normalizeCode("a b?") == nil
          && CustomWords.normalizeCode("  ") == nil, "非拼音的字母编码")

    // 从词库猜拼音：整词取频次最高的，没有就逐字
    let lexiconText = "# 注释\nni hao\t你好\t500\nnihao\t你好\t10\nzhong\t重\t100\nchong\t重\t300\nni\t你\t1\nhao\t好\t1\nshi\t是\t9"
    func guess(_ word: String) -> String? {
        Array(lexiconText.utf8).withUnsafeBytes { CustomWords.guessPinyin(word, lexicon: $0) }
    }
    check(guess("你好") == "ni hao" && guess("重") == "chong", "整词取频次最高的", "\(guess("你好") ?? "nil") \(guess("重") ?? "nil")")
    check(guess("好你是") == "hao ni shi", "词库里没有的词逐字猜", guess("好你是") ?? "nil")
    check(guess("你你好") == "ni ni hao" && guess("好好") == "hao hao", "叠字逐字猜", guess("你你好") ?? "nil")
    check(guess("你x") == nil && guess("") == nil && guess("是") == "shi", "有猜不出的字就不猜；最后一行没换行也找得到")
    if !ownLexicon, let f = fopen(lexicon, "rb") {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while case let n = fread(&buffer, 1, buffer.count, f), n > 0 { bytes.append(contentsOf: buffer[0..<n]) }
        fclose(f)
        let real = bytes.withUnsafeBytes { CustomWords.guessPinyin("字节跳动", lexicon: $0) }
        check(real == "zi jie tiao dong", "真实词库猜拼音", real ?? "nil")
    }
}

do {
    // custom.tsv：自定义词排第一，简拼、非拼音编码也行；文件删掉就清空
    let path = "/tmp/wowtype-macos-harness-\(getpid()).custom.tsv"
    writeFile(path, "# 注释\nni hao\t你好呀\nmail\thello@example.com\n")
    check(engine.loadCustomWords(path) == 2, "载入 2 条自定义词")
    let (c, client) = fresh()
    type(c, "nihao")
    check(client.page?.texts.first == "你好呀", "自定义词排第一", "\(client.page?.texts ?? [])")
    _ = c.handle(.key(Keysym.escape))
    type(c, "nh")
    check(c.allCandidates().contains("你好呀"), "自定义词简拼也能打", "\(c.allCandidates().prefix(5))")
    _ = c.handle(.key(Keysym.escape))
    type(c, "mail")
    check(client.page?.texts.first == "hello@example.com", "非拼音编码", "\(client.page?.texts ?? [])")
    _ = c.handle(.key(Keysym.escape))
    unlink(path)
    check(engine.loadCustomWords(path) == 0, "文件不在了：清空")
    type(c, "nihao")
    check(client.page?.texts.first == "你好", "清空后 nihao 又是你好", "\(client.page?.texts ?? [])")
}

do {
    // 换引擎（换词库）：打到一半的清掉，接着用新引擎打
    let otherPath = ownLexicon ? writeTestLexicon() : lexicon
    guard let other = Engine(lexicon: otherPath) else {
        check(false, "载入第二个引擎")
        exit(1)
    }
    if ownLexicon {
        unlink(otherPath)
        unlink(otherPath + ".wcache")
    }
    let (c, client) = fresh()
    type(c, "ni")
    c.setEngine(other)
    check(!c.isComposing && client.marked.isEmpty && client.committed.isEmpty && c.currentEngine === other,
          "换引擎时清掉编辑区", client.committed)
    type(c, "nihao")
    _ = c.handle(.char(" "))
    check(client.committed == "你好", "换了引擎照常打字", client.committed)
}

// MARK: v + 空格的工具栏、表情面板

do {
    // 默认值、快捷键的键名（和 fcitx5 一样）
    let d = WowtypeConfig()
    check(d.toolbar && !d.clipboardHistory && d.emojiKey == .emojiDefault && d.emojiKey?.name == "Control+period",
          "默认工具栏开、剪贴板历史关、表情面板快捷键 Control+period", d.emojiKey?.name ?? "nil")
    check(WowtypeConfig.parse("EmojiKey=Super+period").emojiKey == .emojiDefault,
          "Linux 的默认值 Super+period 拷过来是 Control+.")
    check(WowtypeConfig.parse("EmojiKey=").emojiKey == nil, "EmojiKey 留空：不用快捷键")
    check(WowtypeConfig.parse("EmojiKey=Hyper+F12").emojiKey == .emojiDefault, "认不出的快捷键保持默认")
    let e = WowtypeConfig.parse("Toolbar=False\nClipboardHistory=True\nEmojiKey=Control+Shift+E")
    check(!e.toolbar && e.clipboardHistory, "Toolbar、ClipboardHistory")
    check(e.emojiKey?.matches(.char("E", [.control, .shift])) == true, "Control+Shift+E：按下时 macOS 给大写也认")
    check(e.emojiKey?.name == "Control+Shift+E" && Shortcut(name: "Control+Shift+e")?.name == "Control+Shift+E"
          && Shortcut(name: "Control+e")?.name == "Control+e", "按着 Shift 的字母写回时是大写（和 fcitx5、设置里的预设一样）")
    check(e.emojiKey?.matches(.char("e", [.control])) == false, "少了 Shift 不算")
    check(Shortcut(name: "Alt+semicolon")?.matches(.char(";", [.option])) == true, "Alt 是 Option，键名 semicolon")
    check(Shortcut(name: "Control+.")?.matches(.char(".", [.control, .caps])) == true, "键名可以是字符本身，CapsLock 不算")
    check(Shortcut.emojiDefault.matches(.char(".", [.control, .command])) == false, "多按了 Command 不算")
}

withConfig({ _ in }) { c, client in
    type(c, "v")
    check(c.handle(.char(" ")) && c.openPanel == .menu, "v + 空格打开工具栏")
    check(client.marked.isEmpty && client.committed.isEmpty && !c.isComposing, "打开工具栏时 v 不上屏、编辑区清掉",
          client.committed)
    check(client.page?.texts == ["剪贴板", "常用语", "符号", "表情"] && client.page?.vertical == true
              && client.page?.cursor == 0 && client.page?.expanded == false,
          "工具栏竖排四项", "\(client.page?.texts ?? [])")
    check(client.page?.aux == "工具栏：数字键选择，Esc 关闭", "工具栏的提示", client.page?.aux ?? "nil")
    check(c.handle(.char("a")) && c.openPanel == .menu && client.committed.isEmpty, "别的键吃掉，不打进应用")
    _ = c.shiftChanged(down: true, otherModifiers: false, now: 1.0)
    check(!c.shiftChanged(down: false, otherModifiers: false, now: 1.1) && c.mode == .chinese, "工具栏开着时单按 Shift 不切")
    _ = c.handle(.key(Keysym.down))
    check(client.page?.cursor == 1, "下键移光标", "\(client.page?.cursor ?? -1)")
    _ = c.handle(.key(Keysym.backspace))
    check(c.openPanel == nil && client.page == nil, "菜单里退格关上")

    type(c, "v")
    _ = c.handle(.char(" "))
    _ = c.handle(.char("2"))
    check(c.openPanel == .phrases, "2 进常用语")
    check(client.page?.texts.isEmpty == true && client.page?.aux == "常用语：还没有，在设置的「自定义词」里添加",
          "没有自定义词时只有提示", client.page?.aux ?? "nil")
    _ = c.handle(.key(Keysym.backspace))
    check(c.openPanel == .menu, "退格返回菜单")
    c.select(1)
    check(c.openPanel == .phrases, "点第 2 项也进常用语")
    _ = c.handle(.key(Keysym.escape))
    check(c.openPanel == nil && client.page == nil && client.committed.isEmpty, "Esc 关上")

    type(c, "v")
    _ = c.handle(.char(" "))
    check(!c.handle(.char("c", [.control])) && c.openPanel == nil && client.page == nil, "Control+C 收起工具栏、交给应用")
    type(c, "v")
    _ = c.handle(.char(" "))
    c.commitComposition()
    check(c.openPanel == nil && client.page == nil && client.committed.isEmpty, "切走输入法时收起工具栏，不上屏")
    type(c, "vim")
    _ = c.handle(.char(" "))
    check(c.openPanel == nil, "vim 照常打字")
}

withConfig({ $0.toolbar = false }) { c, _ in
    type(c, "v")
    _ = c.handle(.char(" "))
    check(c.openPanel == nil, "关掉工具栏：v + 空格不打开")
}

withConfig({ $0.shuangpin = true }) { c, _ in
    type(c, "v")
    _ = c.handle(.char(" "))
    check(c.openPanel == nil, "双拼时不开工具栏")
}

do {
    // 常用语：custom.tsv 的顺序，「编码　词」，选了上屏（\n 是换行）
    let path = "/tmp/wowtype-macos-harness-\(getpid()).phrases.tsv"
    writeFile(path, "dz\t北京市海淀区\nqm\t张三\\n13800000000\n")
    engine.loadCustomWords(path)
    let (c, client) = fresh()
    type(c, "v")
    _ = c.handle(.char(" "))
    _ = c.handle(.char("2"))
    let texts = client.page?.texts ?? []
    check(texts.count == 2 && texts[0] == "dz\u{3000}北京市海淀区" && texts[1].hasPrefix("qm\u{3000}张三"),
          "常用语按文件顺序，编码在前", "\(texts)")
    check(client.page?.aux == "常用语：选一条上屏，退格返回", "常用语的提示", client.page?.aux ?? "nil")
    _ = c.handle(.key(Keysym.down))
    _ = c.handle(.char(" "))
    check(client.committed == "张三\n13800000000" && c.openPanel == nil && client.page == nil, "空格上屏光标处的，收起",
          client.committed)
    unlink(path)
    engine.loadCustomWords(path)
}

withConfig({ $0.clipboardHistory = true }) { c, client in
    ClipboardHistory.remember("第一条")
    // 外壳看到的系统剪贴板（打开剪贴板页时取一次）
    c.sampleClipboard = { ClipboardHistory.remember("第二条\n第二行") }
    type(c, "v")
    _ = c.handle(.char(" "))
    _ = c.handle(.char("1"))
    check(c.openPanel == .clipboard && client.page?.texts == ["第二条⏎第二行", "第一条"],
          "剪贴板：打开时取一次，最新的在前，换行显示成 ⏎", "\(client.page?.texts ?? [])")
    _ = c.handle(.char("1"))
    check(client.committed == "第二条\n第二行" && c.openPanel == nil, "数字选一条上屏", client.committed)
    c.sampleClipboard = nil
    for i in 1...12 {
        ClipboardHistory.remember("条目\(i)")
    }
    client.committed = ""
    type(c, "v")
    _ = c.handle(.char(" "))
    _ = c.handle(.char("1"))
    check(client.page?.texts.count == 9 && client.page?.hasNext == true && client.page?.hasPrev == false,
          "一页 9 条", "\(client.page?.texts.count ?? 0)")
    _ = c.handle(.char("="))
    check(client.page?.texts.first == "条目3" && client.page?.hasPrev == true && client.page?.cursor == 0,
          "= 翻到下一页", "\(client.page?.texts ?? [])")
    _ = c.handle(.char("2"))
    check(client.committed == "条目2", "数字选这一页的第几个", client.committed)
    var off = c.config
    off.clipboardHistory = false
    c.apply(off)
    check(ClipboardHistory.items.isEmpty, "关掉剪贴板历史时马上清空")
}

withConfig({ _ in }) { c, client in
    ClipboardHistory.remember("不该列出来")
    var sampled = false
    c.sampleClipboard = { sampled = true }
    type(c, "v")
    _ = c.handle(.char(" "))
    _ = c.handle(.char("1"))
    check(!sampled && client.page?.texts.isEmpty == true
              && client.page?.aux == "剪贴板：没打开，在设置里打开「记录剪贴板历史」",
          "剪贴板历史默认关：不取、不列", client.page?.aux ?? "nil")
    _ = c.handle(.char(" "))
    check(c.openPanel == nil && client.committed.isEmpty, "空列表按空格关上")
    ClipboardHistory.clear()
}

withConfig({ _ in }) { c, client in
    let recent = RecentEmoji()
    c.recentEmoji = recent
    type(c, "v")
    _ = c.handle(.char(" "))
    _ = c.handle(.char("3"))
    check(c.openPanel == .emoji(symbols: true) && client.page?.expanded == true && (client.page?.texts.count ?? 0) > 6,
          "3 进符号面板（6 列网格）", "\(client.page?.texts.count ?? 0)")
    check(client.page?.aux == "符号：打拼音或英文搜索，Esc 关闭", "符号面板的提示", client.page?.aux ?? "nil")
    let first = client.page?.texts.first ?? "?"
    _ = c.handle(.char(" "))
    check(client.committed == first && recent.items.isEmpty, "空格上屏符号，不记进最近用过", client.committed)
    type(c, "v")
    _ = c.handle(.char(" "))
    _ = c.handle(.char("4"))
    check(c.openPanel == .emoji(symbols: false), "4 进表情面板")
}

withConfig({ _ in }) { c, client in
    let path = "/tmp/wowtype-macos-harness-\(getpid()).emoji-recent.txt"
    unlink(path)
    let recent = RecentEmoji(path: path)
    c.recentEmoji = recent
    check(c.handle(.char(".", [.control])) && c.openPanel == .emoji(symbols: false), "Control+. 打开表情面板")
    check(client.page?.expanded == true && client.page?.texts.count == 36 && client.page?.hasNext == true
              && client.page?.aux == "表情：打拼音或英文搜索，Esc 关闭",
          "不搜索时列全部 emoji，一屏 6 × 6", "\(client.page?.texts.count ?? 0) \(client.page?.aux ?? "nil")")
    type(c, "pizza")
    check(client.marked == "pizza" && client.page?.texts.first == "🍕" && client.page?.aux == "表情：pizza",
          "打英文搜：pizza → 🍕，搜索词在编辑区", "\(client.page?.texts.prefix(6) ?? [])")
    _ = c.handle(.key(Keysym.backspace))
    check(client.marked == "pizz" && c.openPanel != nil, "退格删搜索词", client.marked)
    type(c, "A")
    _ = c.handle(.key(Keysym.returnKey))
    check(client.committed == "🍕" && c.openPanel == nil && client.page == nil && client.marked.isEmpty,
          "回车上屏，面板收起", client.committed)
    check(recent.items == ["🍕"] && readFile(path) == "🍕\n", "记进最近用过，写到文件", "\(recent.items)")
    check(RecentEmoji(path: path).items == ["🍕"], "下次启动从文件读回来")

    _ = c.handle(.char(".", [.control]))
    check(client.page?.texts.first == "🍕", "最近用过的排最前", "\(client.page?.texts.prefix(6) ?? [])")
    _ = c.handle(.key(Keysym.right))
    _ = c.handle(.key(Keysym.down))
    check(client.page?.cursor == 7, "右键、下键在网格里走", "\(client.page?.cursor ?? -1)")
    _ = c.handle(.key(Keysym.up))
    _ = c.handle(.key(Keysym.up))
    check(client.page?.cursor == 1 && c.openPanel != nil, "第一行再往上不收起", "\(client.page?.cursor ?? -1)")
    _ = c.handle(.key(Keysym.pageDown))
    check(client.page?.cursor == 1 && client.page?.hasPrev == true, "PgDn 翻一屏", "\(client.page?.cursor ?? -1)")
    _ = c.handle(.key(Keysym.pageUp))
    let row = client.page?.texts ?? []
    _ = c.handle(.char("3"))
    check(row.count > 2 && client.committed == "🍕" + row[2], "数字选光标所在行的第几个", client.committed)
    check(recent.items.count == 2 && recent.items.last == "🍕", "新用的排最前", "\(recent.items)")

    client.committed = ""
    _ = c.handle(.char(".", [.control]))
    type(c, "zzqqxx")
    check(client.page?.texts.isEmpty == true && client.page?.aux == "表情：没找到「zzqqxx」", "搜不到", client.page?.aux ?? "nil")
    _ = c.handle(.char(".", [.control]))
    check(c.openPanel == nil && client.page == nil && client.marked.isEmpty && client.committed.isEmpty,
          "再按一次快捷键关上")

    type(c, "pizza")
    _ = c.handle(.char(".", [.control]))
    check(client.marked == "pizza" && client.page?.texts.first == "🍕" && !c.isComposing,
          "打到一半按快捷键：拿打的字母搜", client.marked)
    _ = c.handle(.key(Keysym.escape))
    check(c.openPanel == nil && client.committed.isEmpty && client.marked.isEmpty, "Esc 关上，不上屏")

    type(c, "nihaoshi")
    if let i = client.page?.texts.firstIndex(of: "你好"), i < 9 {
        _ = c.handle(.char(Character("\(i + 1)")))
        check(c.isComposing, "选了句首的词", client.marked)
        _ = c.handle(.char(".", [.control]))
        check(client.committed == "你好shi" && c.openPanel != nil && client.marked.isEmpty,
              "选了词以后按快捷键：打的先上屏，搜索词空着", client.committed)
        _ = c.handle(.key(Keysym.escape))
    } else {
        check(false, "nihaoshi 的候选里有你好", "\(client.page?.texts ?? [])")
    }
    unlink(path)
}

withConfig({ _ in }) { c, client in
    c.recentEmoji = RecentEmoji()
    c.toggleMode()
    check(c.handle(.char(".", [.control])) && c.openPanel != nil, "英文模式也能开表情面板")
    type(c, "pizza")
    _ = c.handle(.char(" "))
    check(client.committed == "🍕", "英文模式里搜索上屏", client.committed)
    check(!c.handle(.char("a")), "收起以后英文模式照常交给应用")
    c.toggleMode()
    _ = c.handle(.char(".", [.control]))
    check(!c.handle(.char("v", [.command])) && c.openPanel == nil, "Command+V 收起表情面板、交给应用")
}

withConfig({ $0.arrowKeys = .caret }) { c, client in
    // #129：左右键移动拼音里的光标，字母插在光标处（会话做，外壳把光标位置交给应用）；上下键选词
    type(c, "nihao")
    let end = client.markedCursor
    for _ in 0..<3 { _ = c.handle(.key(Keysym.left)) }
    check(client.markedCursor < end && client.marked.prefix(client.markedCursor) == "ni",
          "左键把光标移到 ni 后面", "\(client.marked) \(client.markedCursor)")
    type(c, "x")
    check(String(client.marked.filter { $0 != " " && $0 != "'" }) == "nixhao",
          "字母插在光标处", client.marked)
    _ = c.handle(.key(Keysym.backspace))
    check(String(client.marked.filter { $0 != " " && $0 != "'" }) == "nihao", "退格删光标前一个", client.marked)
    _ = c.handle(.key(Keysym.end))
    check(c.handle(.key(Keysym.right)) && client.page?.cursor == 0, "末尾的右键吃掉，不挑候选")
    _ = c.handle(.key(Keysym.down))
    check(client.page?.cursor == 1 && client.page?.expanded == false, "下键选下一个，不展开面板")
}

withConfig({ _ in }) { c, client in
    type(c, "nihao")
    _ = c.handle(.key(Keysym.left))
    check(client.markedCursor == client.marked.utf16.count, "默认（都用来选词）光标一直在末尾", "\(client.markedCursor)")
}

withConfig({ $0.emojiKey = nil }) { c, _ in
    check(!c.handle(.char(".", [.control])) && c.openPanel == nil, "不用快捷键：Control+. 交给应用")
}

withConfig({ $0.emojiKey = Shortcut(name: "Control+semicolon") }) { c, _ in
    check(!c.handle(.char(".", [.control])) && c.handle(.char(";", [.control])) && c.openPanel != nil,
          "快捷键换成 Control+;")
}

do {
    // 打字推荐的 emoji（kaixin → 开心、😊）选了也记进最近用过
    let (c, client) = fresh()
    let recent = RecentEmoji()
    c.recentEmoji = recent
    type(c, "kaixin")
    let texts = client.page?.texts ?? []
    if let i = texts.firstIndex(where: { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation } }), i < 9 {
        _ = c.handle(.char(Character("\(i + 1)")))
        check(recent.items.count == 1 && client.committed.hasSuffix(recent.items[0]),
              "选打字推荐的 emoji 记进最近用过", "\(client.committed) \(recent.items)")
    } else {
        check(false, "kaixin 推荐 emoji", "\(texts)")
    }
}

withConfig({ $0.horizontal = false }) { c, client in
    type(c, "shi")
    check(client.page?.vertical == true, "设置竖排时候选框竖着画")
}

// MARK: 互译

/// 假的翻译器：译文由测试一步步给（running → done / error），和核心一样同一句话不重复请求。
final class FakeTranslator: TranslationBackend {
    var isReady = true
    var started: [String] = []
    var cancels = 0
    var snapshot = TranslateSnapshot(phase: .idle)

    func start(_ text: String) {
        if snapshot.source == text && (snapshot.phase == .running || snapshot.phase == .done) {
            return
        }
        started.append(text)
        snapshot = TranslateSnapshot(phase: .running, source: text)
    }

    func cancel() {
        cancels += 1
        snapshot = TranslateSnapshot(phase: .idle)
    }

    func poll() -> TranslateSnapshot { snapshot }

    func tag(for text: String) -> String { "中→英" }

    func stream(_ text: String) { snapshot.text = text }

    func finish(_ text: String) {
        snapshot.text = text
        snapshot.phase = .done
    }

    func fail(_ error: String) {
        snapshot.phase = .error
        snapshot.error = error
    }
}

final class FakeClock {
    var now = 100.0
}

final class Counter {
    var count = 0
}

struct TranslateRig {
    let c: Composer
    let client: FakeClient
    let t: FakeTranslator
    let clock: FakeClock
    /// onTranslatePoll 叫了几次（外壳这时开始定时 poll）
    let pollRequests: Counter

    /// 过了 seconds 秒，外壳的定时器 poll 一次。
    @discardableResult
    func tick(_ seconds: Double = 0.05) -> Bool {
        clock.now += seconds
        return c.pollTranslation()
    }

    var status: String { client.page?.translate?.status ?? "" }
    var source: String { client.page?.translate?.source ?? "" }
}

/// 打开互译、切到「译」的输入框。
func translateRig(_ change: (inout WowtypeConfig) -> Void = { _ in }) -> TranslateRig {
    var config = WowtypeConfig()
    config.translate = true
    change(&config)
    let (c, client) = fresh()
    let t = FakeTranslator()
    let clock = FakeClock()
    let requests = Counter()
    c.clock = { clock.now }
    c.onTranslatePoll = { requests.count += 1 }
    c.setTranslator(t)
    c.apply(config)
    c.switchMode(to: .translate)
    return TranslateRig(c: c, client: client, t: t, clock: clock, pollRequests: requests)
}

do {
    // 设置：键名、默认值和 Linux 一样
    let d = WowtypeConfig()
    check(!d.translate && d.translateTarget == "en" && d.translateBaseUrl.isEmpty && d.translateModel.isEmpty
          && !d.translateFormal && d.translateLocal && d.translateLocalModel.isEmpty
          && d.translateLlamaServer.isEmpty && d.translateIdleMinutes == 5,
          "互译默认关、译成英文、默认用本地模型")
    // 0.3.10 及以前的文件没有 TranslateLocal：填了翻译接口的接着用接口（三端一样，见 spec/config.json）
    let old = "Translate=True\nTranslateBaseUrl=https://api.deepseek.com/v1\nTranslateModel=deepseek-chat\n"
    check(!WowtypeConfig.parse(old).translateLocal, "旧文件填了接口、没写 TranslateLocal：用接口")
    check(WowtypeConfig.parse("Translate=True\nTranslateBaseUrl=\n").translateLocal, "没填接口：用本地模型")
    check(WowtypeConfig.parse(old + "TranslateLocal=True\n").translateLocal, "写了 TranslateLocal 就照写的")
    check(WowtypeConfig.parse(old).serialized(into: old) == old, "旧文件读进来没改：一个字都不动")
    var keepLocal = WowtypeConfig.parse("Translate=True\n")
    keepLocal.translateBaseUrl = "https://api.example.com/v1"
    let keepLocalText = keepLocal.serialized(into: "Translate=True\n")
    check(keepLocalText.contains("\nTranslateLocal=True\n") && WowtypeConfig.parse(keepLocalText).translateLocal,
          "填了接口又要用本地模型：TranslateLocal=True 要写进文件，不然读回来成了 False", keepLocalText)
    var useService = WowtypeConfig.parse(old)
    useService.translateBaseUrl = ""
    let useServiceText = useService.serialized(into: old)
    check(useServiceText.contains("\nTranslateLocal=False\n") && !WowtypeConfig.parse(useServiceText).translateLocal,
          "清空接口但还选着服务：TranslateLocal=False 要写进文件", useServiceText)
    let c = WowtypeConfig.parse("""
    Translate=True
    TranslateTarget=ja
    TranslateBaseUrl=https://api.example.com/v1
    TranslateModel="gpt-4o-mini"
    TranslateFormal=True
    TranslateLocal=True
    TranslateLocalModel=~/models/hy.gguf
    TranslateLlamaServer=/opt/homebrew/bin/llama-server
    TranslateIdleMinutes=999
    """)
    check(c.translate && c.translateTarget == "ja" && c.translateBaseUrl == "https://api.example.com/v1"
          && c.translateModel == "gpt-4o-mini" && c.translateFormal, "互译的各项", "\(c.translateTarget) \(c.translateModel)")
    check(c.translateLocal && c.translateLocalModel == "~/models/hy.gguf"
          && c.translateLlamaServer == "/opt/homebrew/bin/llama-server" && c.translateIdleMinutes == 240,
          "本地模型的各项；闲置分钟数超出 0–240 取 240", "\(c.translateIdleMinutes)")
    check(WowtypeConfig.parse("TranslateTarget=klingon").translateTarget == "en", "不认识的语言保持 en")
    check(WowtypeConfig.template().contains("TranslateBaseUrl=") && !WowtypeConfig.template().contains("TranslateKey="),
          "设置模板里有互译的项，没有 Key")
}

do {
    // Shift：中 → 英 → 译 → 中；没打开互译、翻译器没配好时只在中英之间切
    let r = translateRig()
    r.c.switchMode(to: .chinese)
    r.c.toggleMode()
    check(r.c.mode == .english, "中 → 英")
    r.c.toggleMode()
    check(r.c.mode == .translate && r.c.translating, "英 → 译")
    r.c.toggleMode()
    check(r.c.mode == .chinese, "译 → 中")
    _ = r.c.shiftChanged(down: true, otherModifiers: false, now: 1.0)
    _ = r.c.shiftChanged(down: false, otherModifiers: false, now: 1.1)
    _ = r.c.shiftChanged(down: true, otherModifiers: false, now: 2.0)
    check(r.c.shiftChanged(down: false, otherModifiers: false, now: 2.1) && r.c.mode == .translate, "单按两次 Shift 到译")

    r.t.isReady = false
    r.c.toggleMode()
    r.c.toggleMode()
    r.c.toggleMode()
    check(r.c.mode == .chinese, "翻译器没配好：英 → 中，切不到译", "\(r.c.mode)")

    let off = translateRig { $0.translate = false }
    check(off.c.mode == .chinese && !off.c.translateAvailable, "设置里没打开互译：切不到译")
    off.c.toggleMode()
    off.c.toggleMode()
    check(off.c.mode == .chinese, "没打开互译：英 → 中")

    let (plain, _) = fresh()
    plain.switchMode(to: .translate)
    check(plain.mode == .chinese, "没有翻译器切不到译")
}

do {
    // 另设的切换键（#143），和 Linux 一样
    check(WowtypeConfig().toggleKey == nil, "默认不用另设的切换键")
    check(WowtypeConfig.parse("ToggleKey=Control+space").toggleKey?.name == "Control+space", "读出切换键")
    check(WowtypeConfig.parse("ToggleKey=Hyper+F12").toggleKey == nil, "认不出的键保持不用")

    let r = translateRig { $0.toggleKey = Shortcut(name: "Control+space") }
    check(r.c.handle(.char(" ", [.control])) && r.c.mode == .chinese, "在「译」里按切换键回中文")
    check(r.c.handle(.char(" ", [.control])) && r.c.mode == .english, "切换键：中 → 英")
    check(r.c.handle(.char(" ", [.control])) && r.c.mode == .chinese, "切换键：英 → 中")
}

withConfig({ $0.toggleKey = Shortcut(name: "Control+space") }) { c, client in
    type(c, "nihao")
    check(c.handle(.char(" ", [.control])) && c.mode == .english && client.committed == "nihao",
          "打到一半按切换键：打的字母原样上屏、切到英文", client.committed)
}

withConfig({ _ in }) { c, _ in
    check(!c.handle(.char(" ", [.control])) && c.mode == .chinese, "没设切换键：Control+空格交给应用")
}

withConfig({ $0.shiftToggle = .off; $0.toggleKey = Shortcut(name: "Control+space") }) { c, _ in
    // #87 的用法：Shift 没用、关掉，靠另设的键切换。换设置时不该被拉回中文
    check(c.handle(.char(" ", [.control])) && c.mode == .english, "关了 Shift 也能用切换键切到英文")
    var again = WowtypeConfig()
    again.shiftToggle = .off
    again.toggleKey = Shortcut(name: "Control+space")
    c.apply(again)
    check(c.mode == .english, "有切换键时换设置不拉回中文")
    again.toggleKey = nil
    c.apply(again)
    check(c.mode == .chinese, "关了 Shift、也没切换键：拉回中文（不然切不回来）")
}

do {
    // 打的字攒成原文，不上屏；停 0.5 秒才发请求，译文边出边写在编辑区，回车上屏译文
    let r = translateRig()
    type(r.c, "nihao")
    check(r.client.marked.isEmpty && r.source == "ni'hao", "译：拼音在候选框顶上，编辑区留给译文",
          "\(r.client.marked) / \(r.source)")
    check(r.client.page?.translate?.title == "中→英 互译：" && r.client.page?.texts.first == "你好",
          "候选框顶上是方向，下面照常是候选", "\(r.client.page?.translate?.title ?? "")")
    _ = r.c.handle(.char(" "))
    check(r.client.committed.isEmpty && r.c.translateSource == "你好" && r.source == "你好",
          "选的词进原文，不上屏", "\(r.client.committed) / \(r.c.translateSource)")
    check(r.pollRequests.count == 1 && r.status == "翻译中…", "原文变了叫外壳开始轮询",
          "\(r.pollRequests.count) \(r.status)")
    check(r.tick(0.2) && r.t.started.isEmpty, "0.5 秒内不发请求")
    check(r.tick(0.35) && r.t.started == ["你好"], "停够 0.5 秒发请求", "\(r.t.started)")
    r.t.stream("Hel")
    r.tick()
    check(r.client.marked == "Hel" && r.client.markedCursor == 3, "译文边出边写在编辑区", r.client.marked)
    r.t.finish("Hello")
    check(!r.tick(), "译完了就不用再轮询")
    check(r.client.marked == "Hello" && r.status == "回车上屏 · Shift+回车上屏原文 · Esc 清空",
          "译完提示怎么上屏", "\(r.client.marked) / \(r.status)")
    check(r.c.handle(.key(Keysym.returnKey)), "回车吃掉")
    check(r.client.committed == "Hello" && r.c.translateSource.isEmpty && r.client.marked.isEmpty && r.client.page == nil,
          "回车上屏译文，清空原文和候选框", r.client.committed)
    check(!r.c.handle(.key(Keysym.returnKey)), "原文空了回车交给应用")
}

do {
    // 句末标点立刻发；还没译完按回车（空格也一样）等译好了自动上屏
    let r = translateRig()
    type(r.c, "nihao")
    _ = r.c.handle(.char("."))
    check(r.c.translateSource == "你好。" && r.client.committed.isEmpty, "标点也进原文", r.c.translateSource)
    r.tick(0.01)
    check(r.t.started == ["你好。"], "句末标点不等 0.5 秒", "\(r.t.started)")
    _ = r.c.handle(.char(" "))
    check(r.client.committed.isEmpty && r.status == "翻译中…好了就上屏", "没译完按空格先等着", r.status)
    check(r.tick(), "等着时接着轮询")
    r.t.finish("Hello.")
    check(!r.tick() && r.client.committed == "Hello." && r.c.translateSource.isEmpty, "译好了自动上屏", r.client.committed)
}

do {
    // Shift+回车上屏原文；Esc 清空；退格删原文最后一个字、重新等 0.5 秒
    let r = translateRig()
    type(r.c, "nihao")
    _ = r.c.handle(.char(" "))
    _ = r.c.handle(.key(Keysym.returnKey, .shift))
    check(r.client.committed == "你好" && r.c.translateSource.isEmpty, "Shift+回车上屏原文", r.client.committed)

    type(r.c, "nihao")
    _ = r.c.handle(.char(" "))
    r.tick(0.6)
    let cancels = r.t.cancels
    check(r.c.handle(.key(Keysym.escape)) && r.c.translateSource.isEmpty && r.client.page == nil
          && r.client.committed == "你好", "Esc 清空原文，不上屏", r.client.committed)
    check(r.t.cancels == cancels + 1, "Esc 取消请求")

    type(r.c, "nihao")
    _ = r.c.handle(.char(" "))
    type(r.c, "hao")
    _ = r.c.handle(.char(" "))
    r.tick(0.6)
    r.t.finish("Hello good")
    r.tick()
    check(r.c.handle(.key(Keysym.backspace)) && r.c.translateSource == "你好", "退格删原文最后一个字", r.c.translateSource)
    check(r.client.marked == "Hello good" && r.status == "翻译中…", "原文改了、新译文出来前留着上一句",
          "\(r.client.marked) / \(r.status)")
    r.tick(0.6)
    check(r.t.started.last == "你好", "停一下重新翻", "\(r.t.started)")
    r.t.stream("Hel")
    r.tick()
    check(r.client.marked == "Hello good", "新译文比上一句短时先不换", r.client.marked)
    r.t.finish("Hello")
    r.tick()
    check(r.client.marked == "Hello", "译完了换成新的", r.client.marked)
}

do {
    // 数字和 / + 进原文（3.14 的点原样）；方向键、Tab 吃掉；快捷键交给应用
    let r = translateRig()
    for ch in "3.14/2" {
        check(r.c.handle(.char(ch)), "\(ch) 进原文")
    }
    check(r.c.translateSource == "3.14/2" && r.client.committed.isEmpty, "数字、点、斜杠进原文", r.c.translateSource)
    check(r.c.handle(.key(Keysym.left)) && r.c.handle(.key(Keysym.tab)), "方向键、Tab 吃掉（原文里没有光标）")
    check(!r.c.handle(.char("c", .command)) && r.c.translateSource == "3.14/2", "Command+C 交给应用")
    check(r.c.hasPendingText && !r.c.isComposing, "攒着原文时外壳也要吃掉别的键")
}

do {
    // 出错：候选框底下写原因，回车重试
    let r = translateRig()
    type(r.c, "nihao")
    _ = r.c.handle(.char(" "))
    r.tick(0.6)
    r.t.fail("翻译失败：连不上服务器")
    check(!r.tick() && r.status == "翻译失败：连不上服务器（回车重试）" && r.client.marked.isEmpty,
          "出错写在底下", r.status)
    _ = r.c.handle(.key(Keysym.returnKey))
    check(r.t.started == ["你好", "你好"] && r.status == "翻译中…好了就上屏", "回车重试", "\(r.t.started) \(r.status)")
    r.t.fail("翻译失败：连不上服务器")
    check(!r.tick() && r.client.committed.isEmpty && r.status.hasSuffix("（回车重试）"), "又出错就不等了", r.status)
}

do {
    // 离开「译」：攒着的原文原样上屏，正在打的拼音留着接着打
    let r = translateRig()
    type(r.c, "nihao")
    _ = r.c.handle(.char(" "))
    type(r.c, "hao")
    r.c.toggleMode()
    check(r.c.mode == .chinese && r.client.committed == "你好" && r.c.isComposing && r.client.marked == "hao",
          "单按 Shift 回到中文：原文上屏，拼音留着", "\(r.client.committed) / \(r.client.marked)")
    check(r.client.page?.translate == nil, "回到中文后候选框没有互译那两行")

    // 切走输入法 / 换输入框：拼音原样进原文，原文再上屏
    let s = translateRig()
    type(s.c, "nihao")
    _ = s.c.handle(.char(" "))
    type(s.c, "hao")
    s.c.commitComposition()
    check(s.client.committed == "你好hao" && !s.c.hasPendingText && s.client.page == nil, "切走时原文原样上屏",
          s.client.committed)

    // 设置里关掉互译：离开「译」
    let u = translateRig()
    type(u.c, "nihao")
    _ = u.c.handle(.char(" "))
    var config = u.c.config
    config.translate = false
    u.c.apply(config)
    check(u.c.mode == .chinese && u.client.committed == "你好" && u.c.translateSource.isEmpty,
          "关掉互译时原文上屏、回到中文", u.client.committed)

    // 失去焦点：拼音和原文都丢掉
    let v = translateRig()
    type(v.c, "nihao")
    _ = v.c.handle(.char(" "))
    v.c.cancel()
    check(v.client.committed.isEmpty && !v.c.hasPendingText, "cancel 丢掉原文")
}

do {
    // 密码框（安全输入）里照常打中文，不往外发
    let r = translateRig()
    r.client.allowsTranslation = false
    type(r.c, "nihao")
    _ = r.c.handle(.char(" "))
    check(r.client.committed == "你好" && r.c.translateSource.isEmpty && r.t.started.isEmpty && !r.c.translating,
          "不能翻译的输入框直接上屏", r.client.committed)
}

do {
    // 两个输入框共用一个翻译器：清空自己的原文不取消别人的请求
    let r = translateRig()
    let (other, _) = fresh()
    var config = WowtypeConfig()
    config.translate = true
    other.setTranslator(r.t)
    other.apply(config)
    other.switchMode(to: .translate)
    type(r.c, "nihao")
    _ = r.c.handle(.char(" "))
    r.tick(0.6)
    other.cancel()
    // 每个会话只取消自己发的请求（会话记着发过没有）
    check(r.t.cancels == 0, "别的输入框清空不取消这个的请求", "\(r.t.cancels)")
}

/// 文件的权限位。
func fileMode(_ path: String) -> Int {
    var info = stat()
    return stat(path, &info) == 0 ? Int(info.st_mode) & 0o777 : -1
}

do {
    // API Key 文件：0600，一行；空串删掉；手动建的权限太宽时收紧
    let path = "/tmp/wowtype-macos-harness-\(getpid()).key"
    check(TranslateKeyFile.write("  sk-test-123 \n", to: path), "写 Key")
    check(TranslateKeyFile.read(path) == "sk-test-123" && fileMode(path) == 0o600, "Key 文件 0600，去掉空白",
          "\(fileMode(path))")
    check(TranslateKeyFile.write("", to: path) && access(path, F_OK) != 0, "空串删掉 Key 文件")
    check(TranslateKeyFile.read(path).isEmpty, "没有 Key 文件读出空串")
    writeFile(path, "sk-loose\n")
    chmod(path, 0o644)
    TranslateKeyFile.tighten(path)
    check(fileMode(path) == 0o600 && TranslateKeyFile.read(path) == "sk-loose", "权限太宽的收紧", "\(fileMode(path))")
    unlink(path)
}

do {
    // 核心的翻译器：没填服务时没配好；本地模型看模型文件在不在
    let t = Translator()
    var config = WowtypeConfig()
    config.translate = true
    config.translateLocal = false
    t.configure(config, keyFile: "", defaultLocalModel: "")
    check(!t.isReady, "没填服务、没选本地模型：没配好")
    config.translateBaseUrl = "http://127.0.0.1:1/v1"
    config.translateModel = "m"
    t.configure(config, keyFile: "", defaultLocalModel: "")
    check(t.isReady, "填了地址和模型：配好了")
    config.translateLocal = true
    let model = "/tmp/wowtype-macos-harness-\(getpid()).gguf"
    t.configure(config, keyFile: "", defaultLocalModel: model)
    check(!t.isReady, "本地模型文件不在：没配好")
    writeFile(model, "GGUF")
    t.configure(config, keyFile: "", defaultLocalModel: model)
    check(t.isReady && !t.localRunning, "TranslateLocalModel 留空用默认路径（第一次翻译时才起 llama-server）")
    config.translateLocalModel = model
    t.configure(config, keyFile: "", defaultLocalModel: "/nonexistent.gguf")
    check(t.isReady, "写了模型路径用它")
    unlink(model)
    check(t.tag(for: "你好") == "中→英" && t.tag(for: "hello") == "英→中", "方向标签", t.tag(for: "hello"))
}

/// 本机的假翻译服务（OpenAI 格式，流式）。不起线程：测试循环里每次 service() 接一个连接、
/// 读完请求、一次把 SSE 回完。
final class FakeTranslateServer {
    private let fd: Int32
    let port: UInt16
    var requests: [String] = []
    var status = "200 OK"
    var chunks: [String] = []

    init?() {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        #if !canImport(Glibc)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &size) == 0
            }
        }
        guard ok else {
            close(fd)
            return nil
        }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    deinit {
        close(fd)
    }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    static func sse(_ delta: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"content\":\"\(delta)\"}}]}\n\n"
    }

    func service() {
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { return }
        defer { close(conn) }
        // macOS 上接进来的连接继承了非阻塞，改回阻塞，最多等 5 秒
        _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(conn, &buffer, buffer.count, 0)
            if n <= 0 { break }
            bytes.append(contentsOf: buffer[0..<n])
            // 请求头完了（空行）、请求体也够 Content-Length 了就不读了
            guard let headEnd = (0..<max(bytes.count - 3, 0)).first(where: { bytes[$0..<$0 + 4] == [13, 10, 13, 10] })
            else { continue }
            let head = String(decoding: bytes[..<headEnd], as: UTF8.self)
            let length = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int(String($0.split(separator: ":")[1]).trimmingWhitespace()) } ?? 0
            if bytes.count - (headEnd + 4) >= length { break }
        }
        requests.append(String(decoding: bytes, as: UTF8.self))
        let type = status.hasPrefix("200") ? "text/event-stream" : "application/json"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nConnection: close\r\n\r\n" + chunks.joined()
        let out = Array(response.utf8)
        _ = out.withUnsafeBytes { send(conn, $0.baseAddress, $0.count, 0) }
    }
}

func haveCurl() -> Bool {
    let path = getenv("PATH").map { String(cString: $0) } ?? "/usr/bin:/bin"
    return path.split(separator: ":").contains { access("\($0)/curl", X_OK) == 0 }
}

/// 一直轮询（外壳的定时器）直到 done 返回 true，最多 15 秒。
func waitTranslation(_ c: Composer, _ server: FakeTranslateServer, until done: () -> Bool) -> Bool {
    let deadline = monotonicSeconds() + 15
    while monotonicSeconds() < deadline {
        server.service()
        c.pollTranslation()
        if done() { return true }
        usleep(20_000)
    }
    return false
}

if !haveCurl() {
    print("skip 互译走真的翻译器（没有 curl）")
} else if let server = FakeTranslateServer() {
    // 走核心的翻译器（curl）连本机的假服务：Key、模型、语言照设置发，译文流式写进编辑区
    signal(SIGPIPE, SIG_IGN)
    let keyPath = "/tmp/wowtype-macos-harness-\(getpid()).translate.key"
    TranslateKeyFile.write("sk-test-123", to: keyPath)
    var config = WowtypeConfig()
    config.translate = true
    config.translateLocal = false
    config.translateBaseUrl = server.baseURL
    config.translateModel = "test-model"
    config.translateTarget = "ja"
    let translator = Translator()
    translator.configure(config, keyFile: keyPath, defaultLocalModel: "")
    let (c, client) = fresh()
    c.setTranslator(translator)
    c.apply(config)
    c.switchMode(to: .translate)
    check(c.mode == .translate, "真的翻译器：切到译")
    server.chunks = [FakeTranslateServer.sse("また"), FakeTranslateServer.sse("明日"), "data: [DONE]\n\n"]
    type(c, "nihao")
    _ = c.handle(.char(" "))
    _ = c.handle(.char("."))
    check(client.page?.translate?.title == "中→日 互译：", "方向标签照设置的语言", client.page?.translate?.title ?? "")
    let done = waitTranslation(c, server) { client.page?.translate?.status.hasPrefix("回车上屏") == true }
    check(done && client.marked == "また明日", "流式译文写进编辑区",
          "\(client.marked) / \(client.page?.translate?.status ?? "")")
    let request = server.requests.first ?? ""
    check(request.hasPrefix("POST /v1/chat/completions") && request.contains("Authorization: Bearer sk-test-123"),
          "请求带 Key", String(request.prefix(200)))
    check(request.contains("\"model\":\"test-model\"") && request.contains("Japanese") && request.contains("你好。"),
          "请求里有模型、目标语言、原文")
    _ = c.handle(.key(Keysym.returnKey))
    check(client.committed == "また明日" && !c.hasPendingText, "回车上屏译文", client.committed)

    // 服务出错：底下写原因
    server.status = "401 Unauthorized"
    server.chunks = ["{\"error\":{\"message\":\"bad key\"}}"]
    type(c, "hao")
    _ = c.handle(.char(" "))
    _ = c.handle(.char("."))
    let failed = waitTranslation(c, server) { client.page?.translate?.status.hasSuffix("（回车重试）") == true }
    check(failed && client.page?.translate?.status.contains("bad key") == true, "服务出错写原因",
          client.page?.translate?.status ?? "")
    check(server.requests.count == 2, "连了两次假服务", "\(server.requests.count)")
    unlink(keyPath)
} else {
    check(false, "起假翻译服务")
}

// MARK: 本地翻译模型（和 Linux 设置的 download_model / install_llama_server 一样）

do {
    let arm = LocalModel.llamaAsset(machine: "arm64", os: (14, 0))
    check(arm?.name == "llama-b12110-bin-macos-arm64.tar.gz" && arm?.size == 16_650_691
          && arm?.url == "https://github.com/ggml-org/llama.cpp/releases/download/b12110/llama-b12110-bin-macos-arm64.tar.gz",
          "Apple 芯片用 arm64 的官方包", "\(String(describing: arm))")
    let intel = LocalModel.llamaAsset(machine: "x86_64", os: (13, 3))
    check(intel?.name == "llama-b12110-bin-macos-x64.tar.gz" && intel?.size == 12_388_601, "Intel Mac 用 x64 的包",
          "\(String(describing: intel))")
    check([arm, intel].allSatisfy { $0?.sha256.count == 64 && $0?.sha256 == $0?.sha256.lowercased() }, "钉了 SHA256")
    check(LocalModel.llamaAsset(machine: "arm64", os: (13, 2)) == nil && LocalModel.llamaAsset(machine: "x86_64", os: (12, 7)) == nil,
          "macOS 13.3 以下没有能下载的 llama-server")
    check(LocalModel.llamaAsset(machine: "ppc", os: (26, 0)) == nil, "不认识的 CPU 没有")
    check(LocalModel.size == 1_133_080_512 && LocalModel.sha256.count == 64 && LocalModel.url.hasSuffix("/" + LocalModel.fileName),
          "模型钉了大小和 SHA256")
    // 和 Linux 设置钉的是同一个模型、同一个 llama.cpp 构建（规格目录旁边就是 settings/）
    let specDir = getenv("WOWTYPE_SPEC_DIR").map { String(cString: $0) } ?? "spec"
    if let linux = readFile(specDir + "/../settings/wowtype-config") {
        check(linux.contains("\"\(LocalModel.sha256)\"") && linux.contains("LOCAL_MODEL_SIZE = \(LocalModel.size)")
              && linux.contains("LOCAL_MODEL_FILE = \"\(LocalModel.fileName)\"")
              && linux.contains("LLAMA_BUILD = \"\(LocalModel.llamaBuild)\""),
              "模型的 SHA256、大小和 llama.cpp 构建号和 Linux 的 wowtype-config 一样")
    } else {
        print("skip 对照 Linux 的模型校验值（没找到 settings/wowtype-config）")
    }

    // 缺什么下什么
    let all = LocalModel.plan(modelExists: false, serverFound: false, customServer: false, asset: arm)
    check(all.wantModel && all.wantLlama && !all.ready && all.bytes == LocalModel.size + 16_650_691, "都没有：两样一起下",
          "\(all)")
    let model = LocalModel.plan(modelExists: false, serverFound: true, customServer: false, asset: arm)
    check(model.wantModel && !model.wantLlama && model.bytes == LocalModel.size, "有 llama-server（Homebrew）只下模型", "\(model)")
    let llama = LocalModel.plan(modelExists: true, serverFound: false, customServer: false, asset: arm)
    check(!llama.wantModel && llama.wantLlama && llama.bytes == 16_650_691 && llama.canDownload, "只差 llama-server", "\(llama)")
    check(LocalModel.plan(modelExists: true, serverFound: true, customServer: false, asset: nil).ready, "都有了：已就绪")
    let old = LocalModel.plan(modelExists: true, serverFound: false, customServer: false, asset: nil)
    check(old.llamaUnavailable && !old.canDownload && !old.ready, "系统太旧：下载不了 llama-server", "\(old)")
    let custom = LocalModel.plan(modelExists: false, serverFound: false, customServer: true, asset: arm)
    check(custom.wantModel && !custom.wantLlama && custom.llamaUnavailable && custom.bytes == LocalModel.size,
          "自己写了 llama-server 的位置：不替它下载", "\(custom)")

    // 和 Linux 设置的 human_size 一样：f"{n / 1e9:.2f} GB" if n >= 1e9 else f"{n / 1e6:.0f} MB"
    check(LocalModel.sizeText(LocalModel.size + 16_650_691) == "1.15 GB", "大小写成 1.15 GB（和 Linux 一样）",
          LocalModel.sizeText(LocalModel.size + 16_650_691))
    check(LocalModel.sizeText(16_650_691) == "17 MB" && LocalModel.sizeText(1_950_000_000) == "1.95 GB"
          && LocalModel.sizeText(2_004_000_000) == "2.00 GB" && LocalModel.sizeText(1_133_080_512) == "1.13 GB",
          "MB 取整、GB 留两位小数（和 Linux 一样）")
    check(LocalModel.percent(42, of: 100) == 42 && LocalModel.percent(5, of: 0) == 0 && LocalModel.percent(300, of: 200) == 100,
          "百分比")

    // 续传：带 Range 请求后看服务回什么
    check(LocalModel.resume(status: 206, have: 100, contentRange: "bytes 100-199/200") == .append, "206：接着写")
    check(LocalModel.resume(status: 206, have: 100, contentRange: "bytes 0-199/200") == .fail(status: 206),
          "206 但不是从 .part 末尾开始：不接")
    check(LocalModel.resume(status: 200, have: 100) == .restart && LocalModel.resume(status: 200, have: 0) == .restart,
          "200：服务不支持续传，从头下")
    check(LocalModel.resume(status: 416, have: 100) == .complete, "416：.part 已经完整，只差校验")
    check(LocalModel.resume(status: 416, have: 0) == .fail(status: 416) && LocalModel.resume(status: 404, have: 0) == .fail(status: 404),
          "别的状态码算出错")

    // 官方包里只要 llama-server 和动态库，不往外写
    check(LocalModel.llamaEntry("llama-b12110/llama-server") == "llama-server"
          && LocalModel.llamaEntry("./llama-b12110/libggml-metal.0.29.0.dylib") == "libggml-metal.0.29.0.dylib"
          && LocalModel.llamaEntry("llama-b12110/libllama.dylib") == "libllama.dylib", "要 llama-server 和 lib*.dylib")
    check(["llama-b12110/llama-cli", "llama-b12110/LICENSE", "llama-b12110/", "llama-server", "../llama-server",
           "/llama-server", "llama-b12110/sub/libx.dylib", "-x/llama-server", "../libx.dylib"]
          .allSatisfy { LocalModel.llamaEntry($0) == nil }, "别的程序、子目录、带 .. 的不要")
    check(LocalModel.safeLinkTarget("libllama.0.9.0.dylib"), "链接指向同目录的文件")
    check(!LocalModel.safeLinkTarget("../evil.dylib") && !LocalModel.safeLinkTarget("/usr/lib/libz.dylib")
          && !LocalModel.safeLinkTarget("..") && !LocalModel.safeLinkTarget(""), "链接不许指到别处")
}

// MARK: 语音键

do {
    let d = WowtypeConfig()
    check(d.voice && d.voiceKey == "Alt_R" && !d.voiceCopy, "语音默认开、右 Option、不复制")
    let option = VoiceKey(name: "Alt_R")
    check(option?.keyCode == 0x3D && option?.isModifier == true, "Alt_R 是右 Option")
    // 右 Option 按着时 modifierFlags 带 NX_DEVICERALTKEYMASK（0x40），左 Option 是 0x20
    check(option?.isDown(rawFlags: 0x80000 | 0x40) == true && option?.isDown(rawFlags: 0x80000 | 0x20) == false,
          "分得清左右 Option")
    check(VoiceKey(name: "F8")?.keyCode == 0x64 && VoiceKey(name: "F8")?.isModifier == false, "F8 不是修饰键")
    check(VoiceKey(name: "Menu") == nil && VoiceKey(name: "") == nil && VoiceKey(name: "none") == nil,
          "Mac 上没有的键、留空：不用语音键")
    let c = WowtypeConfig.parse("Voice=False\nVoiceKey=F9\nVoiceCopy=True")
    check(!c.voice && c.voiceKey == "F9" && c.voiceCopy, "读语音设置")
    check(voiceWave([]) == "▁▁▁▁▁▁" && voiceWave([100, 0]) == "▁▁▁▁█▁"
          && voiceWave([0, 10, 20, 30, 40, 50, 60]).count == 6, "音量画成 6 个竖条（和 Linux 一样）")
}

// MARK: 万象词库包（规矩和 Linux 设置的 install_lexicon_pack 一样）

do {
    check(LexiconPack.assetVersion("wowtype-data-wanxiang-2026.11.12.0.tar.gz") == "2026.11.12.0", "认出万象包和版本")
    check(LexiconPack.assetVersion("wowtype-data-wanxiang-latest.tar.gz") == nil
          && LexiconPack.assetVersion("wowtype-data-wanxiang-1.0.zip") == nil
          && LexiconPack.assetVersion("wowtype-data-rime-ice-2026.10.31.2.tar.gz") == nil
          && LexiconPack.assetVersion("wowtype-data-wanxiang-1.0/../x.tar.gz") == nil, "别的文件不认")
    let pick = LexiconPack.pickAsset(["SHA256SUMS", "wowtype-data-wanxiang-2026.9.1.tar.gz",
                                      "wowtype-data-wanxiang-2026.10.31.2.tar.gz", "wowtype-data-wanxiang-2026.10.31.tar.gz"])
    check(pick?.version == "2026.10.31.2", "好几个包取版本最大的", "\(String(describing: pick))")
    check(LexiconPack.pickAsset(["SHA256SUMS", "wowtype_0.3.10_debian13_amd64.deb"]) == nil, "没有万象包")
    check(LexiconPack.compareVersions("2026.10.31.2", "2026.10.31") > 0 && LexiconPack.compareVersions("2026.9.1", "2026.10.1") < 0
          && LexiconPack.compareVersions("1.0", "1") > 0, "版本按数字段比（和 Linux 一样，段多的大）")

    let name = "wowtype-data-wanxiang-1.tar.gz"
    let digest = String(repeating: "ab", count: 32)
    if case .success(let sums) = LexiconPack.checksums("\(digest.uppercased())  \(name)\nffff  other\n", wanted: [name]) {
        check(sums[name] == digest, "SHA256SUMS 取到校验值（转小写）")
    } else {
        check(false, "SHA256SUMS 取到校验值（转小写）")
    }
    if case .success(let sums) = LexiconPack.checksums("\(digest) *\(name)\r\n", wanted: [name]) {
        check(sums[name] == digest, "二进制模式的 * 和 CRLF")
    } else {
        check(false, "二进制模式的 * 和 CRLF")
    }
    for (text, what) in [("\(digest)  \(name)\n\(digest)  \(name)\n", "重复"), ("bad  \(name)\n", "无效"),
                         ("\(digest)  other.tar.gz\n", "缺失")] {
        if case .failure = LexiconPack.checksums(text, wanted: [name]) {
            check(true, "SHA256SUMS 的条目\(what)：不装")
        } else {
            check(false, "SHA256SUMS 的条目\(what)：不装")
        }
    }

    check(LexiconPack.entryName("./lexicon.tsv") == "lexicon.tsv" && LexiconPack.entryName("VERSION") == "VERSION"
          && LexiconPack.entryName("./") == "" && LexiconPack.entryName(".") == "", "包里认的条目")
    check(LexiconPack.entryName("../lexicon.tsv") == nil && LexiconPack.entryName("/etc/passwd") == nil
          && LexiconPack.entryName("dicts/lexicon.tsv") == nil && LexiconPack.entryName("evil.sh") == nil, "别的条目不认")

    let dir = "/tmp/wowtype-macos-harness-\(getpid())-pack"
    mkdir(dir, 0o755)
    let lexicon = dir + "/lexicon.tsv"
    writeFile(lexicon, "# 注释\n\nni hao\t你好\t100\nzhong guo\t中国\n")
    check({ if case .success(2) = LexiconPack.checkLexicon(at: lexicon, minimum: 2) { return true }; return false }(),
          "lexicon.tsv 数条数（注释、空行不算）")
    check({ if case .failure = LexiconPack.checkLexicon(at: lexicon, minimum: 3) { return true }; return false }(),
          "条数太少不装")
    writeFile(lexicon, "ni hao 你好\n")
    check({ if case .failure = LexiconPack.checkLexicon(at: lexicon, minimum: 1) { return true }; return false }(),
          "没有 TAB 的不装")
    check({ if case .failure = LexiconPack.checkLexicon(at: dir + "/none.tsv", minimum: 1) { return true }; return false }(),
          "没有 lexicon.tsv 不装")
    check(LexiconPack.installedVersion(folder: dir) == "?", "没有 VERSION 是 ?")
    writeFile(dir + "/VERSION", "2026.11.12.0\n")
    check(LexiconPack.installedVersion(folder: dir) == "2026.11.12.0", "读 VERSION")
    unlink(lexicon)
    check(LexiconPack.installedVersion(folder: dir) == nil, "没有 lexicon.tsv 算没装")
    unlink(dir + "/VERSION")
    rmdir(dir)
}

// MARK: 设置契约（spec/config.json、spec/lexicon-pack.json；Linux 两端在 scripts/test-config-contract.py 对照）

checkConfigContract()
checkLexiconPackContract()

if getenv("WOWTYPE_EXPECT_FULL_CHARS") != nil {
    // 真实词库（补了雾凇大字表）：一个音节的字要列全，yi 有八百多个
    let (c, _) = fresh()
    type(c, "yi")
    let count = c.allCandidates().count
    check(count > 300, "yi 的字列全（超过 300 个）", "\(count)")
}

if failures > 0 {
    print("macOS HARNESS FAILED (\(failures))")
    exit(1)
}
print("macOS harness ok")
