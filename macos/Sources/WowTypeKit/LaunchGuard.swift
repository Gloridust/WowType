// 连续崩溃检测：10 秒内第 3 次启动就当作在崩溃循环里，这次用安全模式（不读用户数据）。
// 启动时刻记在一个小文件里（临时目录），读不懂的行忽略。参考鼠须管的 problematicLaunchDetected。
import Foundation

public struct LaunchGuard: Sendable {
    public let file: URL
    public let window: TimeInterval
    public let limit: Int

    public init(file: URL, window: TimeInterval = 10, limit: Int = 3) {
        self.file = file
        self.window = window
        self.limit = limit
    }

    /// 记下这次启动。返回 true 表示在崩溃循环里。
    public func recordLaunch(now: Date) -> Bool {
        let t = now.timeIntervalSince1970
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var recent = text.split(separator: "\n").compactMap { Double($0) }
            .filter { $0.isFinite && $0 <= t && t - $0 < window }
        recent.append(t)
        recent = Array(recent.suffix(limit))
        let out = recent.map { String($0) }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(out.utf8).write(to: file, options: .atomic)
        return recent.count >= limit
    }
}
