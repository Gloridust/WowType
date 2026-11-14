// 外壳测试的替身：假的输入框（IMKTextInput）、换掉 client() 的输入控制器、照真键盘造的 NSEvent。
//
// 输入控制器、AppState、候选框都是安装包里的真代码；假的只有 IMK 跨进程的那一段——应用那边的输入框
// （client() 本来是系统给的代理），和应用自己处理输入法不要的键（打出字母、退格删字）。

import AppKit
import Carbon
import InputMethodKit

/// 假的输入框：一段文字、编辑区（marked text）和光标，和 NSTextView 一样处理 IMK 的调用。
/// reliable 为 false 时像读不到光标前文字的应用（attributedSubstring 返回 nil）。
final class FakeTextInput: NSObject, IMKTextInput {
    let reliable: Bool
    private(set) var text = ""
    /// 编辑区在 text 里的范围（UTF-16）；没有时 location 是 NSNotFound
    private(set) var marked = NSRange(location: NSNotFound, length: 0)
    private(set) var selected = NSRange(location: 0, length: 0)
    /// 输入法上屏的每一段（insertText）
    private(set) var inserted: [String] = []
    /// 最后一次 setMarkedText 的属性（输入法给的下划线）
    private(set) var markedAttributes: [NSAttributedString.Key: Any] = [:]
    private(set) var lineRectRequests = 0

    init(reliable: Bool = true) {
        self.reliable = reliable
    }

    var markedText: String {
        marked.location == NSNotFound ? "" : (text as NSString).substring(with: marked)
    }

    /// 光标在编辑区里的位置（UTF-16）；没有编辑区时 nil
    var caretInMarked: Int? {
        marked.location == NSNotFound ? nil : selected.location - marked.location
    }

    var committed: String { inserted.joined() }

    private func replace(_ range: NSRange, with string: String) -> NSRange {
        text = (text as NSString).replacingCharacters(in: range, with: string)
        return NSRange(location: range.location, length: (string as NSString).length)
    }

    private var editRange: NSRange { marked.location != NSNotFound ? marked : selected }

    private func plain(_ string: Any!) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    func insertText(_ string: Any!, replacementRange: NSRange) {
        let s = plain(string)
        let range = replace(editRange, with: s)
        marked = NSRange(location: NSNotFound, length: 0)
        selected = NSRange(location: range.upperBound, length: 0)
        inserted.append(s)
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        let s = plain(string)
        markedAttributes = (string as? NSAttributedString).flatMap { $0.length > 0 ? $0.attributes(at: 0, effectiveRange: nil) : nil } ?? [:]
        let range = replace(editRange, with: s)
        marked = range.length > 0 ? range : NSRange(location: NSNotFound, length: 0)
        selected = NSRange(location: range.location + selectionRange.location, length: selectionRange.length)
    }

    func selectedRange() -> NSRange { selected }
    func markedRange() -> NSRange { marked }
    func length() -> Int { (text as NSString).length }

    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        guard reliable, range.location != NSNotFound, range.upperBound <= length() else { return nil }
        return NSAttributedString(string: (text as NSString).substring(with: range))
    }

    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        attributedSubstring(from: range)?.string
    }

    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        lineRectRequests += 1
        lineRect?.pointee = NSRect(x: 200, y: 600, width: 1, height: 18)
        return [:]
    }

    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect { .zero }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "io.github.gloridust.wowtype.shelltests.client" }
    func windowLevel() -> CGWindowLevel { CGWindowLevelForKey(.normalWindow) }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "shelltests-\(ObjectIdentifier(self).hashValue)" }

    /// 输入法没要的键：像应用一样处理（可见字符打进去、退格删光标前一个、左右键移光标）。
    func appHandles(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Delete:
            if selected.length > 0 {
                selected = replace(selected, with: "")
                selected.length = 0
            } else if selected.location > 0 {
                let r = (text as NSString).rangeOfComposedCharacterSequence(at: selected.location - 1)
                _ = replace(r, with: "")
                selected = NSRange(location: r.location, length: 0)
            }
        case kVK_LeftArrow:
            selected = NSRange(location: max(0, selected.location - 1), length: 0)
        case kVK_RightArrow:
            selected = NSRange(location: min(length(), selected.upperBound + 1), length: 0)
        case kVK_Return:
            selected = NSRange(location: replace(selected, with: "\n").upperBound, length: 0)
        default:
            guard event.modifierFlags.isDisjoint(with: [.control, .option, .command]),
                  let s = event.characters, let scalar = s.unicodeScalars.first, scalar.value >= 0x20, scalar.value < 0x7f
            else { return }
            selected = NSRange(location: replace(selected, with: s).upperBound, length: 0)
        }
    }
}

/// 真的输入控制器，只把 client() 换成假的输入框（系统里它是跨进程的代理）。
final class TestController: WowTypeInputController {
    var fake: FakeTextInput?

    override func client() -> (any IMKTextInput & NSObjectProtocol)! {
        fake
    }
}

// MARK: 按键

/// ANSI 键盘上可见字符的键码和要不要按 Shift。
private let keyTable: [Character: (Int, Bool)] = {
    var t: [Character: (Int, Bool)] = [:]
    let letters: [(Character, Int)] = [
        ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
        ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
        ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
        ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
        ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
        ("z", kVK_ANSI_Z),
    ]
    for (c, code) in letters {
        t[c] = (code, false)
        t[Character(c.uppercased())] = (code, true)
    }
    let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
                  kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    for (i, code) in digits.enumerated() { t[Character("\(i)")] = (code, false) }
    for (c, code, shift) in [(Character(")"), kVK_ANSI_0, true), ("!", kVK_ANSI_1, true), ("@", kVK_ANSI_2, true),
                             ("#", kVK_ANSI_3, true), ("$", kVK_ANSI_4, true), ("%", kVK_ANSI_5, true),
                             ("^", kVK_ANSI_6, true), ("&", kVK_ANSI_7, true), ("*", kVK_ANSI_8, true),
                             ("(", kVK_ANSI_9, true), ("-", kVK_ANSI_Minus, false), ("_", kVK_ANSI_Minus, true),
                             ("=", kVK_ANSI_Equal, false), ("+", kVK_ANSI_Equal, true),
                             ("[", kVK_ANSI_LeftBracket, false), ("]", kVK_ANSI_RightBracket, false),
                             (";", kVK_ANSI_Semicolon, false), ("'", kVK_ANSI_Quote, false),
                             (",", kVK_ANSI_Comma, false), (".", kVK_ANSI_Period, false),
                             ("/", kVK_ANSI_Slash, false), ("?", kVK_ANSI_Slash, true), (" ", kVK_Space, false)] {
        t[c] = (code, shift)
    }
    return t
}()

/// Shift 在 modifierFlags 里的样子（带设备位：左 Shift 0x2、右 Shift 0x4，和真键盘一样）
private let leftShiftFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x102)
private let rightShiftFlags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x104)
private let noFlags = NSEvent.ModifierFlags(rawValue: 0x100)

enum Key {
    case char(Character)
    case special(Int)
    case control(Character)
    /// Control + Shift + 这个键（字母写大写）
    case controlShift(Character)

    static let space = Key.special(kVK_Space)
    static let backspace = Key.special(kVK_Delete)
    static let escape = Key.special(kVK_Escape)
    static let left = Key.special(kVK_LeftArrow)
    static let right = Key.special(kVK_RightArrow)
    static let up = Key.special(kVK_UpArrow)
    static let down = Key.special(kVK_DownArrow)
    static let pageUp = Key.special(kVK_PageUp)
    static let pageDown = Key.special(kVK_PageDown)
}

/// 照真键盘造 keyDown：键码、characters、charactersIgnoringModifiers、修饰键都和按下这个键时一样。
func keyDown(_ key: Key) -> NSEvent {
    var code: Int
    var chars: String
    var ignoring: String
    var flags = noFlags
    switch key {
    case .char(let c):
        guard let (k, shift) = keyTable[c] else { fatalError("键表里没有 \(c)") }
        code = k
        chars = String(c)
        ignoring = String(c)
        if shift { flags = leftShiftFlags }
    case .control(let c):
        guard let (k, _) = keyTable[c] else { fatalError("键表里没有 \(c)") }
        code = k
        chars = c == " " ? "\u{0}" : String(UnicodeScalar(UInt8(c.asciiValue! & 0x1f)))
        ignoring = String(c)
        flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x101)
    case .controlShift(let c):
        // 按着 Shift：charactersIgnoringModifiers 是大写；Control 把 characters 变成控制字符
        guard let (k, _) = keyTable[c] else { fatalError("键表里没有 \(c)") }
        code = k
        chars = c == " " ? "\u{0}" : String(UnicodeScalar(UInt8(c.asciiValue! & 0x1f)))
        ignoring = String(c)
        flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue
                                      | NSEvent.ModifierFlags.shift.rawValue | 0x103)
    case .special(let k):
        code = k
        let function: [Int: Int] = [kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
                                    kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
                                    kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
                                    kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey]
        if let f = function[k] {
            chars = String(UnicodeScalar(UInt16(f))!)
            var raw = noFlags.rawValue | NSEvent.ModifierFlags.function.rawValue
            if k == kVK_LeftArrow || k == kVK_RightArrow || k == kVK_UpArrow || k == kVK_DownArrow {
                raw |= NSEvent.ModifierFlags.numericPad.rawValue
            }
            flags = NSEvent.ModifierFlags(rawValue: raw)
        } else {
            chars = [kVK_Space: " ", kVK_Delete: "\u{7f}", kVK_Escape: "\u{1b}", kVK_Return: "\r", kVK_Tab: "\t"][k] ?? ""
        }
        ignoring = chars
    }
    return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                            characters: chars, charactersIgnoringModifiers: ignoring, isARepeat: false,
                            keyCode: UInt16(code))!
}

/// Shift 按下或松开（flagsChanged），和真键盘一样带设备位。
func shiftEvent(down: Bool, right: Bool = false, at time: TimeInterval) -> NSEvent {
    NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                     modifierFlags: down ? (right ? rightShiftFlags : leftShiftFlags) : noFlags,
                     timestamp: time, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                     isARepeat: false, keyCode: UInt16(right ? kVK_RightShift : kVK_Shift))!
}
