// 向系统登记输入法（install.sh 装好以后调用）。和 Squirrel 的做法一样：
// TISRegisterInputSource 登记安装包，TISEnableInputSource 打开，TISSelectInputSource 切过去。

import Carbon
import Foundation

enum Installer {
    static let bundleID = Bundle.main.bundleIdentifier ?? "io.github.gloridust.inputmethod.WowType"
    static var modeID: String { bundleID + ".Hans" }

    static func register() -> Bool {
        let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
        print(status == noErr ? "已登记 \(Bundle.main.bundleURL.path)" : "登记失败（\(status)）")
        return status == noErr
    }

    /// 这个安装包登记过的输入源（includeAllInstalled：没打开的也要列出来）。
    private static func sources() -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    private static func mode() -> TISInputSource? {
        sources().first { string($0, kTISPropertyInputSourceID) == modeID }
    }

    static func enable() -> Bool {
        guard let source = mode() else {
            print("没找到输入源 \(modeID)：先 --register，可能要等几秒或重新登录")
            return false
        }
        if bool(source, kTISPropertyInputSourceIsEnabled) {
            print("已经打开了")
            return true
        }
        let status = TISEnableInputSource(source)
        print(status == noErr ? "已打开 \(modeID)" : "打开失败（\(status)）")
        return status == noErr
    }

    static func select() -> Bool {
        guard let source = mode() else {
            print("没找到输入源 \(modeID)")
            return false
        }
        let status = TISSelectInputSource(source)
        print(status == noErr ? "已切到 WowType" : "切换失败（\(status)）")
        return status == noErr
    }

    static func disable() -> Bool {
        var ok = true
        for source in sources() where bool(source, kTISPropertyInputSourceIsEnabled) {
            ok = TISDisableInputSource(source) == noErr && ok
        }
        print(ok ? "已关闭" : "关闭失败")
        return ok
    }
}
