// 一键下载本地翻译模型和跑它的 llama-server（和 Linux 设置的「离线翻译模型」一样）。规矩在 Shared/LocalModel.swift。
//
// 模型：下到数据目录的 models/，先写 .part，断了（取消、退出、断网）再点会接着下，下完校验 SHA256 再改名。
// llama-server：系统里没有时下载 llama.cpp 官方的 macOS 包（钉死构建号和 SHA256），只解出 llama-server
// 和它的动态库到数据目录的 llama/，跑一次 --version 确认能用了再换上去。
// URLSession 下载的文件不带隔离标记，解出来的程序直接能跑。

import CryptoKit
import Darwin
import Foundation

enum LocalModelInstaller {
    /// 现在在下载哪一样
    enum Stage { case connecting, model, llama, unpacking }

    struct Progress {
        let stage: Stage
        /// 两样合起来已经下了多少、一共多少
        let done: Int64
        let total: Int64

        var percent: Int { LocalModel.percent(done, of: total) }
    }

    // MARK: 位置

    static func modelsDir(in supportDir: URL) -> URL {
        supportDir.appendingPathComponent("models", isDirectory: true)
    }

    /// 下载的 llama-server 放这里（AppState.findLlamaServer 先找这里）
    static func llamaDir(in supportDir: URL) -> URL {
        supportDir.appendingPathComponent("llama", isDirectory: true)
    }

    static func downloadedServer(in supportDir: URL) -> String? {
        let path = llamaDir(in: supportDir).appendingPathComponent("llama-server").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// 下载的 llama-server 是哪个构建（解包时写的 VERSION）
    static func downloadedBuild(in supportDir: URL) -> String? {
        let file = llamaDir(in: supportDir).appendingPathComponent("VERSION").path
        return readText(file)?.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// 输入法会用哪个 llama-server：设置里写了就只看它，没写就和 AppState.findLlamaServer 一样找。
    static func findServer(custom: String, supportDir: URL) -> String? {
        let custom = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            let path = (custom as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        let candidates = [llamaDir(in: supportDir).appendingPathComponent("llama-server").path,
                          "/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server",
                          "/opt/local/bin/llama-server"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: 下载什么

    /// Apple 芯片（用 Rosetta 跑 x86_64 的 WowType 时也算）是 arm64
    static var machine: String {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0, arm64 == 1 {
            return "arm64"
        }
        var name = utsname()
        uname(&name)
        return withUnsafeBytes(of: &name.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// 测试时可以用环境变量换掉下载地址和校验值（和 Linux 的 WOWTYPE_LOCAL_MODEL_URL 这些一样）
    private static func env(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var modelURL: String { env("WOWTYPE_LOCAL_MODEL_URL") ?? LocalModel.url }
    static var modelSHA256: String { env("WOWTYPE_LOCAL_MODEL_SHA256") ?? LocalModel.sha256 }

    /// 这台 Mac 能下载的官方 llama-server 包；系统太旧（要 13.3 以上）时是 nil
    static var llamaAsset: LocalModel.Asset? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let asset = LocalModel.llamaAsset(machine: machine, os: (os.majorVersion, os.minorVersion)) else {
            return nil
        }
        return LocalModel.Asset(name: asset.name, url: env("WOWTYPE_LLAMA_URL") ?? asset.url, size: asset.size,
                                sha256: env("WOWTYPE_LLAMA_SHA256") ?? asset.sha256)
    }

    static func plan(model: String, customServer: String, supportDir: URL) -> LocalModel.Plan {
        LocalModel.plan(modelExists: isFile(model),
                        serverFound: findServer(custom: customServer, supportDir: supportDir) != nil,
                        customServer: !customServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        asset: llamaAsset)
    }

    /// 模型下了一半（.part 还在）：再下载是接着下
    static func hasPartial(model: String) -> Bool {
        FileManager.default.fileExists(atPath: model + ".part")
    }

    // MARK: 一键安装

    /// 缺什么下什么：模型下到 model，llama-server 解到 supportDir/llama。progress 是两样合起来的
    /// （在后台线程上调）。control 取消时抛 DownloadCancelled，.part 留着下次接着下。
    static func install(_ plan: LocalModel.Plan, model: String, supportDir: URL, control: DownloadControl,
                        progress: @escaping (Progress) -> Void) throws {
        let total = plan.bytes
        var before: Int64 = 0
        progress(Progress(stage: .connecting, done: 0, total: total))
        if plan.wantModel {
            try download(modelURL, sha256: modelSHA256, to: URL(fileURLWithPath: model), control: control) { done, _ in
                progress(Progress(stage: .model, done: done, total: total))
            }
            before = LocalModel.size
        }
        if plan.wantLlama {
            guard let asset = llamaAsset else {
                throw PackError("这台 Mac 下载不了 llama-server（要 macOS 13.3 以上），请自己装 llama.cpp")
            }
            let offset = before
            try installLlamaServer(asset, supportDir: supportDir, control: control) { stage, done in
                progress(Progress(stage: stage, done: offset + done, total: total))
            }
        }
    }

    /// 删掉下载的模型（设置里自己写了模型位置的不删）和下载的 llama-server（Homebrew 装的不动），返回空出的字节数。
    @discardableResult
    static func remove(model: String?, supportDir: URL) -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        if let model {
            for path in [model, model + ".part"] where fm.fileExists(atPath: path) {
                freed += fileSize(path)
                try? fm.removeItem(atPath: path)
            }
        }
        let llama = llamaDir(in: supportDir)
        freed += LexiconPackInstaller.folderSize(llama)
        try? fm.removeItem(at: llama)
        // 下了一半的官方包
        let archive = llama.path + ".tar.gz.part"
        freed += fileSize(archive)
        try? fm.removeItem(atPath: archive)
        return freed
    }

    // MARK: 下载

    /// 下载到 dest：先写 dest.part（有就接着下），一边下一边算 SHA256，对上了再改名成 dest。
    /// 校验不过删掉 .part 抛错；网络出错、取消时 .part 留着。
    static func download(_ link: String, sha256: String, to dest: URL, control: DownloadControl,
                         progress: @escaping (Int64, Int64) -> Void) throws {
        guard let url = URL(string: link) else { throw PackError("下载地址不对：\(link)") }
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = URL(fileURLWithPath: dest.path + ".part")
        var have: Int64 = 0
        var hasher = SHA256()
        if fm.fileExists(atPath: part.path) {
            // 接着下：先把已经下的那段算进校验
            let handle = try FileHandle(forReadingFrom: part)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try control.check()
                hasher.update(data: chunk)
                have += Int64(chunk.count)
            }
        }
        let task = ResumableDownload(url: url, part: part, have: have, hasher: hasher, control: control,
                                     progress: progress)
        let digest = try task.run()
        guard digest == sha256.lowercased() else {
            try? fm.removeItem(at: part)
            throw PackError("下载的文件校验不对（SHA256 不一致），已删除，请重试")
        }
        guard rename(part.path, dest.path) == 0 else {
            throw PackError("下载好了但改不了名：\(String(cString: strerror(errno)))")
        }
    }

    // MARK: llama-server

    /// 下载官方包、校验、解到 supportDir/llama，返回 llama-server 的路径。progress 的字节数只算这个包。
    @discardableResult
    static func installLlamaServer(_ asset: LocalModel.Asset, supportDir: URL, control: DownloadControl,
                                   progress: @escaping (Stage, Int64) -> Void) throws -> String {
        let root = llamaDir(in: supportDir)
        let archive = root.appendingPathExtension("tar.gz")
        try download(asset.url, sha256: asset.sha256, to: archive, control: control) { done, _ in
            progress(.llama, done)
        }
        defer { try? FileManager.default.removeItem(at: archive) }
        progress(.unpacking, asset.size)
        return try unpackLlama(archive, into: root)
    }

    /// 把官方包解到 root：先解到 root.new，只要 llama-server 和 lib*.dylib，检查过链接、
    /// 跑一次 llama-server --version（动态库缺了跑不起来）再换上去。出错时原来的不动。
    @discardableResult
    static func unpackLlama(_ archive: URL, into root: URL) throws -> String {
        let fm = FileManager.default
        // 先看清包里有什么：名字用 -t 列的（原样），类型看 -tv 那一行的第一个字符（- 普通文件，l 链接）
        let raws = try run("/usr/bin/tar", ["-tzf", archive.path]).split(separator: "\n").map(String.init)
        let types = try run("/usr/bin/tar", ["-tvzf", archive.path]).split(separator: "\n").map { $0.first ?? "?" }
        guard raws.count == types.count else { throw PackError("llama.cpp 的包解不开：列出来的条目对不上") }
        var names: [String] = []
        var seen: Set<String> = []
        for (raw, type) in zip(raws, types) {
            guard let name = LocalModel.llamaEntry(raw), type == "-" || type == "l" else { continue }
            guard seen.insert(name).inserted else { throw PackError("llama.cpp 的包里有重名的文件 \(name)") }
            names.append(raw)
        }
        guard seen.contains("llama-server") else { throw PackError("llama.cpp 的包里没有 llama-server") }

        try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = root.appendingPathExtension("new")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            _ = try run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path, "--strip-components", "1"] + names)
            for name in try fm.contentsOfDirectory(atPath: staging.path) {
                let path = staging.appendingPathComponent(name).path
                let type = try fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    guard LocalModel.safeLinkTarget(try fm.destinationOfSymbolicLink(atPath: path)) else {
                        throw PackError("llama.cpp 的包里的链接不对：\(name)")
                    }
                } else if type != .typeRegular {
                    throw PackError("llama.cpp 的包里有不认识的文件：\(name)")
                }
                // 下载的文件本来就不带隔离标记；万一带了，系统会拦着不让跑
                removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
            }
            let server = staging.appendingPathComponent("llama-server").path
            guard fm.isExecutableFile(atPath: server) else { throw PackError("llama.cpp 的包里的 llama-server 不能执行") }
            do {
                _ = try run(server, ["--version"], timeout: 30)
            } catch let error as PackError {
                throw PackError("llama-server 跑不起来：\(error.description)")
            }
            try Data((LocalModel.llamaBuild + "\n").utf8).write(to: staging.appendingPathComponent("VERSION"))
            let old = root.appendingPathExtension("old")
            try? fm.removeItem(at: old)
            if fm.fileExists(atPath: root.path) {
                try fm.moveItem(at: root, to: old)
            }
            try fm.moveItem(at: staging, to: root)
            try? fm.removeItem(at: old)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return root.appendingPathComponent("llama-server").path
    }

    /// 跑一个程序，返回它的输出；退出码不是 0、超时时抛错（带上它报的最后一行）。
    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 120) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // 输出读完了才等它退出（输出多时管道会满）
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { outData = out.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw PackError("\((tool as NSString).lastPathComponent) 超过 \(Int(timeout)) 秒没反应")
        }
        group.wait()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errData.isEmpty ? outData : errData, as: UTF8.self)
            let last = text.split(whereSeparator: \.isNewline).last.map(String.init)
            throw PackError(last ?? "退出码 \(process.terminationStatus)")
        }
        return String(decoding: outData, as: UTF8.self)
    }

    private static func isFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// 用户点了取消（下次接着下）
struct DownloadCancelled: Error, CustomStringConvertible {
    var description: String { "已暂停，再点下载会接着下" }
}

/// 取消下载：设置窗口在主线程上点「取消」，下载线程看这个；正在连网时直接停掉请求。
final class DownloadControl {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionTask?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func check() throws {
        if isCancelled { throw DownloadCancelled() }
    }

    fileprivate func attach(_ task: URLSessionTask?) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { task?.cancel() }
    }
}

/// 能续传的下载：带 Range 请求，收到的数据接在 .part 后面写，同时算 SHA256。返回整个文件的 SHA256。
private final class ResumableDownload: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let part: URL
    private var have: Int64
    private var hasher: SHA256
    private let control: DownloadControl
    private let progress: (Int64, Int64) -> Void
    private let done = DispatchSemaphore(value: 0)
    private var handle: FileHandle?
    private var total: Int64 = 0
    private var failure: Error?
    private var lastReport = 0.0

    init(url: URL, part: URL, have: Int64, hasher: SHA256, control: DownloadControl,
         progress: @escaping (Int64, Int64) -> Void) {
        self.url = url
        self.part = part
        self.have = have
        self.hasher = hasher
        self.control = control
        self.progress = progress
    }

    func run() throws -> String {
        try control.check()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("WowType/\(appVersion)", forHTTPHeaderField: "User-Agent")
        if have > 0 {
            request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        control.attach(task)
        task.resume()
        done.wait()
        control.attach(nil)
        session.invalidateAndCancel()
        try? handle?.close()
        if let failure { throw failure }
        progress(have, have)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let range = http?.value(forHTTPHeaderField: "Content-Range")
        do {
            switch LocalModel.resume(status: status, have: have, contentRange: range) {
            case .append:
                let handle = try FileHandle(forWritingTo: part)
                try handle.seekToEnd()
                self.handle = handle
            case .restart:
                // 服务不支持续传（或者本来就是从头下）：从头写
                guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
                    throw PackError("写不了 \(part.path)")
                }
                handle = try FileHandle(forWritingTo: part)
                have = 0
                hasher = SHA256()
            case .complete:
                // .part 已经下完整了，只差校验
                completionHandler(.cancel)
                return
            case .fail(let status):
                throw PackError("下载失败：服务器返回 \(status)")
            }
        } catch {
            failure = error
            completionHandler(.cancel)
            return
        }
        let length = response.expectedContentLength
        total = length > 0 ? have + length : 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        if control.isCancelled {
            failure = DownloadCancelled()
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = PackError("写不进去：\(error.localizedDescription)")
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        have += Int64(data.count)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastReport > 0.2 {
            lastReport = now
            progress(have, total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil, let error {
            // 收到 416 时自己取消的不算错
            let cancelledByUs = (error as? URLError)?.code == .cancelled && handle == nil
            if control.isCancelled {
                failure = DownloadCancelled()
            } else if !cancelledByUs {
                failure = PackError("下载失败：\(error.localizedDescription)")
            }
        } else if failure == nil, handle == nil {
            failure = PackError("下载失败：服务器没有回数据")
        }
        done.signal()
    }
}
