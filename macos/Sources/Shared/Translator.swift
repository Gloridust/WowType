// 互译：核心的翻译器（wowtype_translate_*）包一层，组字（Composer）只认 TranslationBackend，
// 按键测试换成假的。和 Linux 一样一个进程只有一个翻译器（本地模型的 llama-server 也只起一个），
// 所有输入框共用；每个输入框的会话只取消自己发的请求。
//
// 不依赖 Foundation / AppKit：按键测试在 Linux 上也编。

import CWowtype
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// 翻译的一份快照（wowtype_translate_poll）。
public struct TranslateSnapshot: Equatable {
    public enum Phase: Equatable {
        case idle
        /// 请求中；可能已有一部分译文
        case running
        case done
        /// error 是给用户看的原因
        case error
    }

    public var phase: Phase
    /// 这份结果对应的原文
    public var source: String
    public var text: String
    public var error: String

    public init(phase: Phase, source: String = "", text: String = "", error: String = "") {
        self.phase = phase
        self.source = source
        self.text = text
        self.error = error
    }
}

/// Composer 用的翻译器。调用都不阻塞：start 以后每几十毫秒 poll 一次。
public protocol TranslationBackend: AnyObject {
    /// 填了地址和模型，或者用本地模型且模型文件在
    var isReady: Bool { get }
    /// 开始翻译，取消别的请求；正在译或已经译好同一句话时什么也不做
    func start(_ text: String)
    func cancel()
    func poll() -> TranslateSnapshot
    /// 面板上的方向标签（「中→英」「英→中」），按 text 判断
    func tag(for text: String) -> String
}

/// 核心的翻译器。
public final class Translator: TranslationBackend {
    private let handle: OpaquePointer

    public init() {
        handle = wowtype_translate_new()
    }

    deinit {
        // 本地模型的 llama-server 也一起停掉
        wowtype_translate_free(handle)
    }

    /// 照设置配：keyFile 是 API Key 文件（不在就不带 Key）；defaultLocalModel 是设置里
    /// TranslateLocalModel 留空时用的模型文件；llamaServer 是 TranslateLlamaServer 留空时
    /// 外壳找到的 llama-server（输入法进程的 PATH 里没有 Homebrew）。
    public func configure(_ config: WowtypeConfig, keyFile: String, defaultLocalModel: String,
                          llamaServer: String = "") {
        wowtype_translate_configure(handle, config.translateBaseUrl, config.translateModel,
                                    config.translateTarget, config.translateFormal ? 1 : 0, keyFile)
        var model = ""
        var server = ""
        if config.translateLocal {
            model = config.translateLocalModel.isEmpty ? defaultLocalModel : config.translateLocalModel
            server = config.translateLlamaServer.isEmpty ? llamaServer : config.translateLlamaServer
        }
        // 没选本地模型时传空串：不起进程、不占端口（已经起了的马上停掉）
        wowtype_translate_configure_local(handle, model, server, UInt32(config.translateIdleMinutes * 60))
    }

    public var isReady: Bool {
        wowtype_translate_ready(handle) == 1
    }

    /// 本地模型的 llama-server 正在跑
    public var localRunning: Bool {
        wowtype_translate_local_running(handle) == 1
    }

    public func start(_ text: String) {
        wowtype_translate_start(handle, text)
    }

    public func cancel() {
        wowtype_translate_cancel(handle)
    }

    public func poll() -> TranslateSnapshot {
        let phase: TranslateSnapshot.Phase
        switch Int(wowtype_translate_poll(handle)) {
        case Int(WOWTYPE_TRANSLATE_RUNNING): phase = .running
        case Int(WOWTYPE_TRANSLATE_DONE): phase = .done
        case Int(WOWTYPE_TRANSLATE_ERROR): phase = .error
        default: phase = .idle
        }
        return TranslateSnapshot(phase: phase, source: string(wowtype_translate_source(handle)),
                                 text: string(wowtype_translate_text(handle)),
                                 error: string(wowtype_translate_error(handle)))
    }

    public func tag(for text: String) -> String {
        string(wowtype_translate_tag(handle, text))
    }

    private func string(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }
}

/// 互译的 API Key 文件：一行，就是 Key 本身（和 Linux 的 ~/.config/wowtype/translate.key 一样）。
/// 不写进 wowtype.conf；文件只有自己能读写（0600）。
public enum TranslateKeyFile {
    /// 第一行去掉首尾空白；文件不在是空串。
    public static func read(_ path: String) -> String {
        guard let f = fopen(path, "rb") else { return "" }
        defer { fclose(f) }
        var bytes: [UInt8] = []
        var c = fgetc(f)
        while c != EOF && c != 0x0A && bytes.count < 4096 {
            bytes.append(UInt8(c))
            c = fgetc(f)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingWhitespace()
    }

    /// 存 Key：先写同目录的临时文件（建出来就是 0600）再换过去；空串就删掉文件。成功返回 true。
    @discardableResult
    public static func write(_ key: String, to path: String) -> Bool {
        let key = key.trimmingWhitespace()
        if key.isEmpty {
            return unlink(path) == 0 || errno == ENOENT
        }
        let tmp = path + ".tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        // umask 只会去掉权限位，不会多给；还是明确设一次
        fchmod(fd, 0o600)
        let bytes = Array((key + "\n").utf8)
        let written = bytes.withUnsafeBytes { posixWrite(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == bytes.count, rename(tmp, path) == 0 else {
            unlink(tmp)
            return false
        }
        return true
    }

    /// 已经有的 Key 文件权限比 0600 宽（手动建的）：收紧。
    public static func tighten(_ path: String) {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & 0o077 != 0 else { return }
        chmod(path, 0o600)
    }
}

/// POSIX 的 write（和 Swift 里各种 write 方法重名）。
private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(fd, buffer, count)
    #else
    return Darwin.write(fd, buffer, count)
    #endif
}

extension String {
    /// 去掉首尾的空格、制表符、换行（不引 Foundation）。
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        let blank: (Character) -> Bool = { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
        while let c = s.first, blank(c) { s.removeFirst() }
        while let c = s.last, blank(c) { s.removeLast() }
        return String(s)
    }
}

/// 把 TranslationBackend 包成会话要的函数表（wowtype_session_set_translate_backend）。
/// 会话借用它：换翻译器时外壳先让会话换掉，再放掉旧的。
final class TranslateBridge {
    let backend: TranslationBackend
    /// poll / tag 交出去的 C 字符串，下一次调用前有效
    private var strings: [UnsafeMutablePointer<CChar>] = []
    private var tagString: UnsafeMutablePointer<CChar>?

    init(_ backend: TranslationBackend) {
        self.backend = backend
    }

    deinit {
        strings.forEach { free($0) }
        free(tagString)
    }

    var table: WowtypeTranslateBackend {
        var table = WowtypeTranslateBackend()
        table.size = UInt32(MemoryLayout<WowtypeTranslateBackend>.size)
        table.user = Unmanaged.passUnretained(self).toOpaque()
        table.start = { user, text in
            guard let user, let text else { return }
            TranslateBridge.of(user).backend.start(String(cString: text))
        }
        table.cancel = { user in
            guard let user else { return }
            TranslateBridge.of(user).backend.cancel()
        }
        table.poll = { user, source, text, error in
            guard let user else { return 0 }
            return TranslateBridge.of(user).poll(source, text, error)
        }
        table.tag = { user, text in
            guard let user else { return nil }
            let bridge = TranslateBridge.of(user)
            free(bridge.tagString)
            bridge.tagString = strdup(bridge.backend.tag(for: text.map { String(cString: $0) } ?? ""))
            return UnsafePointer(bridge.tagString)
        }
        return table
    }

    private static func of(_ user: UnsafeMutableRawPointer) -> TranslateBridge {
        Unmanaged<TranslateBridge>.fromOpaque(user).takeUnretainedValue()
    }

    private func poll(_ source: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
                      _ text: UnsafeMutablePointer<UnsafePointer<CChar>?>?,
                      _ error: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32 {
        let snapshot = backend.poll()
        strings.forEach { free($0) }
        strings = [snapshot.source, snapshot.text, snapshot.error].map { (text: String) -> UnsafeMutablePointer<CChar> in
            strdup(text)!
        }
        source?.pointee = UnsafePointer(strings[0])
        text?.pointee = UnsafePointer(strings[1])
        error?.pointee = UnsafePointer(strings[2])
        switch snapshot.phase {
        case .idle: return 0
        case .running: return 1
        case .done: return 2
        case .error: return 3
        }
    }
}
