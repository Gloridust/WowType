// 把 WowType.app 复制到 ~/Library/Input Methods。
//
// 不先删旧的：先复制到同一目录下的临时名字，复制完整了再一次换过去（replaceItemAt），
// 中途失败旧版本原样留着、临时文件清掉。参考 fcitx5-macos 删了一半装不上的教训。
// 安装分几步、按什么顺序在这里（installSteps）；注册输入源、关掉旧进程由输入法程序自己做。
import Foundation

public enum BundleInstaller {
    public static let bundleName = "WowType.app"

    public enum Failure: Error, Equatable {
        /// 要装的就是已经装好的那一份。
        case sameLocation
    }

    public enum InstallStep: Equatable, Sendable {
        /// 复制到 ~/Library/Input Methods（install(source:into:)）。
        case copy
        /// 关掉正在运行的旧进程。
        case quitRunning
        case register, enable, select
    }

    /// 安装的步骤和顺序。alreadyInPlace：程序已经在 ~/Library/Input Methods 里，不用复制。
    ///
    /// 关旧进程要放在新文件换好之后：系统按需从当时注册的 .app 启动输入法，在复制之前关掉的话，
    /// 复制的这段时间里它会从还没换的旧 .app 把旧版本再启动起来，一直用到注销。
    /// 参考 vChewing 的 9ba4c4fd（Retire stale instances after the payload lands）。
    public static func installSteps(alreadyInPlace: Bool) -> [InstallStep] {
        (alreadyInPlace ? [] : [.copy]) + [.quitRunning, .register, .enable, .select]
    }

    /// TISSelectInputSource 返回 -50（paramErr）：macOS 在等用户在系统设置里批准这个输入法
    /// （「允许 WowType 启用 WowType Pinyin？」）。这不是安装失败：装好了、启用了，只差用户点允许。
    /// 2026-11 首次安装实测：没批准时 select 就是 -50，批准后立刻可以选中。
    public static func selectStatusNeedsApproval(_ status: Int32) -> Bool { status == -50 }

    /// 装到 directory 里，返回装好的位置。
    @discardableResult
    public static func install(source: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let dest = directory.appendingPathComponent(bundleName, isDirectory: true)
        if resolved(source) == resolved(dest) { throw Failure.sameLocation }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let staging = directory.appendingPathComponent(".\(bundleName).staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: dest)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return dest
    }

    /// 删掉 directory 里的 WowType.app。返回 false 表示本来就没有。用户数据不动。
    @discardableResult
    public static func uninstall(from directory: URL) throws -> Bool {
        let dest = directory.appendingPathComponent(bundleName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dest.path) else { return false }
        try FileManager.default.removeItem(at: dest)
        return true
    }

    /// url 是不是就在 directory 里（解析 .. 和符号链接后比较）。
    public static func isInside(_ url: URL, directory: URL) -> Bool {
        resolved(url.deletingLastPathComponent()) == resolved(directory)
    }

    private static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
