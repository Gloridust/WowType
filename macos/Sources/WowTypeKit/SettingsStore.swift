// 设置文件：~/Library/Application Support/WowType/wowtype.conf。
//
// - 第一次用时由前端写入核心给的默认全文（不覆盖已有的文件）；
// - 写入是原子的（先写临时文件再改名）；
// - 监视文件：别的程序整个替换（编辑器保存）或在原文件上改，都会回调新内容。
//   同时监视目录（文件被替换、新建）和文件本身（原地改）；内容没变或是自己刚写的不回调。
import Foundation

public final class SettingsStore: @unchecked Sendable {
    public let directory: URL
    public let fileURL: URL

    private let lock = NSLock()
    private var lastText: String?
    /// 正在写入的内容（write 还没返回）。
    private var pendingOwn: String?
    private var queue: DispatchQueue?
    private var onChange: (@Sendable (String) -> Void)?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    public init(directory: URL, fileName: String = "wowtype.conf") {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    deinit { stopWatching() }

    /// 文件内容；没有文件或读不出来时返回 nil。
    public func read() -> String? {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 文件不存在就写入 defaultText（会建目录）。返回文件现在的内容。
    @discardableResult
    public func ensureExists(defaultText: String) throws -> String {
        if let text = read() { return text }
        try write(defaultText)
        return defaultText
    }

    public func write(_ text: String) throws {
        // 写的过程中监视回调可能在别的队列上读到旧内容（原子写先在同一目录建临时文件）或新内容，
        // 两种都不算别人改的：旧的是 lastText，新的先记在 pendingOwn。
        lock.lock()
        pendingOwn = text
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: .atomic)
        } catch {
            lock.lock()
            pendingOwn = nil
            lock.unlock()
            throw error
        }
        lock.lock()
        lastText = text
        pendingOwn = nil
        lock.unlock()
        // 原子写换掉了文件，文件那一路要重新挂。
        rearmFileSource()
    }

    /// 开始监视；回调在 queue 上执行，参数是文件的新内容。
    public func startWatching(queue: DispatchQueue, onChange: @escaping @Sendable (String) -> Void) {
        stopWatching()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock.lock()
        self.queue = queue
        self.onChange = onChange
        if lastText == nil { lastText = read() }
        lock.unlock()

        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
            source.setEventHandler { [weak self] in
                self?.rearmFileSource()
                self?.check()
            }
            source.setCancelHandler { close(fd) }
            lock.lock(); dirSource = source; lock.unlock()
            source.resume()
        }
        rearmFileSource()
    }

    public func stopWatching() {
        lock.lock()
        let sources = [dirSource, fileSource]
        dirSource = nil
        fileSource = nil
        onChange = nil
        queue = nil
        lock.unlock()
        sources.forEach { $0?.cancel() }
    }

    private func rearmFileSource() {
        lock.lock()
        guard let queue else { lock.unlock(); return }
        let old = fileSource
        fileSource = nil
        lock.unlock()
        old?.cancel()

        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if let events = source?.data, !events.isDisjoint(with: [.delete, .rename]) {
                self.rearmFileSource()
            }
            self.check()
        }
        source.setCancelHandler { close(fd) }
        lock.lock()
        if self.queue == nil {  // 期间停掉了
            lock.unlock()
            source.cancel()
            return
        }
        fileSource = source
        lock.unlock()
        source.resume()
    }

    private func check() {
        // 读文件和比较要在同一把锁里：先读后锁的话，可能读到旧内容，等拿到锁时 write 已经写完，
        // 旧内容就被当成了别人的改动。
        lock.lock()
        guard let text = read() else { lock.unlock(); return }
        let changed = text != lastText && text != pendingOwn
        if changed || text == pendingOwn { lastText = text }
        let callback = onChange
        lock.unlock()
        if changed { callback?(text) }
    }
}
