// 设置文本（wowtype.conf 的格式）：一行 Key=Value，# 开头是注释，[节] 行忽略。
//
// 这里只管读写行，不知道有哪些键、默认值是什么：那些只在 Rust 的 config.rs 里，
// 前端第一次写文件用 wowtype_config_default_ini 给的全文。
// 改值时保留别的行（注释、顺序），同一个键只留一行。
public struct IniDocument: Sendable, Equatable {
    private var lines: [String]

    public init(text: String) {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        lines = parts
    }

    /// 全文，每行以换行结尾。
    public var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// 按出现顺序的键名（不重复）。
    public var keys: [String] {
        var seen = Set<String>()
        return lines.compactMap { Self.parse($0)?.key }.filter { seen.insert($0).inserted }
    }

    /// 同一个键写了几次时取最后一次（和核心读文件一样）。
    public func value(for key: String) -> String? {
        lines.reversed().lazy.compactMap { Self.parse($0) }.first { $0.key == key }?.value
    }

    public mutating func set(_ key: String, _ value: String) {
        let line = "\(key)=\(value)"
        var replaced = false
        var out: [String] = []
        for existing in lines {
            guard Self.parse(existing)?.key == key else { out.append(existing); continue }
            if !replaced { out.append(line); replaced = true }
        }
        if !replaced { out.append(line) }
        lines = out
    }

    private static func parse(_ raw: String) -> (key: String, value: String)? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("["),
              let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }
}

import Foundation
