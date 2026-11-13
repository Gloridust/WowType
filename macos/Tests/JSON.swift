// 读设置契约（spec/*.json）用的小 JSON 解析器。测试要在 Linux 上也能编，不用 Foundation 的 JSONSerialization。

enum JSON {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    /// 解析整段文本；格式不对是 nil。
    static func parse(_ text: String) -> JSON? {
        var parser = JSONParser(bytes: Array(text.utf8))
        guard let value = parser.value() else { return nil }
        parser.skipSpace()
        return parser.at == parser.bytes.count ? value : nil
    }

    subscript(key: String) -> JSON? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var int: Int? {
        if case .number(let n) = self, n == n.rounded(), abs(n) < 1e15 { return Int(n) }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var array: [JSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var object: [String: JSON]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var at = 0

    mutating func skipSpace() {
        while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x09 || bytes[at] == 0x0a || bytes[at] == 0x0d {
            at += 1
        }
    }

    mutating func value() -> JSON? {
        skipSpace()
        guard at < bytes.count else { return nil }
        switch bytes[at] {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string().map(JSON.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return number()
        }
    }

    private mutating func literal(_ word: String, _ value: JSON) -> JSON? {
        let w = Array(word.utf8)
        guard at + w.count <= bytes.count, Array(bytes[at..<at + w.count]) == w else { return nil }
        at += w.count
        return value
    }

    private mutating func number() -> JSON? {
        let start = at
        while at < bytes.count, "-+.eE0123456789".utf8.contains(bytes[at]) {
            at += 1
        }
        guard at > start, let n = Double(String(decoding: bytes[start..<at], as: UTF8.self)) else { return nil }
        return .number(n)
    }

    /// at 指着开头的引号。
    private mutating func string() -> String? {
        at += 1
        var out: [UInt8] = []
        while at < bytes.count {
            let c = bytes[at]
            at += 1
            if c == UInt8(ascii: "\"") {
                return String(decoding: out, as: UTF8.self)
            }
            if c != UInt8(ascii: "\\") {
                out.append(c)
                continue
            }
            guard at < bytes.count else { return nil }
            let e = bytes[at]
            at += 1
            switch e {
            case UInt8(ascii: "n"): out.append(0x0a)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0d)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0c)
            case UInt8(ascii: "u"):
                guard var code = hex4() else { return nil }
                if (0xD800..<0xDC00).contains(code) {
                    // 代理对：后面得紧跟 \uDC00–\uDFFF
                    guard at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u")
                    else { return nil }
                    at += 2
                    guard let low = hex4(), (0xDC00..<0xE000).contains(low) else { return nil }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(code) else { return nil }
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                out.append(e) // \" \\ \/
            }
        }
        return nil
    }

    private mutating func hex4() -> UInt32? {
        guard at + 4 <= bytes.count,
              let v = UInt32(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16)
        else { return nil }
        at += 4
        return v
    }

    private mutating func array() -> JSON? {
        at += 1
        var items: [JSON] = []
        skipSpace()
        if at < bytes.count, bytes[at] == UInt8(ascii: "]") {
            at += 1
            return .array(items)
        }
        while true {
            guard let v = value() else { return nil }
            items.append(v)
            skipSpace()
            guard at < bytes.count else { return nil }
            if bytes[at] == UInt8(ascii: ",") {
                at += 1
            } else if bytes[at] == UInt8(ascii: "]") {
                at += 1
                return .array(items)
            } else {
                return nil
            }
        }
    }

    private mutating func object() -> JSON? {
        at += 1
        var members: [String: JSON] = [:]
        skipSpace()
        if at < bytes.count, bytes[at] == UInt8(ascii: "}") {
            at += 1
            return .object(members)
        }
        while true {
            skipSpace()
            guard at < bytes.count, bytes[at] == UInt8(ascii: "\""), let key = string() else { return nil }
            skipSpace()
            guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { return nil }
            at += 1
            guard let v = value() else { return nil }
            members[key] = v
            skipSpace()
            guard at < bytes.count else { return nil }
            if bytes[at] == UInt8(ascii: ",") {
                at += 1
            } else if bytes[at] == UInt8(ascii: "}") {
                at += 1
                return .object(members)
            } else {
                return nil
            }
        }
    }
}
