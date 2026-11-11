// macOS 按键 → 核心的键码（XKB keysym 子集）和修饰键。
//
// 这个文件不依赖 AppKit：Linux 上也能编译，按键测试（Tests/main.swift）在 CI 的 Linux 和 macOS 上都跑。
// 输入法外壳（InputController.swift）把 NSEvent 的 keyCode、characters、modifierFlags 原样传进来。

/// 核心认的键码（和 X11 keysym 取值一样）。
public enum Keysym {
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
    public static let shiftLeft: UInt32 = 0xffe1
    public static let shiftRight: UInt32 = 0xffe2
    public static let delete: UInt32 = 0xffff
}

/// 核心的修饰键位掩码（WOWTYPE_MOD_*）。
public struct Modifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let caps = Modifiers(rawValue: 1 << 1)
    public static let control = Modifiers(rawValue: 1 << 2)
    public static let option = Modifiers(rawValue: 1 << 3)
    public static let command = Modifiers(rawValue: 1 << 6)

    /// NSEvent.ModifierFlags 的原始值 → 核心的掩码（不引 AppKit，直接按位取）。
    public init(cocoaFlags flags: UInt) {
        var m: Modifiers = []
        if flags & (1 << 16) != 0 { m.insert(.caps) }
        if flags & (1 << 17) != 0 { m.insert(.shift) }
        if flags & (1 << 18) != 0 { m.insert(.control) }
        if flags & (1 << 19) != 0 { m.insert(.option) }
        if flags & (1 << 20) != 0 { m.insert(.command) }
        self = m
    }
}

/// macOS 的虚拟键码（Carbon kVK_*），只列用到的。
public enum VirtualKey {
    public static let returnKey: UInt16 = 0x24
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let backspace: UInt16 = 0x33
    public static let escape: UInt16 = 0x35
    public static let shiftLeft: UInt16 = 0x38
    public static let shiftRight: UInt16 = 0x3C
    public static let keypadEnter: UInt16 = 0x4C
    public static let home: UInt16 = 0x73
    public static let pageUp: UInt16 = 0x74
    public static let forwardDelete: UInt16 = 0x75
    public static let end: UInt16 = 0x77
    public static let pageDown: UInt16 = 0x79
    public static let left: UInt16 = 0x7B
    public static let right: UInt16 = 0x7C
    public static let down: UInt16 = 0x7D
    public static let up: UInt16 = 0x7E
}

/// 一次按键，已经翻译成核心的键码。
public struct KeyInput: Equatable, Sendable {
    public var keysym: UInt32
    public var modifiers: Modifiers
    public var release: Bool

    public init(keysym: UInt32, modifiers: Modifiers = [], release: Bool = false) {
        self.keysym = keysym
        self.modifiers = modifiers
        self.release = release
    }

    /// 可见的 ASCII 字符（字母、数字、标点、空格）；功能键为 nil。
    public var ascii: UInt8? {
        keysym >= 0x20 && keysym <= 0x7e ? UInt8(keysym) : nil
    }

    public var isLetter: Bool {
        guard let c = ascii else { return false }
        return (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a)
    }

    public var isDigit: Bool {
        guard let c = ascii else { return false }
        return c >= 0x30 && c <= 0x39
    }

    public static func char(_ c: Character, _ modifiers: Modifiers = []) -> KeyInput {
        KeyInput(keysym: c.unicodeScalars.first.map { $0.value } ?? 0, modifiers: modifiers)
    }

    public static func key(_ keysym: UInt32, _ modifiers: Modifiers = []) -> KeyInput {
        KeyInput(keysym: keysym, modifiers: modifiers)
    }
}

/// NSEvent 的 keyDown → KeyInput。characters 是考虑了 Shift 的字符（Shift+1 是「!」），
/// 带 Control / Option / Command 时用 charactersIgnoringModifiers，免得拿到 Option 组合出来的特殊字符。
public func translateKeyDown(keyCode: UInt16, characters: String?, charactersIgnoringModifiers: String?,
                             cocoaFlags: UInt) -> KeyInput? {
    let modifiers = Modifiers(cocoaFlags: cocoaFlags)
    let special: UInt32? = {
        switch keyCode {
        case VirtualKey.returnKey: return Keysym.returnKey
        case VirtualKey.keypadEnter: return Keysym.keypadEnter
        case VirtualKey.tab: return Keysym.tab
        case VirtualKey.space: return 0x20
        case VirtualKey.backspace: return Keysym.backspace
        case VirtualKey.forwardDelete: return Keysym.delete
        case VirtualKey.escape: return Keysym.escape
        case VirtualKey.left: return Keysym.left
        case VirtualKey.right: return Keysym.right
        case VirtualKey.up: return Keysym.up
        case VirtualKey.down: return Keysym.down
        case VirtualKey.pageUp: return Keysym.pageUp
        case VirtualKey.pageDown: return Keysym.pageDown
        case VirtualKey.home: return Keysym.home
        case VirtualKey.end: return Keysym.end
        default: return nil
        }
    }()
    if let special {
        return KeyInput(keysym: special, modifiers: modifiers)
    }
    let plain = modifiers.isDisjoint(with: [.control, .option, .command])
    let text = plain ? characters : charactersIgnoringModifiers
    guard let scalar = text?.unicodeScalars.first, text?.unicodeScalars.count == 1,
          scalar.value >= 0x20, scalar.value <= 0x7e
    else {
        return nil
    }
    return KeyInput(keysym: scalar.value, modifiers: modifiers)
}

/// 单按 Shift 切中英文：按下 Shift 到松开之间没有按别的键，并且不超过 0.5 秒。
/// macOS 上 Shift 只有 flagsChanged 事件，没有 keyDown / keyUp。
public struct ShiftTap {
    private var downAt: Double?
    public var limit: Double = 0.5

    public init() {}

    /// Shift 的 flagsChanged：down 是按下（flags 里有 shift）。返回 true 表示这一次是单按。
    public mutating func shift(down: Bool, otherModifiers: Bool, now: Double) -> Bool {
        if down {
            downAt = otherModifiers ? nil : now
            return false
        }
        defer { downAt = nil }
        guard let at = downAt else { return false }
        return now - at <= limit
    }

    /// 别的键按下、别的修饰键变化：这一次就不算单按了。
    public mutating func interrupt() {
        downAt = nil
    }
}
