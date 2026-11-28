// 开发者模式的打字记录（docs/DEVLOG.md）：默认关（wowtype.conf 的 DeveloperMode）。开着时核心把每次上屏
// 明文记进数据目录的 devlog.jsonl（打的原始输入、光标前的上文、当时的候选、选了第几个），只有输入法写；
// 设置窗口只看条数和大小、导出、清空。和 Linux 设置界面的 devlog_summary / export_devlog / clear_devlog 一样。
// 这里不依赖 AppKit，Linux 上的按键测试也能编译。
import Foundation
import CWowtype

public enum DevLog {
    public static let fileName = "devlog.jsonl"

    /// 打开开关前要用户确认的话（三端一样，Linux 是 DEVLOG_WARNING）。
    public static let warning = """
        打开以后，WowType 会把你打的字明文记在这台电脑上：每次上屏的拼音、光标前的几个字、当时的候选、选了第几个，还有在哪个应用里打的。

        密码框里的不记；但终端里的密码提示这类没有标成密码框的地方，在中文模式下打的密码会被记下来。

        记录只存在本机，不上传，「复制诊断信息」也不带它。调试完请关掉，并清空记录。
        """

    public static let info = "调排序用：记下每次上屏打的拼音、当时的候选和选了第几个，放弃的、上屏后马上退格的也记。"
        + "用 tools/devlog.py 看汇总、转成评测用例。默认关，记录是明文的。"

    /// 按设置打开或关上（输入法进程里调；整个进程一份）。
    public static func apply(enabled: Bool, path: String) {
        if enabled {
            _ = wowtype_devlog_configure(path, 1)
        } else {
            _ = wowtype_devlog_configure(nil, 0)
        }
    }

    /// 现在在哪个应用里打字（bundle id），记在每条记录里。
    public static func setApp(_ name: String) {
        wowtype_devlog_set_app(name)
    }

    /// 记录文件，旧的在前（换下来的 .1、现在的）；只列存在的。
    public static func files(_ path: String) -> [String] {
        [path + ".1", path].filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// 有多少条（一行一条）、一共多大。
    public static func summary(_ path: String) -> (count: Int, bytes: Int) {
        var count = 0
        var bytes = 0
        for file in files(path) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { continue }
            bytes += data.count
            count += data.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 }
        }
        return (count, bytes)
    }

    /// 清空：删掉记录和换下来的旧文件（核心的 devlog::clear）。输入法开着关着都行。
    public static func clear(path: String) -> Bool {
        wowtype_devlog_clear(path) == 0
    }

    /// 把记录（旧的在前）合成一个文件存到 dest，只有自己能读。返回条数。
    @discardableResult
    public static func export(from path: String, to dest: String) throws -> Int {
        var all = Data()
        for file in files(path) {
            all.append(try Data(contentsOf: URL(fileURLWithPath: file)))
        }
        try all.write(to: URL(fileURLWithPath: dest), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest)
        return all.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 }
    }

    public static func sizeText(_ bytes: Int) -> String {
        bytes >= 1_000_000
            ? String(format: "%.1f MB", Double(bytes) / 1e6)
            : String(format: "%.1f KB", max(Double(bytes) / 1e3, 0.1))
    }

    /// 「打字记录」那一行的副标题。
    public static func statusText(path: String, enabled: Bool) -> String {
        let (count, bytes) = summary(path)
        if count > 0 {
            return "\(count) 条，\(sizeText(bytes))" + (enabled ? "" : "（开发者模式关着，不再记新的）")
        }
        return enabled ? "还没有记录" : "开发者模式关着，什么都不记"
    }
}
