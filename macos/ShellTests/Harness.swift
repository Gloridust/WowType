// 测试进程的准备（只用临时数据目录、不上屏、载入词库）和按键用的小函数。

import AppKit
import Carbon

var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

let state = AppState.shared

/// 数据目录必须是 WOWTYPE_DATA_DIR 指的临时目录（不碰 ~/Library）；建好 NSApplication（不 run、不激活、
/// 不进程序坞），候选框只排版不上屏，载入词库。
func setUpHarness() {
    setbuf(stdout, nil)
    let realHome = String(cString: getpwuid(getuid())!.pointee.pw_dir)
    guard let dir = ProcessInfo.processInfo.environment["WOWTYPE_DATA_DIR"], !dir.isEmpty,
          !URL(fileURLWithPath: dir).standardizedFileURL.path.hasPrefix(realHome + "/Library"),
          state.supportDir.standardizedFileURL.path == URL(fileURLWithPath: dir).standardizedFileURL.path
    else {
        print("要用 WOWTYPE_DATA_DIR 指到一个临时目录（不能是 ~/Library 下面）")
        exit(2)
    }
    NSApplication.shared.setActivationPolicy(.prohibited)
    state.candidatePanel.onScreen = false
    print("资源目录 \(state.resourceDir.path)")
    print("数据目录 \(state.supportDir.path)")
    for name in ["lexicon.tsv", "english.txt", "s2t.tsv", "wubi86.tsv"] where state.resource(name) == nil {
        print("资源目录里没有 \(name)")
        exit(2)
    }
    writeConfig([:])
    state.loadEngineInBackground()
    let start = Date()
    while state.engine == nil && Date().timeIntervalSince(start) < 120 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    guard state.engine != nil else {
        print("FAIL 词库两分钟没载入")
        exit(1)
    }
    print(String(format: "词库载入 %.1f 秒", Date().timeIntervalSince(start)))
    if IsSecureEventInputEnabled() {
        print("注意：系统开着安全输入（别的程序的密码框在前台），这时「译」里不翻译")
    }
}

/// 这个进程有没有窗口在屏幕上（应该永远没有）。
func windowsOnScreen() -> [String] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        .map { "\($0[kCGWindowName as String] ?? "") \($0[kCGWindowBounds as String] ?? "")" }
}

// MARK: 设置和会话

private var configStampSeconds = Date().timeIntervalSince1970.rounded(.down) - 10_000

/// 写 wowtype.conf（语音、剪贴板历史总是关着：不碰麦克风、不读系统剪贴板）。
/// 修改时间每次往后挪一秒，输入法的 checkForChanges 一定看得出变了。
func writeConfig(_ values: [String: String]) {
    var all = ["Voice": "False", "ClipboardHistory": "False"]
    all.merge(values) { $1 }
    let text = all.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n"
    try? FileManager.default.createDirectory(at: state.supportDir, withIntermediateDirectories: true)
    try! text.write(toFile: state.configPath, atomically: true, encoding: .utf8)
    configStampSeconds += 1
    try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: configStampSeconds)],
                                           ofItemAtPath: state.configPath)
}

/// 照这份设置开一个输入框：新建输入控制器（像 IMK 给每个输入框建一个），activateServer 时读设置。
func session(_ values: [String: String] = [:], reliable: Bool = true) -> (TestController, FakeTextInput) {
    writeConfig(values)
    let controller = TestController(server: nil, delegate: nil, client: nil)!
    let fake = FakeTextInput(reliable: reliable)
    controller.fake = fake
    controller.activateServer(fake)
    return (controller, fake)
}

/// 按一个键：先给输入法，它不要就像应用一样处理。返回输入法吃没吃。
@discardableResult
func press(_ c: TestController, _ key: Key) -> Bool {
    let event = keyDown(key)
    let handled = c.handle(event, client: c.fake)
    if !handled {
        c.fake?.appHandles(event)
    }
    return handled
}

func type(_ c: TestController, _ text: String) {
    for ch in text {
        press(c, .char(ch))
    }
}

/// 上一下 Shift 松开的事件时刻
private var lastShiftUp: TimeInterval = 0

/// 单按一下 Shift（按下、0.1 秒后松开）。事件时刻和真键盘一样往后走：下一下在上一下松开 0.2 秒以后，
/// 不然会被当成 Electron 那种重报的回弹。
func tapShift(_ c: TestController, right: Bool = false) {
    let t = max(ProcessInfo.processInfo.systemUptime, lastShiftUp + 0.2)
    _ = c.handle(shiftEvent(down: true, right: right, at: t), client: c.fake)
    _ = c.handle(shiftEvent(down: false, right: right, at: t + 0.1), client: c.fake)
    lastShiftUp = t + 0.1
}

/// 候选框现在排的这一页（收起时 nil）
var panel: CandidateLayout? { state.candidatePanel.layout }
var texts: [String] { panel?.cells.map(\.text) ?? [] }
var comments: [String] { panel?.cells.map(\.comment) ?? [] }
var current: Int? { panel?.cells.firstIndex(where: \.current) }
