// 外壳在会话外面要做的事（核心的会话只管一个输入框里的按键）。照 fcitx5 外壳的
// finishCommit / rememberContext 和 DigitTracker 写，core/tests/session_full_keys.rs 里的
// `shell` 模块是同一份逻辑，那边的 44 个按键测试就是这里的规格：
// - 记最近上屏的字（24 字节）当上文，几个输入框共用；
// - 攒学习次数，每 20 次、或者失去焦点 / 切换输入法时还有没存的学习，要求存盘；
// - 中英文模式在输入框之间共用；
// - 记光标前一个字符（数字后的句点、成对引号要用）。
//
// 这里没有核心的数值：keysym 是 XKB 的标准值（核心的 WowtypeKey 就收这个），修饰键位、
// 模式、面板的数值在 WowTypeEngine 里对到头文件的常量。

/// WowKeyEvent -> XKB keysym（核心的 WowtypeKey.keysym）。
public enum XKeysym {
    public static let backspace: UInt32 = 0xff08
    public static let tab: UInt32 = 0xff09
    public static let returnKey: UInt32 = 0xff0d
    public static let escape: UInt32 = 0xff1b
    public static let home: UInt32 = 0xff50
    public static let left: UInt32 = 0xff51
    public static let up: UInt32 = 0xff52
    public static let right: UInt32 = 0xff53
    public static let down: UInt32 = 0xff54
    public static let pageUp: UInt32 = 0xff55
    public static let pageDown: UInt32 = 0xff56
    public static let end: UInt32 = 0xff57
    public static let keypadEnter: UInt32 = 0xff8d
    public static let keypadMultiply: UInt32 = 0xffaa
    public static let keypadAdd: UInt32 = 0xffab
    public static let keypadSubtract: UInt32 = 0xffad
    public static let keypadDecimal: UInt32 = 0xffae
    public static let keypadDivide: UInt32 = 0xffaf
    public static let keypad0: UInt32 = 0xffb0
    public static let keypadEqual: UInt32 = 0xffbd
    public static let f1: UInt32 = 0xffbe
    public static let shiftL: UInt32 = 0xffe1
    public static let shiftR: UInt32 = 0xffe2
    public static let controlL: UInt32 = 0xffe3
    public static let controlR: UInt32 = 0xffe4
    public static let capsLock: UInt32 = 0xffe5
    public static let altL: UInt32 = 0xffe9
    public static let altR: UInt32 = 0xffea
    public static let superL: UInt32 = 0xffeb
    public static let superR: UInt32 = 0xffec
    public static let delete: UInt32 = 0xffff
    /// X11 和 fcitx5 把 Shift+Tab 报成这个。
    public static let isoLeftTab: UInt32 = 0xfe20

    private static let named: [WowKey: UInt32] = [
        .backspace: backspace, .returnKey: returnKey, .escape: escape, .tab: tab, .delete: delete,
        .left: left, .right: right, .up: up, .down: down, .home: home, .end: end,
        .pageUp: pageUp, .pageDown: pageDown, .shiftL: shiftL, .shiftR: shiftR,
        .controlL: controlL, .controlR: controlR, .altL: altL, .altR: altR,
        .superL: superL, .superR: superR, .capsLock: capsLock, .other: f1,
    ]

    public static func of(_ event: WowKeyEvent) -> UInt32 {
        let keypad = event.modifiers.contains(.keypad)
        switch event.key {
        case .none:
            guard keypad, let scalar = Unicode.Scalar(event.unicode) else { return event.unicode }
            switch scalar {
            case "0"..."9": return keypad0 + (scalar.value - 0x30)
            case "+": return keypadAdd
            case "-": return keypadSubtract
            case "*": return keypadMultiply
            case "/": return keypadDivide
            case ".": return keypadDecimal
            case "=": return keypadEqual
            default: return event.unicode
            }
        case .returnKey where keypad:
            return keypadEnter
        case .tab where event.modifiers.contains(.shift):
            return isoLeftTab
        default:
            return named[event.key] ?? f1
        }
    }
}

/// 几个输入框共用的状态（fcitx5 外壳里是插件对象的成员）。只在主线程上用。
@MainActor
public final class SessionGroup {
    /// 上文最多留多少字节（UTF-8，从尾巴截，不切开一个字）。
    public static let contextBytes = 24
    /// 攒多少次学习存一次盘。
    public static let saveEvery = 20

    public static let shared = SessionGroup()

    /// 英文模式（单按 Shift 切换，几个输入框一起）。
    public var english = false
    /// 最近上屏的字，给会话和引擎当上文。
    public private(set) var recent = ""
    private var unsaved = 0
    private var saveRequested = false

    public init() {}

    /// 上屏了 text。learned：会话说这次记了选词；hasEngine：有引擎（没引擎时学习不算数）。
    /// 返回要交给引擎的新上文（没有引擎时为 nil）。
    @discardableResult
    public func didCommit(_ text: String, learned: Bool, hasEngine: Bool) -> String? {
        guard !text.isEmpty else { return nil }
        recent = Self.utf8Tail(recent + text, max: Self.contextBytes)
        guard hasEngine else { return nil }
        if learned {
            unsaved += 1
            if unsaved >= Self.saveEvery {
                unsaved = 0
                saveRequested = true
            }
        }
        return recent
    }

    /// 失去焦点、切换输入法：还有没存的学习就要求存盘。
    public func requestSaveIfUnsaved() {
        if unsaved > 0 {
            unsaved = 0
            saveRequested = true
        }
    }

    /// 要不要存盘；取一次就清零。
    public func takeSaveRequest() -> Bool {
        defer { saveRequested = false }
        return saveRequested
    }

    static func utf8Tail(_ text: String, max: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > max else { return text }
        var start = bytes.count - max
        // 跳过续字节（10xxxxxx），不切开一个字
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        return String(decoding: bytes[start...], as: UTF8.self)
    }
}

/// 光标前一个字符（fcitx5 外壳的 DigitTracker）：上屏了就是上屏的最后一个字；没上屏时，
/// 原样交给应用的字符算数，别的键（退格、方向键……）就不知道了。修饰键本身和松开不改。
public struct PrevCharTracker: Sendable, Equatable {
    public private(set) var prev: Unicode.Scalar?

    public init() {}

    public mutating func update(_ event: WowKeyEvent, committed: String?, handled: Bool, wasComposing: Bool) {
        if let committed, let last = committed.unicodeScalars.last {
            prev = last
            return
        }
        if event.isRelease || Self.isModifierKey(event.key) { return }
        let command = !event.modifiers.isDisjoint(with: [.control, .alt, .super])
        if event.key == .none, !handled, !wasComposing, !command, event.unicode != 0 {
            prev = Unicode.Scalar(event.unicode)
        } else {
            prev = nil
        }
    }

    /// 上屏不是按键带来的（点选候选、切换输入法）。
    public mutating func didCommit(_ text: String?) {
        if let last = text?.unicodeScalars.last { prev = last }
    }

    static func isModifierKey(_ key: WowKey) -> Bool {
        switch key {
        case .shiftL, .shiftR, .controlL, .controlR, .altL, .altR, .superL, .superR, .capsLock: true
        default: false
        }
    }
}

/// 候选框里每个候选的显示文字和选择键。
public enum CandidateLabels {
    public static let gridColumns = 6

    /// 换行、制表符画成 ⏎、⇥（上屏的还是原文）。
    public static func display(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥")
    }

    /// 列表是 1–9；展开面板里只有光标所在行有 1–6，其余是空串。
    /// offset：这一屏第一个在全部候选里的序号；cursor：光标在这一屏的位置。
    public static func label(index: Int, grid: Bool, offset: Int, cursor: Int) -> String {
        guard grid else { return String(index % 9 + 1) }
        let at = offset + index
        let row = (offset + cursor) / gridColumns
        return at / gridColumns == row ? String(at % gridColumns + 1) : ""
    }
}
