// 数据文件在哪。
//
// | 东西 | 位置 |
// |---|---|
// | 自带数据（只读） | WowType.app/Contents/Resources/ |
// | 设置、用户数据 | ~/Library/Application Support/WowType/ |
// | 词库快照 | ~/Library/Caches/<bundle id>/ |
//
// 自带数据可以被用户目录里的同名文件盖过（和 Linux 上 ~/.local/share 盖过 /usr/share 一样）；
// 安全模式下不看用户目录。资源一律按路径找，不用 SwiftPM 的 Bundle.module。
import Foundation

public struct DataPaths: Sendable, Equatable {
    public let resources: URL
    public let support: URL
    public let cache: URL

    public init(resources: URL, support: URL, cache: URL) {
        self.resources = resources
        self.support = support
        self.cache = cache
    }

    public static func standard(resources: URL, home: URL, bundleID: String) -> DataPaths {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return DataPaths(
            resources: resources,
            support: library.appendingPathComponent("Application Support/WowType", isDirectory: true),
            cache: library.appendingPathComponent("Caches/\(bundleID)", isDirectory: true))
    }

    public var config: URL { support.appendingPathComponent("wowtype.conf") }
    public var userDict: URL { support.appendingPathComponent("user.tsv") }
    public var history: URL { support.appendingPathComponent("history.tsv") }
    public var custom: URL { support.appendingPathComponent("custom.tsv") }
    /// 微信输入法的神经语言模型：不随 WowType 分发，用户自己放进来才有。
    public var nnlm: URL { support.appendingPathComponent("wetype/nlrgpt2_nnlm.bin") }

    /// 自带数据文件：先找用户目录，再找 Resources；都没有返回 nil。
    public func data(_ name: String, userOverrides: Bool = true) -> URL? {
        let candidates = userOverrides ? [support, resources] : [resources]
        return candidates.map { $0.appendingPathComponent(name) }.first(where: Self.isFile)
    }

    public static func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }
}
