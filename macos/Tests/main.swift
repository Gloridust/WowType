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
                 "shishi\t事实\t8000", "lve\t略\t30000"]
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
    // 数字交给了应用，光标前是数字：后面的符号原样（20:22、3,000）
    client.committed = "20"
    _ = c.handle(.char(":"))
    client.committed += "22"
    _ = c.handle(.char(","))
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
    check(commits == ["你好", "，"], "上屏回调", "\(commits)")
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
    ShuangpinScheme=xiaohe
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
    check(c.shuangpin && c.shuangpinScheme == "Xiaohe", "双拼方案不分大小写", c.shuangpinScheme)
    check(c.shiftToggle == .right && c.halfwidthPunct && c.selectKeys == .semicolonQuote, "枚举值")
    check(c.pageKeys == 2, "翻页键", "\(c.pageKeys)")
    check(c.autoSpaceFlags == 1, "自动空格只加字母", "\(c.autoSpaceFlags)")
    check(c.lexicon == "~/dicts/my lexicon.tsv" && c.candidateFontSize == 20, "带引号的值、字号", c.lexicon)
    check(!c.traditional, "认不出的值保持默认")
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
    _ = c.handle(.char(","))
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
