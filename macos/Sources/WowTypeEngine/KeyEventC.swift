// WowKeyEvent -> C 的 WowtypeKey。修饰键位只从头文件里的常量来；keysym 是 XKB 的标准值
// （WowTypeKit 的 XKeysym）。
import CWowTypeCore
import WowTypeKit

extension WowModifiers {
    /// 核心的修饰键位（WOWTYPE_MOD_*，和 X11 / fcitx5 一样）。小键盘不是修饰键，已经体现在 keysym 里。
    var cValue: UInt32 {
        var m: UInt32 = 0
        if contains(.shift) { m |= UInt32(WOWTYPE_MOD_SHIFT) }
        if contains(.capsLock) { m |= UInt32(WOWTYPE_MOD_CAPS) }
        if contains(.control) { m |= UInt32(WOWTYPE_MOD_CTRL) }
        if contains(.alt) { m |= UInt32(WOWTYPE_MOD_ALT) }
        if contains(.super) { m |= UInt32(WOWTYPE_MOD_SUPER) }
        return m
    }
}

extension WowKeyEvent {
    /// prev：光标前一个字符（不知道给 nil）。time_ms 只拿来算单按 Shift 的间隔，Unix 毫秒也行。
    func cValue(prev: Unicode.Scalar?) -> WowtypeKey {
        var key = WowtypeKey()
        key.size = UInt32(MemoryLayout<WowtypeKey>.size)
        key.keysym = XKeysym.of(self)
        key.modifiers = modifiers.cValue
        key.release = isRelease ? 1 : 0
        key.prev_char = prev?.value ?? 0
        key.time_ms = UInt64(max(timeMs, 0))
        return key
    }
}
