// 本地翻译模型（腾讯混元 HY-MT 1.5 1.8B）和跑它的 llama-server：下载地址、校验值、大小。
// 模型和 Linux 设置（settings/wowtype-config 的 LOCAL_MODEL_*）是同一个文件；llama-server 用同一个构建
// （LLAMA_BUILD），换成官方的 macOS 包。要换版本就改这里，大小和 SHA256 一起改。
// 下载、解压在 App 层（LocalModelInstaller），这里只放规矩，不依赖 Foundation，测试在 Linux 上也能跑。

public enum LocalModel {
    public static let fileName = "HY-MT1.5-1.8B-Q4_K_M.gguf"
    public static let url = "https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/resolve/main/" + fileName
    public static let sha256 = "4383ac0c3c8e476de98ff979c2a3f069f8c4fb385e7860cf2d28da896cc477c7"
    public static let size: Int64 = 1_133_080_512
    public static let page = "https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF"
    public static let license = page + "/blob/main/License.txt"
    /// 下载前给用户看的许可要点
    public static let terms = "模型属于腾讯，用的是《腾讯混元社区许可协议》：不适用于欧盟、英国和韩国境内，"
        + "月活超过 1 亿的产品要另外向腾讯申请。模型从 Hugging Face 下载，WowType 不分发它。"

    /// llama.cpp 官方发布的构建（MIT 许可），和 Linux 的一样
    public static let llamaBuild = "b12110"
    public static let llamaPage = "https://github.com/ggml-org/llama.cpp"
    /// 官方 macOS 包要 macOS 13.3 以上（包里程序的 LC_BUILD_VERSION minos）
    public static let llamaMinimumOS = (major: 13, minor: 3)

    public struct Asset: Equatable {
        public let name: String
        public let url: String
        public let size: Int64
        public let sha256: String
    }

    /// 两种 Mac 各一个包：（文件名里的平台, 大小, SHA256）
    static let llamaAssets: [String: (platform: String, size: Int64, sha256: String)] = [
        "arm64": ("macos-arm64", 16_650_691, "4f5b8de12e0b9516658ca6a5764c6ffb3d7c659c3dd538556b1413c7b4050662"),
        "x86_64": ("macos-x64", 12_388_601, "c8094268b6bf62f4998f0e45656fd9f5e2d4afb6b1cd0044d761db64be1dd47d"),
    ]

    /// 这台 Mac 能用的官方包。machine 是 arm64 / x86_64（Apple 芯片上用 Rosetta 跑时也给 arm64）；
    /// 系统太旧、不认识的 CPU 返回 nil。
    public static func llamaAsset(machine: String, os: (major: Int, minor: Int)) -> Asset? {
        guard let pick = llamaAssets[machine],
              (os.major, os.minor) >= (llamaMinimumOS.major, llamaMinimumOS.minor)
        else { return nil }
        let name = "llama-\(llamaBuild)-bin-\(pick.platform).tar.gz"
        return Asset(name: name, url: "\(llamaPage)/releases/download/\(llamaBuild)/\(name)",
                     size: pick.size, sha256: pick.sha256)
    }

    // MARK: 缺什么

    /// 还差什么要下载。
    public struct Plan: Equatable {
        public var wantModel: Bool
        public var wantLlama: Bool
        /// llama-server 找不到、也下载不了（系统太旧，或者设置里写的位置不对）
        public var llamaUnavailable: Bool
        /// 要下载的一共多少字节
        public var bytes: Int64

        public var ready: Bool { !wantModel && !wantLlama && !llamaUnavailable }
        public var canDownload: Bool { wantModel || wantLlama }
    }

    /// serverFound：找到能用的 llama-server；customServer：设置里自己写了 llama-server 的位置
    /// （写了就只用它，不替它下载）；asset：这台 Mac 能下载的官方包。
    public static func plan(modelExists: Bool, serverFound: Bool, customServer: Bool, asset: Asset?) -> Plan {
        let wantLlama = !serverFound && !customServer && asset != nil
        let bytes = (modelExists ? 0 : size) + (wantLlama ? asset?.size ?? 0 : 0)
        return Plan(wantModel: !modelExists, wantLlama: wantLlama,
                    llamaUnavailable: !serverFound && !wantLlama, bytes: bytes)
    }

    // MARK: 显示

    /// 「1.15 GB」「17 MB」：和 Linux 设置的 human_size 一样（按 1000 进位，GB 留两位小数，MB 取整）
    public static func sizeText(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            let hundredths = (bytes + 5_000_000) / 10_000_000
            let fraction = hundredths % 100
            return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction) GB"
        }
        return "\((bytes + 500_000) / 1_000_000) MB"
    }

    /// 下载了百分之几（0–100）；不知道总数时是 0
    public static func percent(_ done: Int64, of total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return Int(min(max(done, 0), total) * 100 / total)
    }

    // MARK: 续传

    public enum Resume: Equatable {
        /// 接着 .part 往后写
        case append
        /// 从头写（服务不支持续传，或者本来就没有 .part）
        case restart
        /// .part 已经完整了，只差校验
        case complete
        /// 出错了，status 是服务回的状态码
        case fail(status: Int)
    }

    /// 带 Range: bytes=<have>- 请求后，服务回的状态码（和 Content-Range）怎么处理。
    public static func resume(status: Int, have: Int64, contentRange: String? = nil) -> Resume {
        switch status {
        case 206 where have > 0:
            // 回的得是从 have 开始的那一段，不然 .part 就接错了
            if let range = contentRange, !range.hasPrefix("bytes \(have)-") {
                return .fail(status: status)
            }
            return .append
        case 200...299:
            return .restart
        case 416 where have > 0:
            return .complete
        default:
            return .fail(status: status)
        }
    }

    // MARK: 解包

    /// 官方包里的一个条目（tar 列出来的名字）要不要：只要顶层目录下的 llama-server 和 lib*.dylib，
    /// 要的返回放下来的名字，别的（其他程序、子目录、带 .. 的、绝对路径）返回 nil。
    public static func llamaEntry(_ raw: String) -> String? {
        var name = Substring(raw)
        while name.hasPrefix("./") { name = name.dropFirst(2) }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[0].hasPrefix("-"), parts[0] != "..", parts[0] != "."
        else { return nil }
        let file = String(parts[1])
        if file == "llama-server" || (file.hasPrefix("lib") && file.hasSuffix(".dylib")) {
            return file
        }
        return nil
    }

    /// 包里的链接只许指向同一个目录里的文件（libllama.dylib -> libllama.0.dylib）。
    public static func safeLinkTarget(_ target: String) -> Bool {
        !target.isEmpty && target != "." && target != ".." && !target.contains("/")
    }
}
