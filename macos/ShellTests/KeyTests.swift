// 按键：每一组新开一个输入框（新的输入控制器 + 假输入框），设置写进临时的 wowtype.conf。

import AppKit
import Carbon

func runKeyTests() {
    do {
        let (c, f) = session()
        type(c, "nihao")
        check(f.markedText == "ni'hao", "nihao 编辑区分音节", f.markedText)
        check(f.caretInMarked == 6, "光标在编辑区末尾", "\(String(describing: f.caretInMarked))")
        check(f.markedAttributes[.underlineStyle] != nil, "编辑区带 IMK 的下划线", "\(f.markedAttributes)")
        check(texts.first == "你好", "候选框第一个是你好", "\(texts)")
        check(f.lineRectRequests > 0, "画候选框前问了输入框光标在哪")
        // 假输入框说光标这一行在 (200, 600)，高 18：候选框在它下面 4 点，第一个序号对着编辑区第一个字母
        let window = NSApp.windows.first { $0.contentView is CandidateView }
        check(window?.frame.maxY == 596 && window?.frame.minX == 200 - CandidateLayout.inset.width - CandidateLayout.cellPadding.width
              && window?.isVisible == false,
              "候选框摆在光标这一行下面（没上屏）", "\(String(describing: window?.frame))")
        press(c, .space)
        check(f.text == "你好" && f.inserted == ["你好"], "空格上屏你好", "\(f.inserted) \(f.text)")
        check(f.markedText.isEmpty && panel == nil, "上屏后编辑区、候选框都收起")
    }

    do {
        let (c, f) = session()
        type(c, "jintiantianqizhenbucuo")
        check(texts.first == "今天天气真不错", "长句整句第一个", "\(texts.prefix(3))")
        press(c, .space)
        check(f.text == "今天天气真不错", "长句空格上屏", f.text)
    }

    do {
        let (c, f) = session()
        type(c, "shi")
        let page = texts
        check(page.count == 9, "shi 一页 9 个", "\(page)")
        press(c, .char("3"))
        check(page.count > 2 && f.text == page[2], "数字 3 选第三个", "\(f.text) \(page)")
    }

    do {
        let (c, _) = session()
        type(c, "shi")
        let first = texts
        check(panel?.hasNext == true && panel?.hasPrev == false, "第一页：能往后翻、不能往前")
        press(c, .char("="))
        let second = texts
        check(!second.isEmpty && second != first && panel?.hasPrev == true, "= 翻到第二页", "\(second)")
        press(c, .char("-"))
        check(texts == first, "- 翻回第一页", "\(texts)")
        press(c, .pageDown)
        check(texts == second, "PageDown 翻页", "\(texts)")
        press(c, .pageUp)
        check(texts == first, "PageUp 翻回", "\(texts)")
    }

    do {
        let (c, f) = session()
        type(c, "nihao")
        let handled = press(c, .escape)
        check(handled && f.text.isEmpty && f.inserted.isEmpty && panel == nil, "Esc 清空不上屏", "\(f.inserted) \(f.text)")
        check(!press(c, .escape), "没在打字时 Esc 交给应用")
    }

    do {
        let (c, f) = session()
        type(c, "nihao")
        press(c, .backspace)
        check(f.markedText == "ni'ha", "退格删一个字母", f.markedText)
        for _ in 0..<5 { press(c, .backspace) }
        check(f.markedText.isEmpty && panel == nil && f.text.isEmpty, "退格删光了收起", "「\(f.text)」")
        check(!press(c, .backspace), "没在打字时退格交给应用")
    }

    // 单按 Shift：中 → 英 → 中，光标下面亮一下「英」「中」，一会儿收起
    do {
        let (c, f) = session()
        tapShift(c)
        check(panel?.aux == "英" && texts.isEmpty, "切到英文：光标下面提示「英」", "\(String(describing: panel?.aux))")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: WowTypeInputController.modeHintDuration + 0.2))
        check(panel == nil, "提示过一会儿收起")
        type(c, "abc")
        check(f.text == "abc" && f.inserted.isEmpty, "英文模式字母交给应用", "\(f.text) \(f.inserted)")
        tapShift(c)
        check(panel?.aux == "中", "回到中文：提示「中」", "\(String(describing: panel?.aux))")
        type(c, "nihao")
        check(f.markedText == "ni'hao", "再按 Shift 回到中文", f.markedText)
        check(texts.first == "你好" && panel?.aux == nil, "接着打字：候选框换成候选，不再是提示")
        tapShift(c)
        check(f.text == "abcnihao" && f.markedText.isEmpty, "打到一半按 Shift：字母原样上屏", "\(f.text) 「\(f.markedText)」")
        tapShift(c, right: true)
        type(c, "ni")
        check(f.markedText == "ni", "右 Shift 也能切回中文", f.markedText)
    }

    // #253：双击 Shift（JetBrains 的到处搜索）不切中英文；Shift 的事件都交给应用。
    // 没在打字时第一下就切了（#310），第二下切回来：提示最后是「中」，不会停在「英」
    do {
        let (c, f) = session()
        // 候选框是共用的：上一段打的拼音的候选还开着，先收起来
        state.candidatePanel.hide()
        check(doubleTapShift(c), "双击 Shift：按下、松开都交给应用")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        check(panel?.aux != "英", "双击 Shift 提示不停在「英」",
              "\(String(describing: panel?.aux)) \(texts)")
        type(c, "ni")
        check(f.markedText == "ni", "双击 Shift 不切，还是中文", f.markedText)
        // 单按以后紧接着打字（不等）：先切英文，字母交给应用，弹「英」
        press(c, .escape)
        tapShift(c, wait: false)
        type(c, "a")
        check(f.text.hasSuffix("a") && f.markedText.isEmpty && panel?.aux == "英",
              "单按以后接着打字：先切英文，a 交给应用", "\(f.text) \(String(describing: panel?.aux))")
        tapShift(c)
        type(c, "ni")
        check(f.markedText == "ni", "单按回中文", f.markedText)
    }

    do {
        let (c, f) = session(["ShiftToggle": "Left"])
        tapShift(c, right: true)
        type(c, "ni")
        check(f.markedText == "ni", "ShiftToggle=Left：右 Shift 不切", f.markedText)
    }

    // 另设的切换键
    do {
        let (c, f) = session(["ToggleKey": "Control+space"])
        check(press(c, .control(" ")), "Control+空格吃掉")
        check(panel?.aux == "英", "Control+空格切到英文也提示「英」", "\(String(describing: panel?.aux))")
        type(c, "ab")
        check(f.text == "ab" && f.markedText.isEmpty, "Control+空格切到英文", f.text)
        press(c, .control(" "))
        type(c, "ni")
        check(f.markedText == "ni", "再按回到中文", f.markedText)
    }

    // Chromium / Electron 的应用会多报、重报 flagsChanged：一次单按只切一次
    do {
        let (c, f) = session()
        let t = ProcessInfo.processInfo.systemUptime + 10
        for event in [shiftEvent(down: true, at: t), shiftEvent(down: true, at: t),
                      shiftEvent(down: false, at: t + 0.1), shiftEvent(down: false, at: t + 0.1)] {
            _ = c.handle(event, client: c.fake)
        }
        type(c, "ab")
        check(f.text == "ab", "按下、松开各报两遍：切到英文一次", f.text)
        // 切完以后又把原来的按下、松开重发一遍（时刻还是原来的）：不算
        _ = c.handle(shiftEvent(down: true, at: t), client: c.fake)
        _ = c.handle(shiftEvent(down: false, at: t + 0.1), client: c.fake)
        // 刚松开 20 毫秒又来一遍按下松开：回弹，不算
        _ = c.handle(shiftEvent(down: true, at: t + 0.12), client: c.fake)
        _ = c.handle(shiftEvent(down: false, at: t + 0.15), client: c.fake)
        type(c, "c")
        check(f.text == "abc", "重发的、回弹的都不算：还在英文", f.text)
        // 人再按一下照常切
        _ = c.handle(shiftEvent(down: true, at: t + 1), client: c.fake)
        _ = c.handle(shiftEvent(down: false, at: t + 1.1), client: c.fake)
        type(c, "ni")
        check(f.markedText == "ni", "过一会儿再按：回到中文", f.markedText)
    }
    do {
        // 按着 Shift 时来了别的键码的 flagsChanged：不带 Control / Option / Command 的不管，带的不算单按
        func modifier(_ code: Int, _ extra: NSEvent.ModifierFlags, at t: TimeInterval) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                             modifierFlags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x102 | extra.rawValue),
                             timestamp: t, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: UInt16(code))!
        }
        let (c, f) = session()
        let t = ProcessInfo.processInfo.systemUptime + 20
        _ = c.handle(shiftEvent(down: true, at: t), client: c.fake)
        _ = c.handle(modifier(kVK_Function, [], at: t + 0.02), client: c.fake)
        _ = c.handle(shiftEvent(down: false, at: t + 0.1), client: c.fake)
        type(c, "ab")
        check(f.text == "ab", "中间多报一个不带 Control / Option / Command 的修饰键事件：照样切", f.text)
        _ = c.handle(shiftEvent(down: true, at: t + 1), client: c.fake)
        _ = c.handle(modifier(kVK_Command, .command, at: t + 1.02), client: c.fake)
        _ = c.handle(shiftEvent(down: false, at: t + 1.1), client: c.fake)
        type(c, "c")
        check(f.text == "abc", "按着 Shift 按了 Command：不算单按", f.text)
    }

    // 进出「译」的快捷键（真的 keyDown：Control+Shift+Y）
    do {
        let translate = ["Translate": "True", "TranslateLocal": "False", "TranslateBaseUrl": "http://127.0.0.1:9/v1",
                         "TranslateModel": "shelltest", "TranslateModeKey": "Control+Shift+Y"]
        let (c, f) = session(translate)
        tapShift(c)
        tapShift(c)
        type(c, "ni")
        check(f.markedText == "ni", "设了互译键：单按 Shift 两下是中 → 英 → 中，不进「译」", f.markedText)
        press(c, .escape)
        check(press(c, .controlShift("Y")), "Control+Shift+Y 吃掉")
        check(panel?.aux?.hasPrefix("译") == true, "互译键进「译」：提示「译 …」", "\(String(describing: panel?.aux))")
        check(press(c, .controlShift("Y")) && panel?.aux == "中", "再按回中文：提示「中」", "\(String(describing: panel?.aux))")
        tapShift(c)
        press(c, .controlShift("Y"))
        check(press(c, .controlShift("Y")) && panel?.aux == "英", "英文里进「译」再按：回到英文", "\(String(describing: panel?.aux))")
        // 在「译」里单按 Shift：回中文
        press(c, .controlShift("Y"))
        tapShift(c)
        type(c, "ni")
        check(f.markedText == "ni", "在「译」里单按 Shift 回中文", f.markedText)
    }
    do {
        // 没开互译：互译键交给应用
        let (c, f) = session(["TranslateModeKey": "Control+Shift+Y"])
        check(!press(c, .controlShift("Y")) && panel == nil, "没开互译：Control+Shift+Y 交给应用")
        type(c, "ni")
        check(f.markedText == "ni", "还在中文", f.markedText)
    }
    do {
        // 关了 Shift、只设了互译键：怎么按都不会卡在英文
        let (c, f) = session(["ShiftToggle": "Off", "Translate": "True", "TranslateLocal": "False",
                              "TranslateBaseUrl": "http://127.0.0.1:9/v1", "TranslateModel": "shelltest",
                              "TranslateModeKey": "Control+Shift+Y"])
        tapShift(c)
        press(c, .controlShift("Y"))
        press(c, .controlShift("Y"))
        type(c, "ni")
        check(f.markedText == "ni", "关了 Shift、只有互译键：在中和译之间，回得到中文", f.markedText)
    }
    do {
        // 预设的切换键 Control+Shift+空格（真的 keyDown）
        let (c, f) = session(["ToggleKey": "Control+Shift+space"])
        check(press(c, .controlShift(" ")) && panel?.aux == "英", "Control+Shift+空格切到英文", "\(String(describing: panel?.aux))")
        type(c, "ab")
        check(f.text == "ab", "英文里字母交给应用", f.text)
    }

    // 方向键 = 移光标
    do {
        let (c, f) = session(["ArrowKeys": "Caret"])
        type(c, "nihao")
        press(c, .left)
        check(f.markedText == "ni'hao" && f.caretInMarked == 5, "← 光标左移一个字母（输入框里的光标跟着动）",
              "「\(f.markedText)」 光标 \(String(describing: f.caretInMarked))")
        press(c, .left)
        press(c, .left)
        let caret = f.caretInMarked
        // ni|hao：光标在隔音符哪一边都行（核心给的是 ' 前面）
        check(caret == 2 || caret == 3, "再按两下 ← 到 hao 前面", "光标 \(String(describing: caret)) 「\(f.markedText)」")
        press(c, .down)
        check(current == 1, "↓ 移高亮", "\(String(describing: current))")
        press(c, .up)
        check(current == 0, "↑ 移回", "\(String(describing: current))")
        press(c, .right)
        press(c, .right)
        press(c, .right)
        check(f.caretInMarked == 6, "→ 回到末尾", "\(String(describing: f.caretInMarked))")
    }
    do {
        let (c, f) = session(["ArrowKeys": "Caret"])
        type(c, "nhao")
        for _ in 0..<3 { press(c, .left) }
        type(c, "i")
        check(f.markedText == "ni'hao", "光标处插字母 n|hao + i → ni'hao", f.markedText)
        check(texts.first == "你好", "插进去以后照常出你好", "\(texts.prefix(3))")
        press(c, .space)
        check(f.text == "你好", "空格上屏", f.text)
    }

    // 默认：左右键选词，不绕回
    do {
        let (c, f) = session()
        type(c, "shi")
        check(current == 0, "开始高亮第一个")
        press(c, .right)
        check(current == 1, "→ 选下一个", "\(String(describing: current))")
        press(c, .left)
        press(c, .left)
        check(current == 0, "← 到头不绕到最后", "\(String(describing: current))")
        check(f.caretInMarked == 3, "默认模式 ← 不动编辑区的光标", "\(String(describing: f.caretInMarked))")
        press(c, .down)
        check(panel?.cells.count ?? 0 > 9 && panel?.row != nil, "↓ 展开更多候选（网格）", "\(panel?.cells.count ?? 0)")
        check(panel?.cells.allSatisfy(\.leading) == true, "展开面板的词靠左摆（同一列对齐）")
    }
    do {
        let (c, _) = session()
        type(c, "lve")
        for _ in 0..<50 where panel?.hasNext == true { press(c, .pageDown) }
        let last = texts
        check(panel?.hasNext == false && last.count > 1, "lve 翻到最后一页", "\(last)")
        for _ in 0..<last.count { press(c, .right) }
        check(texts == last && current == last.count - 1, "→ 到最后一个不绕回开头", "\(texts) \(String(describing: current))")
    }

    // 竖排
    do {
        let (c, _) = session(["CandidateLayout": "Vertical"])
        type(c, "shi")
        let cells = panel?.cells ?? []
        check(cells.count == 9 && cells.allSatisfy(\.leading), "竖排一行一个、靠左", "\(cells.count)")
        check(zip(cells, cells.dropFirst()).allSatisfy { $0.frame.minX == $1.frame.minX && $0.frame.maxY < $1.frame.minY },
              "竖排各行左边对齐、从上往下")
        press(c, .down)
        check(current == 1, "竖排 ↓ 移高亮", "\(String(describing: current))")
        let first = texts
        press(c, .right)
        check(texts != first, "竖排 → 翻页", "\(texts)")
    }

    wubiTests()
    shuangpinTests()

    // 繁体
    do {
        let (c, f) = session(["Traditional": "True"])
        type(c, "toufa")
        check(texts.first == "頭髮", "繁体 toufa → 頭髮", "\(texts.prefix(3))")
        press(c, .escape)
        type(c, "weilejiejue")
        check(texts.first == "爲了解決", "繁体 weilejiejue → 爲了解決（OpenCC 的爲；不是瞭解）", "\(texts.prefix(3))")
        press(c, .space)
        check(f.committed == "爲了解決", "繁体上屏", f.committed)
    }

    // 模糊音
    do {
        let (c, _) = session(["Fuzzy": "True", "FuzzyEngOng": "True"])
        type(c, "zheng")
        check(texts.contains("中"), "模糊音 eng=ong：zheng 第一页有中", "\(texts.prefix(5))")
    }
    do {
        let (c, _) = session()
        type(c, "zheng")
        check(!texts.contains("中"), "没开模糊音时 zheng 这一页没有中", "\(texts)")
    }

    // #229：候选上点右键，学过的词出菜单「忘掉这个词」（⌃⌫），点了和 Control+Delete 一样忘掉、重画
    do {
        let (c, f) = session()
        type(c, "ma")
        let word = texts.count > 2 ? texts[2] : ""
        for _ in 0..<3 {
            press(c, .escape)
            type(c, "ma")
            if let at = texts.firstIndex(of: word) {
                press(c, .char(Character(String(at + 1))))
            }
        }
        press(c, .escape)
        type(c, "ma")
        let at = texts.firstIndex(of: word)
        let menu = at.flatMap { state.candidatePanel.forgetMenu(forCandidate: $0) }
        let item = menu?.items.first
        check(menu?.items.count == 1 && item?.title == "忘掉这个词" && item?.keyEquivalent == "\u{8}"
              && item?.keyEquivalentModifierMask == .control,
              "选过的 \(word) 右键有「忘掉这个词」（⌃⌫）", "\(String(describing: menu?.items))")
        let unlearned = texts.indices.first { state.candidatePanel.forgetMenu(forCandidate: $0) == nil }
        check(unlearned != nil, "没学过的词右键不出菜单", "\(texts)")
        let cursor = current
        let marked = f.markedText
        let inserted = f.inserted.count
        if let item, let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
        check(f.inserted.count == inserted && f.markedText == marked && current == cursor,
              "点了「忘掉这个词」：编辑区、光标不动", "\(f.markedText) \(String(describing: current))")
        let again = texts.firstIndex(of: word)
        check(again.map { state.candidatePanel.forgetMenu(forCandidate: $0) == nil } ?? true,
              "忘掉以后 \(word) 右键不再出菜单", "\(texts)")
        press(c, .escape)
    }

    commitCompositionTests()
    contextTests()
    panelDrawingTests()
    autoPairTests()
}

/// 中文标点自动配对（AutoPairPunct）：真的输入控制器靠按位置换字（insertText 带 replacementRange）
/// 把光标挪到两个中间、跳过补好的右半边、空的一对退格两个一起删。
private func autoPairTests() {
    let on = ["AutoPairPunct": "True", "EmojiSuggest": "False"]
    func shown(_ f: FakeTextInput) -> String {
        let t = f.text as NSString
        let at = min(f.selected.location, t.length)
        return t.substring(to: at) + "|" + t.substring(from: at)
    }
    do {
        // 空格交给应用：输入框里有字了，光标旁边读得到
        let (c, f) = session(on)
        type(c, " (")
        check(shown(f) == " （|）", "配对：( 上屏（），光标在中间", shown(f))
        type(c, "3)")
        check(shown(f) == " （3）|", "配对：( 3 ) 是（3），) 跳过补好的右括号", shown(f))
    }
    do {
        let (c, f) = session(on)
        type(c, " (nihao)")
        check(shown(f) == " （你好）|", "配对：打拼音途中按 ) 先上屏再跳过", shown(f))
    }
    do {
        let (c, f) = session(on)
        type(c, " (")
        check(press(c, .backspace) && shown(f) == " |", "配对：空的一对退格两个一起删", shown(f))
    }
    do {
        // 读不到光标旁边的字的应用（终端这类）：不配对
        let (c, f) = session(on, reliable: false)
        type(c, " (")
        check(shown(f) == " （|", "配对：应用说不清光标旁边是什么时不配对", shown(f))
    }
    do {
        // 空的输入框里第一个字：光标旁边没有字可读，先不配对
        let (c, f) = session(on)
        type(c, "(")
        check(shown(f) == "（|", "配对：空的输入框里第一个 ( 不配对", shown(f))
    }
    do {
        let (c, f) = session()
        type(c, " (")
        check(shown(f) == " （|", "默认不配对", shown(f))
    }
}

/// 候选框排的格子都在框里；CandidateView 真画出来（浅色、深色），高亮的绿色在格子上。
private func panelDrawingTests() {
    let cases: [(String, [String: String], String)] = [
        ("横排", [:], "shi"), ("竖排", ["CandidateLayout": "Vertical"], "shi"),
        ("五笔编码提示", ["InputScheme": "Wubi86", "WubiHint": "True"], "g"),
        ("五笔空码", ["InputScheme": "Wubi86"], "abb"),
    ]
    for (name, values, keys) in cases {
        let (c, _) = session(values)
        type(c, keys)
        guard let layout = panel else {
            check(false, "\(name)：有候选框")
            continue
        }
        let bounds = NSRect(origin: .zero, size: layout.size)
        let inside = layout.cells.allSatisfy { bounds.insetBy(dx: CandidateLayout.inset.width - 0.5,
                                                              dy: CandidateLayout.inset.height - 0.5).contains($0.frame) }
            && (layout.auxFrame.map { bounds.contains($0) } ?? true)
        check(inside, "\(name)：候选、提示都在框里", "\(layout.size) \(layout.cells.map(\.frame))")
        for (appearance, green) in [(NSAppearance.Name.aqua, CandidateTheme.light.highlight),
                                    (.darkAqua, CandidateTheme.dark.highlight)] {
            let view = CandidateView(frame: bounds)
            view.appearance = NSAppearance(named: appearance)
            view.layout = layout
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
                check(false, "\(name)：画得出来")
                continue
            }
            view.cacheDisplay(in: bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / bounds.width
            let highlighted = layout.cells.first(where: \.current)
            let sample = highlighted.map { NSPoint(x: $0.frame.minX + 3, y: $0.frame.midY) }
            let pixel = sample.flatMap { rep.colorAt(x: Int($0.x * scale), y: Int($0.y * scale)) }?
                .usingColorSpace(.sRGB)
            let target = green.usingColorSpace(.sRGB)!
            let close = pixel.map { abs($0.redComponent - target.redComponent) < 0.03
                && abs($0.greenComponent - target.greenComponent) < 0.03
                && abs($0.blueComponent - target.blueComponent) < 0.03 } ?? (highlighted == nil)
            check(close, "\(name)（\(appearance == .aqua ? "浅色" : "深色")）：高亮格子画成主题绿", "\(String(describing: pixel))")
        }
        c.commitComposition(c.fake)
    }
}

private func wubiTests() {
    let wubi = ["InputScheme": "Wubi86", "WubiAutoCommit": "True", "WubiHint": "True"]
    do {
        let (c, _) = session(wubi)
        type(c, "g")
        check(texts.first == "一", "五笔 g → 一", "\(texts.prefix(3))")
        check(comments.contains { !$0.isEmpty }, "五笔 g 的候选后面有编码提示", "\(Array(zip(texts, comments)).prefix(5))")
    }
    do {
        let (c, f) = session(wubi)
        type(c, "ggll")
        check(f.text == "一" && f.markedText.isEmpty, "ggll 四码唯一自动上屏", "「\(f.text)」「\(f.markedText)」")
    }
    do {
        let (c, f) = session(wubi)
        type(c, "wqvbw")
        check(f.committed == "你好" && f.markedText == "w", "第五个键顶出你好、w 接着打", "「\(f.committed)」「\(f.markedText)」")
    }
    do {
        let (c, f) = session(wubi)
        type(c, "abb")
        check(texts.isEmpty && panel?.aux?.contains("空码") == true, "空码时候选框只有「空码」提示",
              "\(texts) \(String(describing: panel?.aux))")
        press(c, .space)
        check(f.text.isEmpty && f.markedText.isEmpty, "空码按空格清空、不上屏字母", "「\(f.text)」")
    }
    do {
        let (c, f) = session(wubi)
        type(c, "znihao")
        let i = texts.firstIndex(of: "你好")
        check(i != nil && comments[i!] == "wqvb", "z 临时拼音：你好后面是五笔码 wqvb", "\(Array(zip(texts, comments)).prefix(4))")
        press(c, .space)
        check(f.text == "你好", "z 拼音空格上屏", f.text)
    }
    do {
        let (c, f) = session(wubi)
        type(c, "V1+2*3")
        check(texts.first == "7", "五笔大写 V 计算器 1+2*3 → 7", "\(texts.prefix(3))")
        press(c, .space)
        check(f.text == "7", "计算结果上屏", f.text)
    }
    do {
        let (c, _) = session(["InputScheme": "Wubi86", "WubiHint": "False"])
        type(c, "g")
        check(comments.allSatisfy(\.isEmpty), "关了编码提示没有小字", "\(comments)")
    }
}

private func shuangpinTests() {
    do {
        let (c, f) = session(["InputScheme": "Shuangpin", "ShuangpinScheme": "Ziranma"])
        type(c, "nihk")
        check(f.markedText == "ni'hao", "自然码 nihk 编辑区显示全拼", f.markedText)
        check(texts.first == "你好", "自然码 nihk → 你好", "\(texts.prefix(3))")
        press(c, .space)
        check(f.text == "你好", "双拼上屏", f.text)
    }
    do {
        let (c, f) = session(["InputScheme": "Shuangpin", "ShuangpinScheme": "Ziranma", "ShuangpinShowKeys": "True"])
        type(c, "nihk")
        check(f.markedText.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "") == "nihk",
              "「编辑区显示打的键」：编辑区是 nihk", f.markedText)
        check(texts.first == "你好", "显示打的键时照样出你好", "\(texts.prefix(3))")
    }
}

/// 系统结束组字（commitComposition / 切走输入框 deactivateServer）：打的字母原样上屏，不带隔音符。
private func commitCompositionTests() {
    func both(_ name: String, _ values: [String: String], _ keys: (TestController) -> Void, expect: String) {
        for deactivate in [false, true] {
            let (c, f) = session(values)
            keys(c)
            if deactivate {
                c.deactivateServer(f)
            } else {
                c.commitComposition(f)
            }
            let how = deactivate ? "deactivateServer" : "commitComposition"
            check(f.committed == expect && !f.committed.contains("'"), "\(how)：\(name) → \(expect)",
                  "上屏「\(f.committed)」 编辑区「\(f.markedText)」")
            check(f.markedText.isEmpty && panel == nil, "\(how)：\(name) 之后编辑区、候选框收起")
        }
    }
    both("全拼", [:], { type($0, "nihao") }, expect: "nihao")
    both("选了一半的句子", [:], { c in
        type(c, "nihaoshijie")
        if let i = texts.firstIndex(of: "你好") {
            press(c, .char(Character("\(i + 1)")))
        } else {
            check(false, "nihaoshijie 的候选里有你好", "\(texts)")
        }
    }, expect: "你好shijie")
    both("双拼打的键", ["InputScheme": "Shuangpin", "ShuangpinScheme": "Ziranma"], { type($0, "nihk") }, expect: "nihk")
    both("五笔的码", ["InputScheme": "Wubi86"], { type($0, "wqv") }, expect: "wqv")
    // 互译：翻译服务指到本机一个没人听的端口（不跑 run loop，定时器不会真去请求）
    let translate = ["Translate": "True", "TranslateLocal": "False", "TranslateBaseUrl": "http://127.0.0.1:9/v1",
                     "TranslateModel": "shelltest"]
    both("互译里打的拼音", translate, { c in
        tapShift(c)
        tapShift(c)
        check(panel?.aux?.hasPrefix("译") == true, "两下 Shift 到「译」：提示「译 …」", "\(String(describing: panel?.aux))")
        type(c, "nihao")
        // 开着安全输入（别的程序的密码框在前台）时「译」里不翻译，候选框上面没有「互译」那一行
        if !IsSecureEventInputEnabled() {
            check(panel?.header != nil, "单按两下 Shift 到「译」，候选框上面是互译那一行",
                  "\(String(describing: panel?.header))")
        }
    }, expect: "nihao")
}

/// 上文：上屏「不」以后 ma 的第一个候选受上文影响；退格交给应用以后上文作废，ma 第一个回到「吗」。
private func contextTests() {
    for reliable in [true, false] {
        let which = reliable ? "读得到光标前文字的应用" : "读不到光标前文字的应用"
        let (c0, _) = session(reliable: reliable)
        type(c0, "ma")
        let plain = texts.first
        check(plain == "吗", "\(which)：ma 第一个是吗", "\(texts.prefix(3))")

        let (c1, f1) = session(reliable: reliable)
        type(c1, "bu")
        press(c1, .space)
        check(f1.text == "不", "\(which)：上屏不", f1.text)
        type(c1, "ma")
        let after = texts.first
        check(after != "吗", "\(which)：上屏「不」以后 ma 的第一个跟着上文变（不是吗）", "\(texts.prefix(3))")

        let (c, f) = session(reliable: reliable)
        type(c, "bu")
        press(c, .space)
        let handled = press(c, .backspace)
        check(!handled && f.text.isEmpty, "\(which)：退格交给应用、删掉了不", "「\(f.text)」")
        type(c, "ma")
        check(texts.first == "吗", "\(which)：退格以后上文作废，ma 第一个是吗", "\(texts.prefix(3))（上屏不以后是 \(after ?? "")）")
    }
}
