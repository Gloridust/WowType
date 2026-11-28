// IMK 输入控制器：每个输入框一个。按键翻译成 KeyInput 交给 Composer，Composer 通过 TextClient 回来写字。
//
// 类名要和 Info.plist 里的 InputMethodServerControllerClass 一样（WowTypeInputController）。
// 不是 final：外壳测试（macos/ShellTests）用子类换掉 client()，给它一个假的输入框。

import AppKit
import Carbon
import InputMethodKit
import os

/// 修饰键事件的调试记录（debug 级别，平时不记）。看某个应用里单按 Shift 收到了什么：
/// log stream --level debug --predicate 'subsystem == "WowType" && category == "flags"'
private let flagsLog = Logger(subsystem: "WowType", category: "flags")

@objc(WowTypeInputController)
class WowTypeInputController: IMKInputController {
    private var composer: Composer!
    /// 上一次给应用的编辑区和光标，一样就不再发（每次上屏后 Composer 都会清一次编辑区）。
    /// 光标也要比：方向键移光标时字没变、光标变了
    private var lastMarked = (text: "", cursor: 0)
    /// 最近上屏或交给应用的最后一个字。很多应用读不到光标前的字（attributedSubstring 返回 nil），用它兜底。
    private var lastInserted: UInt32 = 0
    /// 上一次松开 Shift 那个事件的时刻（NSEvent.timestamp）
    private var lastShiftTap: TimeInterval = -.infinity
    /// 松开 Shift 以后这么久以内又「按下」的 Shift 不算：Electron 的应用有时把一次按下松开报成两遍
    /// （或者晚一点重发原来的事件），人连按两下没有这么快。单按先等双击（#253）、松开时还没切，
    /// 所以每次松开都记，不然重报的那一遍会被当成双击，单按就切不了
    static let shiftBounce: TimeInterval = 0.05
    /// 照哪一版设置配的会话（AppState.configGeneration）
    private var configGeneration = -1
    /// 互译：在等译文时每 50 毫秒取一次结果（主线程的 run loop 上，菜单打开时也走）
    private var translateTimer: Timer?
    static let translatePollInterval: TimeInterval = 0.05
    /// 切中 / 英 / 译以后在光标下面亮一下的提示，到时间收起（和 Linux 上 fcitx5 的提示一样）
    private var modeHintTimer: Timer?
    static let modeHintDuration: TimeInterval = 1
    /// 这一下按键里上屏以后光标在应用文字里的位置（UTF-16，上屏前的编辑区 / 选区起点 + 上屏的字数）。
    /// 自动配对紧接着按它挪光标：有的应用（Chromium、WebKit）上屏是异步的，刚上屏时问 selectedRange 还是旧的
    private var caretAfterInsert: Int?
    /// 照哪一轮「切到 WowType」定过模式（AppState.switchGeneration，InitialMode）；0 是还没定过
    private var initialModeGeneration = 0

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        composer = Composer(engine: AppState.shared.engine, client: self)
        composer.onCommit = { _ in AppState.shared.didCommit() }
        composer.onCommitStats = { text, source, scheme, index in
            AppState.shared.recordCommit(text, source: source, scheme: scheme,
                                         candidateIndex: index, sensitive: IsSecureEventInputEnabled())
        }
        composer.onForget = { AppState.shared.didForget() }
        composer.sampleClipboard = { AppState.shared.sampleClipboard() }
        composer.onTranslatePoll = { [weak self] in self?.startTranslatePolling() }
        syncComposer()
    }

    private func startTranslatePolling() {
        guard translateTimer == nil else { return }
        let timer = Timer(timeInterval: Self.translatePollInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let mode = self.composer.mode
            let more = self.composer.pollTranslation()
            if self.composer.mode != mode {
                // 单按 Shift 等双击等到了时间（#253）：这时才切，弹「中 / 英」提示
                self.showModeHint()
            }
            if !more {
                timer.invalidate()
                self.translateTimer = nil
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

    /// 候选框上的鼠标操作：和按键一样先跟上设置，挪光标的位置从头算
    fileprivate func mouseAction(_ action: (Composer) -> Void) {
        caretAfterInsert = nil
        syncComposer()
        action(composer)
    }

    /// 外部命令切模式（AppState.externalMode）：request 空串只问。和 Linux 一样不弹提示；
    /// 打到一半切英文时打的字母原样上屏（会话做）。
    func externalMode(_ request: String) -> String {
        syncComposer()
        if !request.isEmpty {
            composer.setMode(named: request)
        }
        return composer.modeName
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        // keyUp 只给语音键用（F8 这类按住说话的键）
        Int(NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        caretAfterInsert = nil
        syncComposer()
        let mode = composer.mode
        let handled = handleKey(event)
        if composer.mode != mode {
            showModeHint()
        }
        return handled
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            VoiceInput.shared.flagsChanged(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue,
                                           composing: composer.isComposing, host: self)
            recordModifierPress(event)
            handleFlags(event)
            // 修饰键永远交给应用
            return false
        case .keyUp:
            return VoiceInput.shared.keyEvent(keyCode: event.keyCode, up: true, composing: composer.isComposing,
                                              host: self)
        case .keyDown:
            recordKeyPress(event)
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

    /// 按键热力图（TypingStats 开着时）：自动重复不算，密码框（安全输入）不计。功能键也在这一层记，
    /// 因为 `translateKeyDown` 会把 F 键、别的键盘布局打出的字符丢掉。
    private func recordKeyPress(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        AppState.shared.recordKey(event.keyCode, sensitive: IsSecureEventInputEnabled())
    }

    /// 修饰键只有 flagsChanged：按左右设备位判断是不是按下那一边。
    private var modifierHeld: Set<UInt16> = []

    private func recordModifierPress(_ event: NSEvent) {
        // 统计关着时连按着哪个修饰键也不记
        guard AppState.shared.config.typingStats else {
            modifierHeld.removeAll()
            return
        }
        let code = event.keyCode
        if code == 0x39 {  // Caps Lock 只在切换时来一次，每次切换都算按了一下
            AppState.shared.recordKey(code, sensitive: IsSecureEventInputEnabled())
            return
        }
        let bit: NSEvent.ModifierFlags?
        switch code {
        case 0x38, 0x3C: bit = .shift
        case 0x3B, 0x3E: bit = .control
        case 0x3A, 0x3D: bit = .option
        case 0x37, 0x36: bit = .command
        default: return
        }
        guard let bit else { return }
        let down = event.modifierFlags.contains(bit)
        if down {
            if modifierHeld.insert(code).inserted {
                AppState.shared.recordKey(code, sensitive: IsSecureEventInputEnabled())
            }
        } else {
            modifierHeld.remove(code)
        }
    }

    /// 修饰键变了。按下还是松开只看这个事件自己带的标志，不和上一个事件比：Chromium / Electron 的
    /// 应用会多报、重报 flagsChanged（同一个状态来两遍），以前一比就当成按了别的修饰键，单按 Shift 就没了。
    /// 多报的按下会话当成重新按下，多报的松开没有按下对着、不算。
    private func handleFlags(_ event: NSEvent) {
        // 插值只在开着 debug 日志时才算（不开时不去问应用是谁）
        flagsLog.debug("\(self.textInput?.bundleIdentifier() ?? "?", privacy: .public) key=\(event.keyCode) flags=\(String(event.modifierFlags.rawValue, radix: 16), privacy: .public) t=\(event.timestamp)")
        let flags = event.modifierFlags.rawValue
        let others = NSEvent.ModifierFlags([.control, .option, .command]).rawValue
        let right = event.keyCode == VirtualKey.shiftRight
        guard right || event.keyCode == VirtualKey.shiftLeft else {
            // 别的修饰键：按着 Control、Option、Command 时这次 Shift 不算单按。不带这几个的
            // （Fn、CapsLock，或者应用多报的别的键码）不管
            if flags & others != 0 {
                composer.otherModifierChanged()
            }
            return
        }
        // 左右 Shift 的设备位（NX_DEVICELSHIFTKEYMASK、NX_DEVICERSHIFTKEYMASK）；事件没带设备位时看 Shift 位
        let side: UInt = right ? 0x04 : 0x02
        let down = flags & 0x06 != 0 ? flags & side != 0 : flags & NSEvent.ModifierFlags.shift.rawValue != 0
        if down && event.timestamp - lastShiftTap < Self.shiftBounce {
            return
        }
        composer.shiftChanged(down: down, otherModifiers: flags & others != 0, now: composer.clock(), right: right)
        if !down {
            lastShiftTap = event.timestamp
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        lastMarked = ("", 0)
        lastInserted = 0
        syncComposer(force: true)
        // 从别的输入法切回来（不是换应用、换窗口）、这个进程里第一次用到这个输入框：按「切到 WowType 时」定中 / 英
        // （InitialMode，和 Linux 一样；macOS 每个应用一份模式，新的一轮里每个输入框定一次）
        let (generation, switchedBack) = AppState.shared.noteActivated()
        if initialModeGeneration != generation {
            initialModeGeneration = generation
            composer.applyInitialMode()
        }
        // 换到别的应用、别的窗口：设了「默认中/英文」就定一次（WindowMode，#254；默认和上次一样，不动）。
        // 刚从别的输入法切回来的这一下按上面的 InitialMode，别让两边抢着定
        if AppState.shared.config.windowMode != .same {
            let moved = AppState.shared.noteWindow(focusKey())
            if moved && !switchedBack {
                composer.applyWindowMode()
            }
        }
        AppState.shared.activeController = self
        // 开发者模式的记录里带上是在哪个应用里打的（关着时只是记个名字，什么都不写）
        DevLog.setApp(textInput?.bundleIdentifier() ?? "")
        // 剪贴板历史（设置里打开时）：切换输入框时看一眼（和 Linux 一样，另外打开工具栏的剪贴板页时也看）
        AppState.shared.sampleClipboard()
        AppState.shared.touchClipboardSync()
        // 每天最多查一次有没有新版本（后台，有新版时菜单里多一项）
        AppState.shared.checkUpdateIfDue()
    }

    /// 现在用 WowType 的是哪个应用的哪个窗口（WindowMode）：应用的 bundle id + 它最前面的普通窗口的窗口号。
    /// 窗口号不要「屏幕录制」权限（只看窗口号和所属进程，不读标题）；问不到时只看应用。
    private func focusKey() -> String {
        let app = textInput?.bundleIdentifier() ?? ""
        return WindowFocus.key(app: app, window: Self.frontWindow(of: app))
    }

    private static func frontWindow(of bundle: String) -> Int? {
        guard !bundle.isEmpty,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        // 从前往后排的，第一个是这个应用最前面的窗口；只看普通窗口那一层（菜单、浮条不算）
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            return (info[kCGWindowNumber as String] as? NSNumber)?.intValue
        }
        return nil
    }

    override func deactivateServer(_ sender: Any!) {
        VoiceInput.shared.cancel(for: self)
        composer.commitComposition()
        stopTranslatePolling()
        showCandidates(nil)
        AppState.shared.save()
        AppState.shared.flushStats()
        modifierHeld.removeAll()
        // 是不是切走了输入法：过一会儿看系统现在用的输入源（InitialMode）
        AppState.shared.noteDeactivated()
        super.deactivateServer(sender)
    }

    /// 系统要求结束组字（换输入框、点了别处、切走输入法）：打的字母原样上屏，见 Composer.commitComposition。
    override func commitComposition(_ sender: Any!) {
        composer.commitComposition()
    }

    override func hidePalettes() {
        AppState.shared.candidatePanel.hide()
        super.hidePalettes()
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        let item = NSMenuItem(title: "WowType \(appVersion)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        if AppState.shared.config.checkUpdate, let version = AppState.shared.availableUpdate {
            let update = NSMenuItem(title: "有新版本 \(version)，下载并安装…", action: #selector(openUpdate),
                                    keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
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

    /// 新版本在设置窗口「常规」页下载安装（不在输入法进程里装：安装时会停掉输入法自己）
    @objc private func openUpdate() {
        SettingsApp.open(page: .general)
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
        // 自动配对接着要按位置挪光标：先记下上屏的字落在哪（编辑区或选区的起点），不在上屏以后再问应用
        caretAfterInsert = AppState.shared.config.autoPairPunct
            ? insertionStart(client).map { $0 + text.utf16.count } : nil
        client.insertText(text, replacementRange: noRange())
        lastMarked = ("", 0)
        if let last = text.unicodeScalars.last {
            lastInserted = last.value
        }
    }

    func setMarkedText(_ text: String, cursor: Int) {
        guard let client = textInput, (text, cursor) != lastMarked else { return }
        lastMarked = (text, cursor)
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
        modeHintTimer?.invalidate()
        modeHintTimer = nil
        let panel = AppState.shared.candidatePanel
        guard let page, let client = textInput else {
            panel.hide()
            return
        }
        var line = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &line)
        // 鼠标点候选、翻页箭头、滚轮：交给这个输入框的组字（候选框所有输入框共用，谁画的归谁）
        panel.onSelect = { [weak self] index in
            self?.mouseAction { $0.select(index) }
        }
        panel.onPage = { [weak self] forward in
            self?.mouseAction { $0.turnPage(forward: forward) }
        }
        // 右键「忘掉这个词」（#229）：学过的词才出菜单
        panel.canForget = { [weak self] index in
            self?.composer.canForget(index) ?? false
        }
        panel.onForget = { [weak self] index in
            self?.mouseAction { $0.forget(index) }
        }
        panel.show(page, below: line)
    }

    /// 切到中 / 英 / 译以后在光标下面亮一下「中」「英」「译 中→英」，过一会儿收起；还有没上屏的字时不画
    /// （候选框正画着它们）。
    private func showModeHint() {
        guard !composer.hasPendingText else { return }
        let label: String
        switch composer.mode {
        case .chinese: label = "中"
        case .english: label = "英"
        case .translate: label = ["译", AppState.shared.translator?.tag(for: "") ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        }
        showCandidates(CandidatePage(texts: [], cursor: -1, hasPrev: false, hasNext: false, expanded: false, aux: label))
        let timer = Timer(timeInterval: Self.modeHintDuration, repeats: false) { [weak self] _ in
            self?.showCandidates(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        modeHintTimer = timer
    }

    /// 应用告诉的光标前一个字；光标在开头、应用说得清（见 caretAtStartIsKnown）是 0；读不到是 nil。
    /// 打字途中光标在编辑区里，要看编辑区前面那个字。
    private var clientPreviousCharacter: UInt32? {
        guard let client = textInput else { return nil }
        let marked = client.markedRange()
        let location = marked.location != NSNotFound && marked.length > 0
            ? marked.location : client.selectedRange().location
        guard location != NSNotFound else { return nil }
        if location == 0 {
            return caretAtStartIsKnown(client) ? 0 : nil
        }
        guard let text = client.attributedSubstring(from: NSRange(location: location - 1, length: 1))?.string,
              let scalar = text.unicodeScalars.last
        else {
            return nil
        }
        return scalar.value
    }

    /// 光标在位置 0 时光标前确实没有字（输入框清空了、光标挪到了开头）：应用读得出开头的字，或者整个输入框是空的。
    /// 会话拿它清掉自己记的上文，和 fcitx5、Windows 一样。终端不算（位置是假的）；什么都不说的应用位置是 NSNotFound，到不了这里
    private func caretAtStartIsKnown(_ client: IMKTextInput & NSObjectProtocol) -> Bool {
        if WowTypeInputController.terminalApps.contains(client.bundleIdentifier() ?? "") {
            return false
        }
        return client.length() == 0 || readable(client, NSRange(location: 0, length: 1))
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

    // MARK: 自动配对（AutoPairPunct）
    //
    // IMK 没有挪光标的接口，发方向键要「辅助功能」权限。能用的是按位置换字：insertText 带 replacementRange
    // （长按出重音字母、自动更正都是这么换的），换完光标落在换上的字后面。挪光标就是把目标位置前面那个字
    // 原样换一遍（见 Shared/Composer.swift 的 CaretEdit）。只在应用说得清光标在哪、读得到光标旁边的字时开配对，
    // 终端这类不报位置的应用里照常一个一个上屏。

    /// 上屏的字从哪里开始：有编辑区时是编辑区的起点，否则是选区（光标）的起点；应用不说是 nil。
    private func insertionStart(_ client: IMKTextInput & NSObjectProtocol) -> Int? {
        let marked = client.markedRange()
        if marked.location != NSNotFound && marked.length > 0 {
            return marked.location
        }
        let selected = client.selectedRange()
        return selected.location == NSNotFound ? nil : selected.location
    }

    /// 现在的光标位置：没有编辑区、没有选区时才算；应用不说是 nil。
    private var currentCaret: Int? {
        guard let client = textInput else { return nil }
        let marked = client.markedRange()
        guard marked.location == NSNotFound || marked.length == 0 else { return nil }
        let selected = client.selectedRange()
        guard selected.location != NSNotFound, selected.length == 0 else { return nil }
        return selected.location
    }

    /// 应用在 range 上给不给得出字（给了空串、nil 都算给不出）。
    private func readable(_ client: IMKTextInput & NSObjectProtocol, _ range: NSRange) -> Bool {
        (client.attributedSubstring(from: range)?.length ?? 0) > 0
    }

    /// 终端：文字是程序画的，换不了光标前面已经「打出去」的字，按位置换字只会多打一遍。不管报不报位置都不配对
    static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "org.alacritty", "io.alacritty", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "co.zeit.hyper",
        "org.tabby", "com.raggesilver.BlackBox",
    ]

    var canEditAroundCaret: Bool {
        guard let client = textInput, !WowTypeInputController.terminalApps.contains(client.bundleIdentifier() ?? ""),
              let start = insertionStart(client) else { return false }
        // 光标旁边的字读得到，才信应用会照位置换字（文档开头读后面那个字；空的输入框里先不配对）
        if start > 0 {
            return readable(client, NSRange(location: start - 1, length: 1))
        }
        return readable(client, NSRange(location: 0, length: 1))
    }

    var nextCharacter: UInt32? {
        guard let client = textInput else { return nil }
        let marked = client.markedRange()
        let location: Int
        if marked.location != NSNotFound && marked.length > 0 {
            location = marked.location + marked.length
        } else {
            let selected = client.selectedRange()
            // 有选区时不报（打的字会换掉选中的）
            guard selected.location != NSNotFound, selected.length == 0 else { return nil }
            location = selected.location
        }
        guard let text = client.attributedSubstring(from: NSRange(location: location, length: 1))?.string,
              let scalar = text.unicodeScalars.first
        else {
            return nil
        }
        return scalar.value
    }

    func edit(_ edit: CaretEdit) -> Bool {
        guard let client = textInput, let caret = caretAfterInsert ?? currentCaret else { return false }
        let location = caret + edit.offset
        guard location >= 0, edit.length >= 0 else { return false }
        client.insertText(edit.text, replacementRange: NSRange(location: location, length: edit.length))
        caretAfterInsert = location + edit.text.utf16.count
        lastMarked = ("", 0)
        lastInserted = edit.text.unicodeScalars.last?.value ?? 0
        return true
    }
}

let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"

// MARK: 语音输入

extension WowTypeInputController: VoiceHost {
    func voiceShow(status: String?, partial: String) {
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
