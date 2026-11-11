import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem
import Testing
@testable import WowTypeKit

// 按键翻译：NSEvent 的几个字段 -> 会话要的 WowKeyEvent。
// 常量都取自系统头文件（kVK_*、CGEventFlags、NX_DEVICE*），测试里不写魔数。

private let shift = CGEventFlags.maskShift.rawValue
private let control = CGEventFlags.maskControl.rawValue
private let option = CGEventFlags.maskAlternate.rawValue
private let command = CGEventFlags.maskCommand.rawValue
private let capsLock = CGEventFlags.maskAlphaShift.rawValue
private let numericPad = CGEventFlags.maskNumericPad.rawValue
private let function = CGEventFlags.maskSecondaryFn.rawValue
private let lShift = UInt64(NX_DEVICELSHIFTKEYMASK)
private let rShift = UInt64(NX_DEVICERSHIFTKEYMASK)
private let lCmd = UInt64(NX_DEVICELCMDKEYMASK)

private func down(_ code: Int, _ chars: String, _ ignoring: String? = nil, flags: UInt64 = 0) -> WowKeyEvent? {
    KeyTranslator.translate(
        MacKeyInput(kind: .keyDown, keyCode: UInt16(code), characters: chars,
                    charactersIgnoringModifiers: ignoring ?? chars, modifierFlags: flags),
        timeMs: 1_700_000_000_123, utcOffsetSeconds: 28800)
}

private func flags(_ code: Int, _ value: UInt64) -> WowKeyEvent? {
    KeyTranslator.translate(
        MacKeyInput(kind: .flagsChanged, keyCode: UInt16(code), characters: "",
                    charactersIgnoringModifiers: "", modifierFlags: value),
        timeMs: 5, utcOffsetSeconds: 0)
}

private func ev(_ key: WowKey, _ unicode: Unicode.Scalar? = nil, _ mods: WowModifiers = [],
                release: Bool = false, time: Int64 = 1_700_000_000_123, utc: Int32 = 28800) -> WowKeyEvent {
    WowKeyEvent(key: key, unicode: unicode.map { $0.value } ?? 0, modifiers: mods,
                isRelease: release, utcOffsetSeconds: utc, timeMs: time)
}

@Suite("按键翻译：打字的键")
struct CharacterKeyTests {
    @Test func letterCarriesItsCharacter() {
        #expect(down(kVK_ANSI_A, "a") == ev(.none, "a"))
    }

    @Test func shiftLetterIsUppercase() {
        #expect(down(kVK_ANSI_A, "A", "A", flags: shift) == ev(.none, "A", .shift))
    }

    @Test func spaceIsACharacter() {
        #expect(down(kVK_Space, " ") == ev(.none, " "))
    }

    @Test func mainRowDigitHasNoKeypadFlag() {
        #expect(down(kVK_ANSI_1, "1") == ev(.none, "1"))
    }

    @Test func punctuationCarriesItsCharacter() {
        #expect(down(kVK_ANSI_Comma, ",") == ev(.none, ","))
        #expect(down(kVK_ANSI_Quote, "'") == ev(.none, "'"))
        #expect(down(kVK_ANSI_Minus, "-") == ev(.none, "-"))
    }

    @Test func controlLetterFallsBackToIgnoringModifiers() {
        // Ctrl+a 的 characters 是控制字符 0x01，会话要的是 'a'。
        #expect(down(kVK_ANSI_A, "\u{01}", "a", flags: control) == ev(.none, "a", .control))
    }

    @Test func commandLetterKeepsCommand() {
        #expect(down(kVK_ANSI_C, "c", flags: command) == ev(.none, "c", .super))
    }

    @Test func optionLetterKeepsTypedCharacter() {
        #expect(down(kVK_ANSI_A, "å", "a", flags: option) == ev(.none, "å", .alt))
    }

    @Test func deadKeyWithoutCharacterIsOther() {
        #expect(down(kVK_ANSI_E, "", "e", flags: option) == ev(.other, nil, .alt))
    }

    @Test func capsLockIsReported() {
        #expect(down(kVK_ANSI_A, "A", "a", flags: capsLock) == ev(.none, "A", .capsLock))
    }

    @Test func timeAndZoneArePassedThrough() {
        let e = down(kVK_ANSI_A, "a")
        #expect(e?.timeMs == 1_700_000_000_123)
        #expect(e?.utcOffsetSeconds == 28800)
    }

    @Test func keyUpIsRelease() {
        let e = KeyTranslator.translate(
            MacKeyInput(kind: .keyUp, keyCode: UInt16(kVK_ANSI_A), characters: "a",
                        charactersIgnoringModifiers: "a", modifierFlags: 0),
            timeMs: 1, utcOffsetSeconds: 0)
        #expect(e == ev(.none, "a", release: true, time: 1, utc: 0))
    }
}

@Suite("按键翻译：具名键")
struct NamedKeyTests {
    @Test(arguments: [
        (kVK_Delete, "\u{7f}", WowKey.backspace),
        (kVK_ForwardDelete, "\u{F728}", .delete),
        (kVK_Return, "\r", .returnKey),
        (kVK_Escape, "\u{1b}", .escape),
        (kVK_Tab, "\t", .tab),
        (kVK_Home, "\u{F729}", .home),
        (kVK_End, "\u{F72B}", .end),
        (kVK_PageUp, "\u{F72C}", .pageUp),
        (kVK_PageDown, "\u{F72D}", .pageDown),
    ])
    func namedKeyHasNoCharacter(code: Int, chars: String, key: WowKey) {
        #expect(down(code, chars) == ev(key))
    }

    @Test func shiftTabIsTabWithShift() {
        #expect(down(kVK_Tab, "\u{19}", "\u{19}", flags: shift) == ev(.tab, nil, .shift))
    }

    @Test(arguments: [
        (kVK_LeftArrow, "\u{F702}", WowKey.left),
        (kVK_RightArrow, "\u{F703}", .right),
        (kVK_UpArrow, "\u{F700}", .up),
        (kVK_DownArrow, "\u{F701}", .down),
    ])
    func arrowsAreNotKeypadEvenWithNumericPadFlag(code: Int, chars: String, key: WowKey) {
        // macOS 给方向键带上 .numericPad 和 .function，它们不是小键盘。
        #expect(down(code, chars, flags: numericPad | function) == ev(key))
    }

    @Test func functionKeyIsOther() {
        #expect(down(kVK_F5, "\u{F708}", flags: function) == ev(.other))
    }

    @Test func unknownPrivateUseCharacterIsOther() {
        // 没在表里的功能键（字符落在 U+F700–U+F8FF）也是 OTHER，不能当字符交给会话。
        #expect(down(kVK_Help, "\u{F746}", flags: function) == ev(.other))
    }
}

@Suite("按键翻译：小键盘")
struct KeypadTests {
    @Test func keypadDigitHasKeypadFlag() {
        #expect(down(kVK_ANSI_Keypad1, "1", flags: numericPad) == ev(.none, "1", .keypad))
    }

    @Test func keypadDigitIsKeypadEvenWithoutFlag() {
        // 判断只看键码，不看 .numericPad。
        #expect(down(kVK_ANSI_Keypad7, "7") == ev(.none, "7", .keypad))
    }

    @Test(arguments: [
        (kVK_ANSI_KeypadPlus, "+"), (kVK_ANSI_KeypadMinus, "-"), (kVK_ANSI_KeypadMultiply, "*"),
        (kVK_ANSI_KeypadDivide, "/"), (kVK_ANSI_KeypadDecimal, "."), (kVK_ANSI_KeypadEquals, "="),
        (kVK_ANSI_Keypad0, "0"), (kVK_ANSI_Keypad9, "9"),
    ])
    func keypadOperators(code: Int, chars: String) {
        #expect(down(code, chars, flags: numericPad) == ev(.none, chars.unicodeScalars.first!, .keypad))
    }

    @Test func keypadEnterIsReturnWithKeypad() {
        #expect(down(kVK_ANSI_KeypadEnter, "\u{03}", flags: numericPad) == ev(.returnKey, nil, .keypad))
    }

    @Test func keypadClearIsOtherWithKeypad() {
        #expect(down(kVK_ANSI_KeypadClear, "\u{F739}", flags: numericPad) == ev(.other, nil, .keypad))
    }
}

@Suite("按键翻译：单独的修饰键（flagsChanged）")
struct ModifierKeyTests {
    @Test func leftShiftPressAndRelease() {
        #expect(flags(kVK_Shift, shift | lShift) == ev(.shiftL, nil, [], time: 5, utc: 0))
        #expect(flags(kVK_Shift, 0) == ev(.shiftL, nil, [], release: true, time: 5, utc: 0))
    }

    @Test func rightShiftPressWhileLeftHeld() {
        #expect(flags(kVK_RightShift, shift | lShift | rShift) == ev(.shiftR, nil, [], time: 5, utc: 0))
    }

    @Test func rightShiftReleaseWhileLeftStillHeld() {
        // 通用的 .shift 还在（左边按着），但右边的设备位没了：是右 Shift 松开。
        #expect(flags(kVK_RightShift, shift | lShift) == ev(.shiftR, nil, [], release: true, time: 5, utc: 0))
    }

    @Test func leftShiftReleaseWhileRightStillHeld() {
        #expect(flags(kVK_Shift, shift | rShift) == ev(.shiftL, nil, [], release: true, time: 5, utc: 0))
    }

    @Test func shiftWithoutDeviceBitsUsesGenericFlag() {
        // 有的程序合成的事件没有左右设备位。
        #expect(flags(kVK_Shift, shift) == ev(.shiftL, nil, [], time: 5, utc: 0))
        #expect(flags(kVK_RightShift, 0) == ev(.shiftR, nil, [], release: true, time: 5, utc: 0))
    }

    @Test func shiftPressReportsOtherHeldModifiers() {
        #expect(flags(kVK_Shift, shift | lShift | command | lCmd) == ev(.shiftL, nil, .super, time: 5, utc: 0))
    }

    @Test(arguments: [
        (kVK_Control, CGEventFlags.maskControl.rawValue, UInt64(NX_DEVICELCTLKEYMASK), WowKey.controlL),
        (kVK_RightControl, CGEventFlags.maskControl.rawValue, UInt64(NX_DEVICERCTLKEYMASK), .controlR),
        (kVK_Option, CGEventFlags.maskAlternate.rawValue, UInt64(NX_DEVICELALTKEYMASK), .altL),
        (kVK_RightOption, CGEventFlags.maskAlternate.rawValue, UInt64(NX_DEVICERALTKEYMASK), .altR),
        (kVK_Command, CGEventFlags.maskCommand.rawValue, UInt64(NX_DEVICELCMDKEYMASK), .superL),
        (kVK_RightCommand, CGEventFlags.maskCommand.rawValue, UInt64(NX_DEVICERCMDKEYMASK), .superR),
    ])
    func otherModifierKeys(code: Int, generic: UInt64, device: UInt64, key: WowKey) {
        #expect(flags(code, generic | device) == ev(key, nil, [], time: 5, utc: 0))
        #expect(flags(code, 0) == ev(key, nil, [], release: true, time: 5, utc: 0))
    }

    @Test func capsLockOnAndOff() {
        #expect(flags(kVK_CapsLock, capsLock) == ev(.capsLock, nil, [], time: 5, utc: 0))
        #expect(flags(kVK_CapsLock, 0) == ev(.capsLock, nil, [], release: true, time: 5, utc: 0))
    }

    @Test func fnAndUnknownKeyCodesAreIgnored() {
        #expect(flags(kVK_Function, function) == nil)
        // 远程桌面工具会发键码 0 的 flagsChanged。
        #expect(flags(0, shift) == nil)
    }
}
