import Testing
@testable import WowTypeKit

private func ev(_ key: WowKey = .none, _ ch: Character? = nil, _ mods: WowModifiers = [],
                release: Bool = false) -> WowKeyEvent {
    WowKeyEvent(key: key, unicode: ch?.unicodeScalars.first?.value ?? 0, modifiers: mods,
                isRelease: release, utcOffsetSeconds: 0, timeMs: 0)
}

@Suite("按键 -> keysym")
struct XKeysymTests {
    @Test func charactersAreTheirCodePoints() {
        #expect(XKeysym.of(ev(.none, "a")) == 0x61)
        #expect(XKeysym.of(ev(.none, "，")) == 0xff0c)
        #expect(XKeysym.of(ev(.none, " ")) == 0x20)
    }

    @Test func keypadKeys() {
        #expect(XKeysym.of(ev(.none, "0", .keypad)) == XKeysym.keypad0)
        #expect(XKeysym.of(ev(.none, "7", .keypad)) == XKeysym.keypad0 + 7)
        #expect(XKeysym.of(ev(.none, "+", .keypad)) == XKeysym.keypadAdd)
        #expect(XKeysym.of(ev(.none, ".", .keypad)) == XKeysym.keypadDecimal)
        #expect(XKeysym.of(ev(.returnKey, nil, .keypad)) == XKeysym.keypadEnter)
        #expect(XKeysym.of(ev(.returnKey)) == XKeysym.returnKey)
    }

    @Test func shiftTabIsIsoLeftTab() {
        #expect(XKeysym.of(ev(.tab)) == XKeysym.tab)
        #expect(XKeysym.of(ev(.tab, nil, .shift)) == XKeysym.isoLeftTab)
    }

    @Test func everyNamedKeyHasAKeysym() {
        var seen = Set<UInt32>()
        for key in WowKey.allCases where key != .none {
            let sym = XKeysym.of(ev(key))
            #expect(sym >= 0xfe00, "\(key)")
            seen.insert(sym)
        }
        #expect(seen.count == WowKey.allCases.count - 1, "每个具名键的 keysym 都不一样")
    }
}

@Suite("几个输入框共用的状态")
@MainActor
struct SessionGroupTests {
    @Test func contextKeepsTheLast24Bytes() {
        let g = SessionGroup()
        #expect(g.didCommit("你好", learned: true, hasEngine: true) == "你好")
        g.didCommit("一二三四五六七八", learned: false, hasEngine: true)
        #expect(g.recent == "一二三四五六七八", "正好 24 字节")
        g.didCommit("ab", learned: false, hasEngine: true)
        #expect(g.recent == "二三四五六七八ab", "截到字的边界")
        #expect(SessionGroup.utf8Tail("a你好", max: 4) == "好", "不切开一个字")
    }

    @Test func saveEvery20Learned() {
        let g = SessionGroup()
        for _ in 0..<19 { g.didCommit("字", learned: true, hasEngine: true) }
        #expect(!g.takeSaveRequest())
        g.didCommit("。", learned: false, hasEngine: true)
        #expect(!g.takeSaveRequest(), "标点不算学习")
        g.didCommit("字", learned: true, hasEngine: true)
        #expect(g.takeSaveRequest())
        #expect(!g.takeSaveRequest(), "取一次就清零")
    }

    @Test func focusLossSavesOnlyWhenUnsaved() {
        let g = SessionGroup()
        g.requestSaveIfUnsaved()
        #expect(!g.takeSaveRequest())
        g.didCommit("字", learned: true, hasEngine: true)
        g.requestSaveIfUnsaved()
        #expect(g.takeSaveRequest())
        g.requestSaveIfUnsaved()
        #expect(!g.takeSaveRequest())
    }

    @Test func noEngineNoLearning() {
        let g = SessionGroup()
        #expect(g.didCommit("ni", learned: true, hasEngine: false) == nil)
        g.requestSaveIfUnsaved()
        #expect(!g.takeSaveRequest())
        #expect(g.recent == "ni", "上文照样记")
    }
}

@Suite("光标前一个字符")
struct PrevCharTrackerTests {
    @Test func followsCommitsAndPassedCharacters() {
        var t = PrevCharTracker()
        t.update(ev(.none, "3"), committed: nil, handled: false, wasComposing: false)
        #expect(t.prev == "3")
        t.update(ev(.none, "3", release: true), committed: nil, handled: false, wasComposing: false)
        #expect(t.prev == "3", "松开不改")
        t.update(ev(.shiftL), committed: nil, handled: false, wasComposing: false)
        #expect(t.prev == "3", "修饰键不改")
        t.update(ev(.none, " "), committed: "你好", handled: true, wasComposing: true)
        #expect(t.prev == "好")
        t.update(ev(.backspace), committed: nil, handled: false, wasComposing: false)
        #expect(t.prev == nil, "退格以后不知道")
        t.update(ev(.none, "c", .control), committed: nil, handled: false, wasComposing: false)
        #expect(t.prev == nil, "组合键不算")
        t.update(ev(.none, "n"), committed: nil, handled: true, wasComposing: false)
        #expect(t.prev == nil, "会话接住的字母不算")
        t.didCommit("国")
        #expect(t.prev == "国")
    }
}

@Suite("候选的显示和选择键")
struct CandidateLabelTests {
    @Test func listLabels() {
        #expect((0..<9).map { CandidateLabels.label(index: $0, grid: false, offset: 18, cursor: 4) }
                == ["1", "2", "3", "4", "5", "6", "7", "8", "9"])
    }

    @Test func gridLabelsOnlyOnCursorRow() {
        let labels = (0..<18).map { CandidateLabels.label(index: $0, grid: true, offset: 0, cursor: 8) }
        #expect(labels[0..<6].allSatisfy { $0.isEmpty })
        #expect(Array(labels[6..<12]) == ["1", "2", "3", "4", "5", "6"])
        #expect(labels[12...].allSatisfy { $0.isEmpty })
    }

    @Test func displayMarksNewlinesAndTabs() {
        #expect(CandidateLabels.display("a\nb\tc") == "a⏎b⇥c")
    }
}
