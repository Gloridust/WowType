// IMK 输入控制器：每个输入框一个。按键翻译成 KeyInput 交给 Composer，Composer 通过 TextClient 回来写字。
//
// 类名要和 Info.plist 里的 InputMethodServerControllerClass 一样（WowTypeInputController）。

import AppKit
import Carbon
import InputMethodKit

@objc(WowTypeInputController)
final class WowTypeInputController: IMKInputController {
    private var composer: Composer!
    /// 上一次给应用的编辑区，一样就不再发（每次上屏后 Composer 都会清一次编辑区）。
    private var lastMarked = ""
    /// 最近上屏或交给应用的最后一个字。很多应用读不到光标前的字（attributedSubstring 返回 nil），用它兜底。
    private var lastInserted: UInt32 = 0
    private var lastFlags: UInt = 0
    /// 照哪一版设置配的会话（AppState.configGeneration）
    private var configGeneration = -1
    /// 互译：在等译文时每 50 毫秒取一次结果（主线程的 run loop 上，菜单打开时也走）
    private var translateTimer: Timer?
    static let translatePollInterval: TimeInterval = 0.05

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        composer = Composer(engine: AppState.shared.engine, client: self)
        composer.onCommit = { _ in AppState.shared.didCommit() }
        composer.onForget = { AppState.shared.didForget() }
        composer.sampleClipboard = { AppState.shared.sampleClipboard() }
        composer.onTranslatePoll = { [weak self] in self?.startTranslatePolling() }
        syncComposer()
    }

    private func startTranslatePolling() {
        guard translateTimer == nil else { return }
        let timer = Timer(timeInterval: Self.translatePollInterval, repeats: true) { [weak self] timer in
            guard let self, self.composer.pollTranslation() else {
                timer.invalidate()
                self?.translateTimer = nil
                return
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        translateTimer = timer
    }

    private func stopTranslatePolling() {
        translateTimer?.invalidate()
        translateTimer = nil
    }

    /// 词库载入完了、换了词库、改了设置：照 AppState 更新这个输入框的会话。
    private func syncComposer(force: Bool = false) {
        let state = AppState.shared
        state.checkForChanges(force: force)
        if let engine = state.engine, composer.currentEngine !== engine {
            composer.setEngine(engine)
        }
        composer.setTranslator(state.translator)
        if configGeneration != state.configGeneration {
            configGeneration = state.configGeneration
            composer.apply(state.config)
            VoiceInput.shared.configure(state.config, modelDir: state.voiceModelDir)
        }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        // keyUp 只给语音键用（F8 这类按住说话的键）
        Int(NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        syncComposer()
        switch event.type {
        case .flagsChanged:
            VoiceInput.shared.flagsChanged(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue,
                                           composing: composer.isComposing, host: self)
            handleFlags(event)
            // 修饰键永远交给应用
            return false
        case .keyUp:
            return VoiceInput.shared.keyEvent(keyCode: event.keyCode, up: true, composing: composer.isComposing,
                                              host: self)
        case .keyDown:
            if VoiceInput.shared.keyEvent(keyCode: event.keyCode, up: false, composing: composer.isComposing,
                                          host: self) {
                return true
            }
            guard let key = translateKeyDown(keyCode: event.keyCode, characters: event.characters,
                                             charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                                             cocoaFlags: event.modifierFlags.rawValue)
            else {
                // 翻不出来的键（F 键、别的键盘布局打出的非 ASCII 字符）：打字途中、互译攒着原文、
                // 工具栏或表情面板开着时吃掉，免得应用里的光标跑到别处
                composer.otherModifierChanged()
                composer.dismissPrediction()
                return composer.hasPendingText || composer.openPanel != nil
            }
            let handled = composer.handle(key)
            if !handled {
                // 交给应用的键也记下来（读不到光标前的字时，20:22 的冒号要知道前面是数字）；
                // 功能键、快捷键之后就不知道光标前是什么了
                let shortcut = !key.modifiers.isDisjoint(with: [.control, .option, .command])
                lastInserted = shortcut ? 0 : key.ascii.map { UInt32($0) } ?? 0
            }
            return handled
        default:
            return false
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.rawValue
        let changed = flags ^ lastFlags
        lastFlags = flags
        let shiftMask = NSEvent.ModifierFlags.shift.rawValue
        let others = NSEvent.ModifierFlags([.control, .option, .command]).rawValue
        let isShiftKey = event.keyCode == VirtualKey.shiftLeft || event.keyCode == VirtualKey.shiftRight
        if isShiftKey && changed & shiftMask != 0 {
            composer.shiftChanged(down: flags & shiftMask != 0, otherModifiers: flags & others != 0,
                                  now: event.timestamp, right: event.keyCode == VirtualKey.shiftRight)
        } else {
            composer.otherModifierChanged()
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        lastMarked = ""
        lastInserted = 0
        lastFlags = NSEvent.modifierFlags.rawValue
        syncComposer(force: true)
        // 剪贴板历史（设置里打开时）：切换输入框时看一眼（和 Linux 一样，另外打开工具栏的剪贴板页时也看）
        AppState.shared.sampleClipboard()
    }

    override func deactivateServer(_ sender: Any!) {
        VoiceInput.shared.cancel(for: self)
        composer.commitComposition()
        stopTranslatePolling()
        AppState.shared.candidatePanel.hide()
        AppState.shared.save()
        super.deactivateServer(sender)
    }

    /// 系统要求结束组字（换输入框、点了别处）：打到一半的原样上屏。
    override func commitComposition(_ sender: Any!) {
        composer.commitComposition()
    }

    override func hidePalettes() {
        composer.dismissPrediction() // 候选框收起了：联想也收起，免得数字键选到看不见的词
        AppState.shared.candidatePanel.hide()
        super.hidePalettes()
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        let item = NSMenuItem(title: "WowType \(appVersion)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        menu.addItem(.separator())
        // 设置窗口是另一个进程（SettingsApp）；直接改文件的入口在设置窗口的「文件」菜单里
        for (title, action) in [("WowType 设置…", #selector(openSettings)),
                                ("自定义词…", #selector(openCustomWords)),
                                ("设置互译 API Key…", #selector(editTranslateKey)),
                                ("打开数据目录", #selector(openDataFolder))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func openSettings() {
        SettingsApp.open()
    }

    @objc private func openCustomWords() {
        SettingsApp.open(page: .words)
    }

    @objc private func editTranslateKey() {
        TranslateKeyWindow.shared.show()
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(AppState.shared.supportDir)
    }

    private var textInput: (IMKTextInput & NSObjectProtocol)? {
        client()
    }

    private func noRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }
}

extension WowTypeInputController: TextClient {
    func insertText(_ text: String) {
        guard let client = textInput else { return }
        client.insertText(text, replacementRange: noRange())
        lastMarked = ""
        if let last = text.unicodeScalars.last {
            lastInserted = last.value
        }
    }

    func setMarkedText(_ text: String, cursor: Int) {
        guard let client = textInput, text != lastMarked else { return }
        lastMarked = text
        let attributed = NSMutableAttributedString(string: text)
        let whole = NSRange(location: 0, length: attributed.length)
        if attributed.length > 0,
           let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: whole) as? [NSAttributedString.Key: Any] {
            attributed.setAttributes(attrs, range: whole)
        }
        client.setMarkedText(attributed, selectionRange: NSRange(location: cursor, length: 0),
                             replacementRange: noRange())
    }

    func showCandidates(_ page: CandidatePage?) {
        let panel = AppState.shared.candidatePanel
        guard let page, let client = textInput else {
            panel.hide()
            return
        }
        var line = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &line)
        panel.show(page, below: line)
    }

    /// 应用告诉的光标前一个字；读不到是 nil。打字途中光标在编辑区里，要看编辑区前面那个字。
    private var clientPreviousCharacter: UInt32? {
        guard let client = textInput else { return nil }
        let marked = client.markedRange()
        let location = marked.location != NSNotFound && marked.length > 0
            ? marked.location : client.selectedRange().location
        guard location != NSNotFound, location > 0,
              let text = client.attributedSubstring(from: NSRange(location: location - 1, length: 1))?.string,
              let scalar = text.unicodeScalars.last
        else {
            return nil
        }
        return scalar.value
    }

    var previousCharacterIsReliable: Bool {
        clientPreviousCharacter != nil
    }

    /// 密码框（应用开了安全输入）里不翻译，照常打中文。
    var allowsTranslation: Bool {
        !IsSecureEventInputEnabled()
    }

    var previousCharacter: UInt32 {
        clientPreviousCharacter ?? lastInserted
    }
}

let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

// MARK: 语音输入

extension WowTypeInputController: VoiceHost {
    func voiceShow(status: String?, partial: String) {
        composer.dismissPrediction() // 候选框要画语音的提示：联想收起，免得数字键选到看不见的词
        setMarkedText(partial, cursor: partial.utf16.count)
        guard let status else {
            showCandidates(nil)
            return
        }
        showCandidates(CandidatePage(texts: [], cursor: -1, hasPrev: false, hasNext: false, expanded: false,
                                     aux: status))
    }

    func voiceCommit(_ text: String) {
        setMarkedText("", cursor: 0)
        showCandidates(nil)
        guard !text.isEmpty else { return }
        // 和打字上屏一样走 Composer：自动加空格、记上下文；互译时进原文
        composer.insert(text)
    }
}
