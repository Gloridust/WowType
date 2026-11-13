// 可选词库包（万象拼音）：Release 上的 wowtype-data-wanxiang-<版本>.tar.gz。
// 规矩和 Linux 设置（settings/wowtype-config 的 install_lexicon_pack 等）一模一样：
// 包里只许有 lexicon.tsv、LICENSE、SOURCE.txt、VERSION 四个普通文件；lexicon.tsv 每行至少「拼音<TAB>词」，
// 少于 10 万条当成不完整；按 SHA256SUMS 校验，校验值重复、无效、缺失都不装；发布页上有好几个包时取版本最大的。
// 下载、解压在 App 层（LexiconPackInstaller），这里只放规矩，不依赖 Foundation，测试在 Linux 上也能跑。
// 规矩以 spec/lexicon-pack.json 为准：改了要先改规格，macos/test.sh 拿规格里的常量和例子对照。

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum LexiconPack {
    /// 包里只许有这几个文件
    public static let files: Set<String> = ["lexicon.tsv", "LICENSE", "SOURCE.txt", "VERSION"]
    /// lexicon.tsv 少于这么多条当成没下完整
    public static let minEntries = 100_000
    /// 数据目录下放万象的地方（Linux 是 ~/.local/share/wowtype/dicts/wanxiang）
    public static let folderName = "dicts/wanxiang"
    public static let assetPrefix = "wowtype-data-wanxiang-"
    public static let assetSuffix = ".tar.gz"
    /// 同一个发布页上的校验和文件
    public static let checksumFile = "SHA256SUMS"

    /// 发布页上的文件名是不是万象词库包，是的话给出版本（wowtype-data-wanxiang-<版本>.tar.gz，版本以数字开头）。
    public static func assetVersion(_ name: String) -> String? {
        guard name.hasPrefix(assetPrefix), name.hasSuffix(assetSuffix) else { return nil }
        let version = String(name.dropFirst(assetPrefix.count).dropLast(assetSuffix.count))
        guard let first = version.unicodeScalars.first, ("0"..."9").contains(first),
              version.unicodeScalars.allSatisfy({ isASCIIAlnum($0) || $0 == "." })
        else { return nil }
        return version
    }

    /// 发布页上的万象词库包：好几个时取版本最大的；没有是 nil。
    public static func pickAsset(_ names: [String]) -> (name: String, version: String)? {
        names.compactMap { name in assetVersion(name).map { (name: name, version: $0) } }
            .max { compareVersions($0.version, $1.version) < 0 }
    }

    /// 版本比大小，和 Linux 的 parse_version 一样按数字段逐段比，前面都一样时段多的大
    /// （2026.10.31.2 > 2026.10.31，1.0 > 1）。
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let x = versionParts(a), y = versionParts(b)
        for i in 0..<min(x.count, y.count) where x[i] != y[i] {
            return x[i] < y[i] ? -1 : 1
        }
        return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
    }

    private static func versionParts(_ v: String) -> [Int] {
        var parts: [Int] = []
        var current: Int?
        for s in v.unicodeScalars {
            if let d = Int(String(s)), ("0"..."9").contains(s) {
                current = (current ?? 0) * 10 + d
            } else if let c = current {
                parts.append(c)
                current = nil
            }
        }
        if let c = current { parts.append(c) }
        return parts
    }

    /// 从 SHA256SUMS 里取要的那些文件的校验值（小写）。重复或无效的条目整个不认（返回错误原因）。
    public static func checksums(_ text: String, wanted: Set<String>) -> Result<[String: String], PackError> {
        var sums: [String: String] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2 else { continue }
            let digest = String(fields[0])
            var name = String(fields[1])
            while name.hasPrefix(" ") || name.hasPrefix("\t") { name.removeFirst() }
            while name.hasSuffix(" ") || name.hasSuffix("\t") || name.hasSuffix("\r") { name.removeLast() }
            if name.hasPrefix("*") { name.removeFirst() }
            guard wanted.contains(name) else { continue }
            guard sums[name] == nil, digest.count == 64, digest.unicodeScalars.allSatisfy(isHexDigit) else {
                return .failure(PackError("SHA256SUMS 中 \(name) 的校验值重复或无效，不安装"))
            }
            sums[name] = digest.lowercased()
        }
        for name in wanted where sums[name] == nil {
            return .failure(PackError("SHA256SUMS 里没有 \(name)，不安装"))
        }
        return .success(sums)
    }

    /// 包里的一个条目（tar 列出来的名字）能不能解：去掉开头的 ./ 后得是四个文件之一。
    /// 返回去掉 ./ 的名字；"." 这类目录本身是 ""（跳过）；不许的是 nil。
    public static func entryName(_ raw: String) -> String? {
        var name = raw
        // 只去掉一层 ./（和 Linux 的 removeprefix 一样，././lexicon.tsv 不认）
        if name.hasPrefix("./") { name.removeFirst(2) }
        if name.isEmpty || name == "." { return "" }
        return files.contains(name) ? name : nil
    }

    /// 检查解出来的 lexicon.tsv：每行（注释、空行除外）至少两列，条数不少于 minimum。返回条数。
    public static func checkLexicon(at path: String, minimum: Int = minEntries) -> Result<Int, PackError> {
        guard let f = fopen(path, "rb") else {
            return .failure(PackError("词库包里没有 lexicon.tsv，不安装"))
        }
        defer { fclose(f) }
        var line: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(line) }
        var count = 0
        while true {
            let n = getline(&line, &capacity, f)
            if n < 0 { break }
            guard let line, n > 0 else { continue }
            let first = UInt8(bitPattern: line[0])
            if first == UInt8(ascii: "#") { continue }
            var blank = true, tab = false
            for i in 0..<n {
                let c = UInt8(bitPattern: line[i])
                if c == UInt8(ascii: "\t") { tab = true }
                if c != UInt8(ascii: " ") && c != UInt8(ascii: "\t") && c != UInt8(ascii: "\n") && c != UInt8(ascii: "\r") {
                    blank = false
                }
            }
            if blank { continue }
            if !tab {
                return .failure(PackError("lexicon.tsv 格式不对（应为 拼音<TAB>词<TAB>频次），不安装"))
            }
            count += 1
        }
        if count < minimum {
            return .failure(PackError("lexicon.tsv 只有 \(count) 条，像是不完整，不安装"))
        }
        return .success(count)
    }

    /// 装好的词库包的版本（VERSION 文件，空的是「?」）；没装（没有 lexicon.tsv）是 nil。
    public static func installedVersion(folder: String) -> String? {
        guard access(folder + "/lexicon.tsv", F_OK) == 0 else { return nil }
        guard let text = readFile(folder + "/VERSION") else { return "?" }
        let version = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).first.map(String.init) ?? ""
        let trimmed = version.trimmingSpaces()
        return trimmed.isEmpty ? "?" : trimmed
    }
}

public struct PackError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

private func isASCIIAlnum(_ s: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(s) || ("a"..."z").contains(s) || ("A"..."Z").contains(s)
}

private func isHexDigit(_ s: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(s) || ("a"..."f").contains(s) || ("A"..."F").contains(s)
}

private extension String {
    func trimmingSpaces() -> String {
        var s = Substring(self)
        while let c = s.first, c == " " || c == "\t" || c == "\r" { s.removeFirst() }
        while let c = s.last, c == " " || c == "\t" || c == "\r" { s.removeLast() }
        return String(s)
    }
}
