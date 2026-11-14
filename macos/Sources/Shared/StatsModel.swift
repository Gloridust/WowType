// 打字统计的读取和派生指标：和 core/src/stats.rs 的口径一致。
//
// 输入法只写聚合计数，不保存文字；设置页读同一个 JSON。这里不依赖 AppKit，
// Linux 上的按键测试也能编译。
import Foundation

public struct StatsDay: Equatable {
    public var chars = 0
    public var han = 0
    public var latin = 0
    public var number = 0
    public var punct = 0
    public var emoji = 0
    public var other = 0
    public var activeMs = 0
    public var keys: [String: Int] = [:]
    public var sources: [String: Int] = [:]
    public var schemes: [String: Int] = [:]
    public var selections = [Int](repeating: 0, count: 9)
    public var beyond = 0

    /// 速度的分子：汉字与字母。
    public var readable: Int { han + latin }
}

public struct StatsDocument: Equatable {
    public var enabled = true
    public var generation: Int = 0
    public var lastCommitMs: Int = 0
    public var days: [String: StatsDay] = [:]
}

public struct StatsMetrics {
    public var todayChars = 0
    public var todayActive = 0
    public var todaySpeed = 0.0
    public var totalChars = 0
    public var totalActive = 0
    public var averageSpeed = 0.0
    public var recordedDays = 0
    public var averagePerDay = 0.0
    public var bestDay: String?
    public var bestChars = 0
    public var fastestDay: String?
    public var fastestSpeed = 0.0
    public var streak = 0
    public var longestStreak = 0
}

public enum StatsStore {
    /// 一天里最快的速度至少要有 1 分钟活跃时间，避免几秒钟的输入霸榜。
    static let fastestDayMinimumMs = 60_000

    public static func load(_ path: String) -> StatsDocument {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return StatsDocument()
        }
        var document = StatsDocument()
        document.enabled = (root["enabled"] as? Bool) ?? true
        document.generation = integer(root["generation"])
        document.lastCommitMs = integer(root["lastCommitMs"])
        for (day, value) in (root["days"] as? [String: Any]) ?? [:] {
            guard day.count == 10, let value = value as? [String: Any] else { continue }
            document.days[day] = parseDay(value)
        }
        return document
    }

    /// 只写开关/清空用；days 保持传进来的值。
    public static func save(_ document: StatsDocument, to path: String) throws {
        var days: [String: Any] = [:]
        for (day, value) in document.days {
            days[day] = encodeDay(value)
        }
        let root: [String: Any] = [
            "version": 1,
            "enabled": document.enabled,
            "generation": document.generation,
            "lastCommitMs": document.lastCommitMs,
            "days": days,
        ]
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func setEnabled(_ enabled: Bool, path: String) throws {
        var document = load(path)
        document.enabled = enabled
        try save(document, to: path)
    }

    /// 清空只换一个代号、删掉记录；输入法攒着没写的旧计数发现代号变了会丢掉。
    public static func clear(path: String, enabled: Bool) throws {
        var document = load(path)
        document.enabled = enabled
        document.generation = Int.random(in: 1...Int.max)
        document.lastCommitMs = 0
        document.days = [:]
        try save(document, to: path)
    }

    private static func parseDay(_ value: [String: Any]) -> StatsDay {
        var day = StatsDay()
        day.chars = integer(value["chars"])
        if let kinds = value["kinds"] as? [String: Any] {
            day.han = integer(kinds["han"])
            day.latin = integer(kinds["latin"])
            day.number = integer(kinds["number"])
            day.punct = integer(kinds["punct"])
            day.emoji = integer(kinds["emoji"])
            day.other = integer(kinds["other"])
        }
        day.activeMs = integer(value["activeMs"])
        day.keys = map(value["keys"])
        day.sources = map(value["sources"])
        day.schemes = map(value["schemes"])
        if let ranks = value["selections"] as? [Any] {
            for (index, rank) in ranks.prefix(9).enumerated() {
                day.selections[index] = integer(rank)
            }
        }
        day.beyond = integer(value["beyond"])
        return day
    }

    private static func encodeDay(_ day: StatsDay) -> [String: Any] {
        [
            "chars": day.chars,
            "kinds": ["han": day.han, "latin": day.latin, "number": day.number,
                      "punct": day.punct, "emoji": day.emoji, "other": day.other],
            "activeMs": day.activeMs,
            "keys": day.keys,
            "sources": day.sources,
            "schemes": day.schemes,
            "selections": day.selections,
            "beyond": day.beyond,
        ]
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return max(0, value) }
        if let value = value as? Double { return max(0, Int(value)) }
        if let value = value as? NSNumber { return max(0, value.intValue) }
        return 0
    }

    private static func map(_ value: Any?) -> [String: Int] {
        guard let value = value as? [String: Any] else { return [:] }
        var out: [String: Int] = [:]
        for (key, count) in value {
            out[key] = integer(count)
        }
        return out
    }
}

// MARK: 日期和指标

public enum StatsMath {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func dayKey(_ date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    public static func shift(_ key: String, days: Int) -> String {
        guard let date = dayFormatter.date(from: key),
              let shifted = Calendar.current.date(byAdding: .day, value: days, to: date)
        else { return key }
        return dayFormatter.string(from: shifted)
    }

    public static func cpm(_ characters: Int, _ activeMs: Int) -> Double {
        guard characters > 0, activeMs > 0 else { return 0 }
        return Double(characters) / (Double(activeMs) / 60_000)
    }

    public static func formatActive(_ milliseconds: Int) -> String {
        guard milliseconds > 0 else { return "0分" }
        let minutes = milliseconds / 60_000
        if minutes == 0 { return "\(max(1, (milliseconds + 500) / 1000))秒" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)分" }
        return rest == 0 ? "\(hours)小时" : "\(hours)小时\(rest)分"
    }

    public static func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]) else {
            return key
        }
        return "\(month)月\(day)日"
    }

    public static func metrics(_ document: StatsDocument, today: String = dayKey()) -> StatsMetrics {
        let recorded = document.days.keys.sorted()
        var metrics = StatsMetrics()
        metrics.recordedDays = recorded.count
        var totalReadable = 0
        for key in recorded {
            guard let day = document.days[key] else { continue }
            metrics.totalChars += day.chars
            if day.activeMs > 0 {
                metrics.totalActive += day.activeMs
                totalReadable += day.readable
            }
            if day.chars > metrics.bestChars {
                metrics.bestChars = day.chars
                metrics.bestDay = key
            }
            if day.activeMs >= StatsStore.fastestDayMinimumMs {
                let speed = cpm(day.readable, day.activeMs)
                if speed > metrics.fastestSpeed {
                    metrics.fastestSpeed = speed
                    metrics.fastestDay = key
                }
            }
        }
        let todayDay = document.days[today]
        metrics.todayChars = todayDay?.chars ?? 0
        metrics.todayActive = todayDay?.activeMs ?? 0
        metrics.todaySpeed = cpm(todayDay?.readable ?? 0, metrics.todayActive)
        metrics.averageSpeed = cpm(totalReadable, metrics.totalActive)
        metrics.averagePerDay = recorded.isEmpty ? 0 : Double(metrics.totalChars) / Double(recorded.count)
        metrics.streak = currentStreak(recorded, today: today)
        metrics.longestStreak = longestStreak(recorded)
        return metrics
    }

    public static func currentStreak(_ recorded: [String], today: String) -> Int {
        let present = Set(recorded)
        var cursor = present.contains(today) ? today : shift(today, days: -1)
        var streak = 0
        while present.contains(cursor) {
            streak += 1
            cursor = shift(cursor, days: -1)
        }
        return streak
    }

    public static func longestStreak(_ recorded: [String]) -> Int {
        var longest = 0
        var run = 0
        var previous: String?
        for day in recorded {
            if let previous, shift(previous, days: 1) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        return longest
    }

    public static func recentDays(_ document: StatsDocument, length: Int = 30,
                                  today: String = dayKey()) -> [(key: String, count: Int)] {
        (0..<length).map { offset in
            let key = shift(today, days: offset - length + 1)
            return (key, document.days[key]?.chars ?? 0)
        }
    }
}

// MARK: 键盘热力图

public struct StatsKey: Identifiable {
    public let code: String?
    public let label: String
    public let weight: Double
    public var id: String { code ?? "spacer-\(label)-\(weight)" }

    public init(_ code: String?, _ label: String, _ weight: Double) {
        self.code = code
        self.label = label
        self.weight = weight
    }
}

public enum StatsKeyboard {
    public static let unit = 36.0

    public static let names: [String: String] = [
        "Escape": "Esc", "Backquote": "`", "Minus": "-", "Equal": "=",
        "BracketLeft": "[", "BracketRight": "]", "Backslash": "\\",
        "Semicolon": ";", "Quote": "'", "Comma": ",", "Period": ".", "Slash": "/",
        "Backspace": "Backspace", "Tab": "Tab", "CapsLock": "Caps Lock", "Enter": "Enter",
        "ShiftLeft": "Shift", "ShiftRight": "Shift",
        "ControlLeft": "Ctrl", "ControlRight": "Ctrl",
        "AltLeft": "Option", "AltRight": "Option",
        "MetaLeft": "⌘", "MetaRight": "⌘",
        "ContextMenu": "Menu", "Space": "Space",
        "ArrowLeft": "左箭头", "ArrowRight": "右箭头", "ArrowUp": "上箭头", "ArrowDown": "下箭头",
        "Home": "Home", "End": "End", "PageUp": "Page Up", "PageDown": "Page Down",
        "Insert": "Insert", "Delete": "Delete", "NumLock": "Num Lock",
        "NumpadEnter": "小键盘回车", "NumpadAdd": "小键盘 +", "NumpadSubtract": "小键盘 -",
        "NumpadMultiply": "小键盘 *", "NumpadDivide": "小键盘 /", "NumpadDecimal": "小键盘 .",
        "Fn": "Fn", "IntlBackslash": "ISO \\", "IntlRo": "ろ", "IntlYen": "¥",
    ]

    public static func name(_ code: String) -> String {
        if let name = names[code] { return name }
        if code.count == 4, code.hasPrefix("Key") { return String(code.suffix(1)) }
        if code.hasPrefix("Digit"), code.count == 6 { return String(code.suffix(1)) }
        if code.hasPrefix("Numpad"), code.count == 7, let last = code.last, last.isNumber {
            return "小键盘 \(last)"
        }
        if code.hasPrefix("F"), code.dropFirst().allSatisfy(\.isNumber) { return code }
        return code
    }

    public static var rows: [[StatsKey]] {
        var rows: [[StatsKey]] = []
        rows.append([StatsKey("Escape", "Esc", 1), StatsKey(nil, "", 1)]
            + (1...4).map { StatsKey("F\($0)", "F\($0)", 1) }
            + [StatsKey(nil, "", 0.5)]
            + (5...8).map { StatsKey("F\($0)", "F\($0)", 1) }
            + [StatsKey(nil, "", 0.5)]
            + (9...12).map { StatsKey("F\($0)", "F\($0)", 1) })
        rows.append([StatsKey("Backquote", "`", 1)]
            + (1...9).map { StatsKey("Digit\($0)", "\($0)", 1) }
            + [StatsKey("Digit0", "0", 1), StatsKey("Minus", "-", 1),
               StatsKey("Equal", "=", 1), StatsKey("Backspace", "Backspace", 2)])
        rows.append([StatsKey("Tab", "Tab", 1.5)]
            + "QWERTYUIOP".map { StatsKey("Key\($0)", String($0), 1) }
            + [StatsKey("BracketLeft", "[", 1), StatsKey("BracketRight", "]", 1),
               StatsKey("Backslash", "\\", 1.5)])
        rows.append([StatsKey("CapsLock", "Caps Lock", 1.75)]
            + "ASDFGHJKL".map { StatsKey("Key\($0)", String($0), 1) }
            + [StatsKey("Semicolon", ";", 1), StatsKey("Quote", "'", 1),
               StatsKey("Enter", "Enter", 2.25)])
        rows.append([StatsKey("ShiftLeft", "Shift", 2.25)]
            + "ZXCVBNM".map { StatsKey("Key\($0)", String($0), 1) }
            + [StatsKey("Comma", ",", 1), StatsKey("Period", ".", 1),
               StatsKey("Slash", "/", 1), StatsKey("ShiftRight", "Shift", 2.75)])
        rows.append([StatsKey("ControlLeft", "Ctrl", 1.25), StatsKey("MetaLeft", "⌘", 1.25),
                     StatsKey("AltLeft", "Option", 1.25), StatsKey("Space", "Space", 6.25),
                     StatsKey("AltRight", "Option", 1.25), StatsKey("MetaRight", "⌘", 1.25),
                     StatsKey("ContextMenu", "Menu", 1.25),
                     StatsKey("ControlRight", "Ctrl", 1.25)])
        return rows
    }

    public static var drawnCodes: Set<String> {
        Set(rows.flatMap { $0 }.compactMap(\.code))
    }

    public static func totals(_ document: StatsDocument) -> [String: Int] {
        var counts: [String: Int] = [:]
        for day in document.days.values {
            for (code, count) in day.keys {
                counts[code, default: 0] += count
            }
        }
        return counts
    }

    public static func level(_ count: Int, maximum: Int) -> Int {
        guard count > 0, maximum > 0 else { return 0 }
        return max(1, min(4, (count * 4 + maximum - 1) / maximum))
    }
}

public struct KeyCount: Identifiable {
    public let code: String
    public let count: Int
    public var id: String { code }

    public init(code: String, count: Int) {
        self.code = code
        self.count = count
    }
}

/// 所有记录日合并后的分类、来源、方案和候选位置。
public struct StatsTotals {
    public var kinds: [String: Int] = [:]
    public var sources: [String: Int] = [:]
    public var schemes: [String: Int] = [:]
    public var selections = [Int](repeating: 0, count: 9)
    public var beyond = 0

    public var characters: Int { kinds.values.reduce(0, +) }
}

public extension StatsStore {
    static func totals(_ document: StatsDocument) -> StatsTotals {
        var totals = StatsTotals()
        for day in document.days.values {
            totals.kinds["han", default: 0] += day.han
            totals.kinds["latin", default: 0] += day.latin
            totals.kinds["number", default: 0] += day.number
            totals.kinds["punct", default: 0] += day.punct
            totals.kinds["emoji", default: 0] += day.emoji
            totals.kinds["other", default: 0] += day.other
            for (key, count) in day.sources {
                totals.sources[key, default: 0] += count
            }
            for (key, count) in day.schemes {
                totals.schemes[key, default: 0] += count
            }
            for (index, count) in day.selections.enumerated() where index < totals.selections.count {
                totals.selections[index] += count
            }
            totals.beyond += day.beyond
        }
        return totals
    }
}
