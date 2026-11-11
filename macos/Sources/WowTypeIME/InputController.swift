// 输入控制器：一个客户端连接一个控制器、一个会话。
//
// 这里只做三件事：把 NSEvent 翻译成 WowKeyEvent 交给会话、把会话的输出画出来（编辑区、候选框）、
// 把上屏文字交给应用。按键怎么处理全在核心的会话里。
// - 每次 handle 都重新绑定客户端（activateServer 不一定先来）；会话不在了就重建。
// - IMK 可能传 nil 事件：上屏已有内容并返回 false。
// - 应用调 commitComposition、切走（deactivateServer）：已选的词 + 原始字母上屏，关候选框。
// - 调应用的方法都包在 WTCatchException 里，应用抛异常不让输入法崩。
import AppKit
import CObjCSafe
import InputMethodKit
import WowTypeEngine
import WowTypeKit

typealias Client = any IMKTextInput & NSObjectProtocol

final class WowTypeInputController: IMKInputController {
    private var session: Session?
    private var boundClient: Client?
    /// 上一次交给应用的编辑区（相同就不再发）；nil 表示不知道应用那边是什么。
    private var lastMarked: MarkedState?
    private var lastGoodAnchor: CGRect?

    private struct MarkedState: Equatable {
        var text: String
        var plain: Int
        var caret: Int
    }

    // IMK 在主线程上建控制器，但父类的 init 不带隔离标记，这里也声明为 nonisolated。
    nonisolated override init() {
        super.init()
    }

    nonisolated override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
    }

    // MARK: - IMK 入口

    nonisolated override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    nonisolated override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        let args = MainThreadValue((event, sender))
        return mainSync { self.handleOnMain(args.value.0, sender: args.value.1) }
    }

    nonisolated override func activateServer(_ sender: Any!) {
        let sender = MainThreadValue(sender)
        mainSync {
            self.bind(sender.value)
            self.ensureSession().reset()
            self.lastMarked = nil
            CandidatePanel.shared.hide(owner: self)
            self.saveIfRequested()
        }
    }

    nonisolated override func deactivateServer(_ sender: Any!) {
        let sender = MainThreadValue(sender)
        mainSync {
            self.bind(sender.value)
            self.finishComposition()
            self.boundClient = nil
        }
    }

    nonisolated override func commitComposition(_ sender: Any!) {
        let sender = MainThreadValue(sender)
        mainSync {
            self.bind(sender.value)
            self.finishComposition()
        }
    }

    nonisolated override func hidePalettes() {
        mainSync { CandidatePanel.shared.hide(owner: self) }
    }

    nonisolated override func menu() -> NSMenu! {
        mainSync { AppMenu.make(target: self) }
    }

    // MARK: - 按键

    private func handleOnMain(_ event: NSEvent?, sender: Any?) -> Bool {
        bind(sender)
        guard let event else {
            // nil 事件（applefeedback FB11472618）：不丢用户打的字。
            finishComposition()
            return false
        }
        let kind: MacKeyInput.Kind
        switch event.type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        default: return false
        }
        // Command 组合键一律交给应用（会话对 Super 也是这样，这里不让它进会话）。
        if kind != .flagsChanged, event.modifierFlags.contains(.command) {
            return false
        }
        // flagsChanged 事件上读 characters 会抛异常。
        let isKey = kind != .flagsChanged
        let input = MacKeyInput(
            kind: kind,
            keyCode: event.keyCode,
            characters: isKey ? (event.characters ?? "") : "",
            charactersIgnoringModifiers: isKey ? (event.charactersIgnoringModifiers ?? "") : "",
            modifierFlags: UInt64(event.modifierFlags.rawValue))
        let now = Date()
        guard let key = KeyTranslator.translate(
            input, timeMs: Int64((now.timeIntervalSince1970 * 1000).rounded(.down)),
            utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: now))) else { return false }

        let handled = ensureSession().process(key, engine: IMEApp.shared.store.engine)
        render()
        return handled
    }

    // MARK: - 候选框回调

    func selectFromPanel(_ index: Int) {
        ensureSession().select(index, engine: IMEApp.shared.store.engine)
        render()
    }

    func pageFromPanel(_ delta: Int) {
        if ensureSession().page(delta) { render() }
    }

    // MARK: - 输出

    private func finishComposition() {
        let session = ensureSession()
        session.commitComposition(engine: IMEApp.shared.store.engine)
        if let text = session.takeCommit() { insert(text) }
        lastMarked = nil
        CandidatePanel.shared.hide(owner: self)
        saveIfRequested()
    }

    /// 会话说该存盘时（每 20 次学习，或失去焦点、切换输入法时还有没存的学习）才存盘。
    private func saveIfRequested() {
        if ensureSession().takeSaveRequest() {
            IMEApp.shared.store.save()
        }
    }

    /// 把会话的输出交给应用和候选框。
    private func render() {
        let session = ensureSession()
        if let text = session.takeCommit() {
            insert(text)
        }
        let snap = session.snapshot()
        updateMarkedText(snap)
        updatePanel(snap)
        saveIfRequested()
    }

    private func insert(_ text: String) {
        guard let client = boundClient else { return }
        let failure = WTCatchException {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        if let failure { Log.input.error("insertText 抛出异常: \(failure.name.rawValue, privacy: .public)") }
        // insertText 换掉了应用里的编辑区。
        lastMarked = MarkedState(text: "", plain: 0, caret: 0)
    }

    private func updateMarkedText(_ snap: SessionSnapshot) {
        guard let client = boundClient else { return }
        let layout = snap.preedit
        let want = snap.composing
            ? MarkedState(text: layout.text, plain: layout.plainUTF16, caret: layout.caretUTF16)
            : MarkedState(text: "", plain: 0, caret: 0)
        if want == lastMarked { return }

        let string = NSMutableAttributedString(string: want.text)
        let length = (want.text as NSString).length
        if want.plain > 0 {
            string.addAttributes([.markedClauseSegment: 0], range: NSRange(location: 0, length: want.plain))
        }
        if length > want.plain {
            string.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 1],
                                 range: NSRange(location: want.plain, length: length - want.plain))
        }
        let failure = WTCatchException {
            client.setMarkedText(string, selectionRange: NSRange(location: want.caret, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if let failure { Log.input.error("setMarkedText 抛出异常: \(failure.name.rawValue, privacy: .public)") }
        lastMarked = want
    }

    private func updatePanel(_ snap: SessionSnapshot) {
        let panel = CandidatePanel.shared
        guard let client = boundClient, snap.composing, !(snap.candidates.isEmpty && snap.aux.isEmpty) else {
            panel.hide(owner: self)
            return
        }
        // 位置和窗口层级在要显示时才问应用（激活之后都可能变）。
        let layout = snap.preedit
        let anchor = AnchorResolver.resolve(caret: layout.caretUTF16, length: layout.lengthUTF16,
                                            lastGood: lastGoodAnchor) { index in
            var rect = NSRect(x: 0, y: 0, width: 1, height: 1)  // 不用 .zero 当初值：有的应用会崩
            var result: NSRect?
            _ = WTCatchException {
                _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
                result = rect
            }
            return result
        }
        if let anchor { lastGoodAnchor = anchor }
        var level = Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1
        _ = WTCatchException { level = max(level, Int(client.windowLevel()) + 1) }
        panel.show(snap, anchor: anchor ?? fallbackAnchor(), level: level, owner: self)
    }

    /// 应用一个位置都给不出时：鼠标所在处。
    private func fallbackAnchor() -> CGRect {
        let p = NSEvent.mouseLocation
        return CGRect(x: p.x, y: p.y, width: 0, height: 16)
    }

    // MARK: -

    private func bind(_ sender: Any?) {
        if let client = sender as? Client, client !== boundClient {
            boundClient = client
            lastMarked = nil
            lastGoodAnchor = nil
        }
    }

    @discardableResult
    private func ensureSession() -> Session {
        if let session { return session }
        let created = Session()
        IMEApp.shared.store.register(created)
        session = created
        return created
    }
}
