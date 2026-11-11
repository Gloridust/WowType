// 按键翻译：NSEvent 的几个字段 -> 会话要的 WowKeyEvent。
//
// 要点：
// - 方向键、Home 这些键 macOS 也带 .numericPad / .function，所以「小键盘」只看键码（kVK_ANSI_Keypad*）。
// - flagsChanged 按键码分左右，按下还是松开看这个键自己的设备位（NX_DEVICE*）；
//   没有设备位的合成事件退回看通用位。
// - Fn 和不认识的键码（远程桌面工具会发键码 0）的 flagsChanged 不交给会话。
import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem

public enum KeyTranslator {
    public static func translate(_ input: MacKeyInput, timeMs: Int64, utcOffsetSeconds: Int32) -> WowKeyEvent? {
        switch input.kind {
        case .flagsChanged:
            return modifierKey(input, timeMs: timeMs, utcOffsetSeconds: utcOffsetSeconds)
        case .keyDown, .keyUp:
            return ordinaryKey(input, timeMs: timeMs, utcOffsetSeconds: utcOffsetSeconds)
        }
    }

    // MARK: - 普通按键

    private static let namedKeys: [Int: WowKey] = [
        kVK_Delete: .backspace,
        kVK_ForwardDelete: .delete,
        kVK_Return: .returnKey,
        kVK_ANSI_KeypadEnter: .returnKey,
        kVK_Escape: .escape,
        kVK_Tab: .tab,
        kVK_LeftArrow: .left,
        kVK_RightArrow: .right,
        kVK_UpArrow: .up,
        kVK_DownArrow: .down,
        kVK_Home: .home,
        kVK_End: .end,
        kVK_PageUp: .pageUp,
        kVK_PageDown: .pageDown,
    ]

    private static let keypadKeys: Set<Int> = [
        kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
        kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear,
        kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals,
    ]

    private static func ordinaryKey(_ input: MacKeyInput, timeMs: Int64, utcOffsetSeconds: Int32) -> WowKeyEvent {
        let code = Int(input.keyCode)
        var mods = heldModifiers(input.modifierFlags)
        if keypadKeys.contains(code) { mods.insert(.keypad) }

        let key: WowKey
        var unicode: UInt32 = 0
        if let named = namedKeys[code] {
            key = named
        } else if let scalar = typedScalar(input) {
            key = .none
            unicode = scalar.value
        } else {
            key = .other
        }
        return WowKeyEvent(key: key, unicode: unicode, modifiers: mods, isRelease: input.kind == .keyUp,
                           utcOffsetSeconds: utcOffsetSeconds, timeMs: timeMs)
    }

    /// 这个键打出的字符。Ctrl 组合时 characters 是控制字符，改用 charactersIgnoringModifiers。
    /// characters 为空（死键，如 Option+e）时没有打出字符。
    /// 功能键的字符在私用区（U+F700–U+F8FF），不算打出的字符。
    private static func typedScalar(_ input: MacKeyInput) -> Unicode.Scalar? {
        guard let typed = input.characters.unicodeScalars.first else { return nil }
        if isFunctionKeyScalar(typed) { return nil }
        if !isControl(typed) { return typed }
        guard let base = input.charactersIgnoringModifiers.unicodeScalars.first,
              !isFunctionKeyScalar(base), !isControl(base) else { return nil }
        return base
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || s.value == 0x7F
    }

    private static func isFunctionKeyScalar(_ s: Unicode.Scalar) -> Bool {
        (0xF700...0xF8FF).contains(s.value)
    }

    // MARK: - 单独的修饰键

    private struct ModifierKeyInfo {
        let key: WowKey
        let generic: UInt64
        /// 这个键自己的设备位；Caps Lock 没有，填 0。
        let device: UInt64
        /// 同一类左右两个键的设备位（用来判断事件里有没有设备位）。
        let family: UInt64
        let own: WowModifiers
    }

    private static let shiftFamily = UInt64(NX_DEVICELSHIFTKEYMASK) | UInt64(NX_DEVICERSHIFTKEYMASK)
    private static let controlFamily = UInt64(NX_DEVICELCTLKEYMASK) | UInt64(NX_DEVICERCTLKEYMASK)
    private static let altFamily = UInt64(NX_DEVICELALTKEYMASK) | UInt64(NX_DEVICERALTKEYMASK)
    private static let commandFamily = UInt64(NX_DEVICELCMDKEYMASK) | UInt64(NX_DEVICERCMDKEYMASK)

    private static let modifierKeys: [Int: ModifierKeyInfo] = [
        kVK_Shift: .init(key: .shiftL, generic: CGEventFlags.maskShift.rawValue,
                         device: UInt64(NX_DEVICELSHIFTKEYMASK), family: shiftFamily, own: .shift),
        kVK_RightShift: .init(key: .shiftR, generic: CGEventFlags.maskShift.rawValue,
                              device: UInt64(NX_DEVICERSHIFTKEYMASK), family: shiftFamily, own: .shift),
        kVK_Control: .init(key: .controlL, generic: CGEventFlags.maskControl.rawValue,
                           device: UInt64(NX_DEVICELCTLKEYMASK), family: controlFamily, own: .control),
        kVK_RightControl: .init(key: .controlR, generic: CGEventFlags.maskControl.rawValue,
                                device: UInt64(NX_DEVICERCTLKEYMASK), family: controlFamily, own: .control),
        kVK_Option: .init(key: .altL, generic: CGEventFlags.maskAlternate.rawValue,
                          device: UInt64(NX_DEVICELALTKEYMASK), family: altFamily, own: .alt),
        kVK_RightOption: .init(key: .altR, generic: CGEventFlags.maskAlternate.rawValue,
                               device: UInt64(NX_DEVICERALTKEYMASK), family: altFamily, own: .alt),
        kVK_Command: .init(key: .superL, generic: CGEventFlags.maskCommand.rawValue,
                           device: UInt64(NX_DEVICELCMDKEYMASK), family: commandFamily, own: .super),
        kVK_RightCommand: .init(key: .superR, generic: CGEventFlags.maskCommand.rawValue,
                                device: UInt64(NX_DEVICERCMDKEYMASK), family: commandFamily, own: .super),
        kVK_CapsLock: .init(key: .capsLock, generic: CGEventFlags.maskAlphaShift.rawValue,
                            device: 0, family: 0, own: .capsLock),
    ]

    private static func modifierKey(_ input: MacKeyInput, timeMs: Int64, utcOffsetSeconds: Int32) -> WowKeyEvent? {
        guard let info = modifierKeys[Int(input.keyCode)] else { return nil }
        let flags = input.modifierFlags
        let pressed: Bool
        if info.family != 0, flags & info.family != 0 {
            pressed = flags & info.device != 0
        } else {
            pressed = flags & info.generic != 0
        }
        var mods = heldModifiers(flags)
        mods.remove(info.own)
        return WowKeyEvent(key: info.key, unicode: 0, modifiers: mods, isRelease: !pressed,
                           utcOffsetSeconds: utcOffsetSeconds, timeMs: timeMs)
    }

    // MARK: -

    private static func heldModifiers(_ flags: UInt64) -> WowModifiers {
        var mods: WowModifiers = []
        if flags & CGEventFlags.maskShift.rawValue != 0 { mods.insert(.shift) }
        if flags & CGEventFlags.maskControl.rawValue != 0 { mods.insert(.control) }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { mods.insert(.alt) }
        if flags & CGEventFlags.maskCommand.rawValue != 0 { mods.insert(.super) }
        if flags & CGEventFlags.maskAlphaShift.rawValue != 0 { mods.insert(.capsLock) }
        return mods
    }
}
