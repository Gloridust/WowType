import Foundation
import Testing
@testable import WowTypeKit

// 设置文本、设置文件、数据路径。用临时目录，不碰真的 ~/Library。

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wowtype-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("设置文本（INI）")
struct IniDocumentTests {
    @Test func readsValuesSkippingCommentsAndSections() {
        let doc = IniDocument(text: "# 注释\n[Group]\nPageSize = 7\nFuzzy=True\n\n")
        #expect(doc.value(for: "PageSize") == "7")
        #expect(doc.value(for: "Fuzzy") == "True")
        #expect(doc.value(for: "Missing") == nil)
        #expect(doc.keys == ["PageSize", "Fuzzy"])
    }

    @Test func lastOccurrenceWins() {
        #expect(IniDocument(text: "A=1\nA=2\n").value(for: "A") == "2")
    }

    @Test func setReplacesInPlaceAndKeepsOtherLines() {
        var doc = IniDocument(text: "# 头\nPageSize=9\n# 中间\nFuzzy=False\n")
        doc.set("Fuzzy", "True")
        #expect(doc.text == "# 头\nPageSize=9\n# 中间\nFuzzy=True\n")
    }

    @Test func setCollapsesDuplicates() {
        var doc = IniDocument(text: "A=1\nB=x\nA=2\n")
        doc.set("A", "3")
        #expect(doc.text == "A=3\nB=x\n")
    }

    @Test func setAppendsMissingKey() {
        var doc = IniDocument(text: "A=1")
        doc.set("B", "2")
        #expect(doc.text == "A=1\nB=2\n")
    }

    @Test func commentLooksLikeKeyIsNotTouched() {
        var doc = IniDocument(text: "#A=0\nA=1\n")
        doc.set("A", "5")
        #expect(doc.text == "#A=0\nA=5\n")
    }

    @Test func emptyTextSet() {
        var doc = IniDocument(text: "")
        doc.set("A", "1")
        #expect(doc.text == "A=1\n")
    }
}

@Suite("设置文件")
struct SettingsStoreTests {
    @Test func missingFileReadsNil() throws {
        let dir = try tempDir()
        #expect(SettingsStore(directory: dir).read() == nil)
    }

    @Test func ensureWritesDefaultOnceAndCreatesDirectory() throws {
        let dir = try tempDir().appendingPathComponent("WowType", isDirectory: true)
        let store = SettingsStore(directory: dir)
        #expect(try store.ensureExists(defaultText: "PageSize=9\n") == "PageSize=9\n")
        #expect(store.fileURL.lastPathComponent == "wowtype.conf")
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "PageSize=9\n")
        // 已经有了就不覆盖用户的设置。
        try store.write("PageSize=5\n")
        #expect(try store.ensureExists(defaultText: "PageSize=9\n") == "PageSize=5\n")
    }

    @Test func writeLeavesNoTempFiles() throws {
        let dir = try tempDir()
        let store = SettingsStore(directory: dir)
        try store.write("A=1\n")
        try store.write("A=2\n")
        #expect(store.read() == "A=2\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["wowtype.conf"])
    }

    @Test func watchSeesReplaceAndInPlaceEdits() async throws {
        let dir = try tempDir()
        let store = SettingsStore(directory: dir)
        try store.write("A=1\n")
        let seen = Seen()
        store.startWatching(queue: DispatchQueue(label: "test.watch")) { text in seen.add(text) }
        defer { store.stopWatching() }

        // 别的程序整个替换文件（编辑器的原子保存）。
        let other = dir.appendingPathComponent("tmp.conf")
        try "A=2\n".write(to: other, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(store.fileURL, withItemAt: other)
        #expect(await seen.wait(for: "A=2\n"))

        // 在原文件上追加。
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("B=3\n".utf8))
        try handle.close()
        #expect(await seen.wait(for: "A=2\nB=3\n"))
    }

    @Test func watchSeesFileCreatedLater() async throws {
        let dir = try tempDir()
        let store = SettingsStore(directory: dir)
        let seen = Seen()
        store.startWatching(queue: DispatchQueue(label: "test.watch2")) { text in seen.add(text) }
        defer { store.stopWatching() }
        try "X=1\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(await seen.wait(for: "X=1\n"))
    }

    @Test func ownWriteDoesNotNotify() async throws {
        let dir = try tempDir()
        let store = SettingsStore(directory: dir)
        try store.write("A=1\n")
        let seen = Seen()
        store.startWatching(queue: DispatchQueue(label: "test.watch3")) { text in seen.add(text) }
        defer { store.stopWatching() }
        try store.write("A=9\n")
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(seen.all == [])
    }
}

/// 收集回调结果，带等待。
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func wait(for text: String, seconds: Double = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if all.contains(text) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
}

@Suite("设置窗口改设置")
struct SettingsEditorTests {
    private let defaults = "# 默认\nPageSize=5\nFuzzy=False\n"

    @Test func safeModeShowsDefaultsAndNeverWritesTheUserFile() throws {
        let store = SettingsStore(directory: try tempDir())
        let mine = "# 我的\nPageSize=9\nShuangpin=True\n"
        try store.write(mine)
        let editor = SettingsEditor(store: store, defaultText: defaults, readOnly: true)
        #expect(editor.text == defaults)
        #expect(throws: SettingsEditor.Failure.readOnly) { try editor.set("Fuzzy", "True") }
        #expect(store.read() == mine)
    }

    @Test func setStartsFromTheFileNotFromAnOldCopy() throws {
        let store = SettingsStore(directory: try tempDir())
        try store.write("PageSize=5\nFuzzy=False\n")
        let editor = SettingsEditor(store: store, defaultText: defaults, readOnly: false)
        _ = editor.text  // 窗口打开时读过一次
        try "# 手改的\nPageSize=7\nFuzzy=False\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
        let saved = try editor.set("Fuzzy", "True")
        #expect(saved == "# 手改的\nPageSize=7\nFuzzy=True\n")
        #expect(store.read() == saved)
    }

    @Test func missingFileStartsFromDefaults() throws {
        let store = SettingsStore(directory: try tempDir().appendingPathComponent("WowType"))
        let editor = SettingsEditor(store: store, defaultText: defaults, readOnly: false)
        #expect(editor.text == defaults)
        #expect(try editor.set("PageSize", "7") == "# 默认\nPageSize=7\nFuzzy=False\n")
        #expect(store.read() == "# 默认\nPageSize=7\nFuzzy=False\n")
    }

    @Test func sameValueDoesNotRewrite() throws {
        let dir = try tempDir()
        let store = SettingsStore(directory: dir)
        try store.write("PageSize=5\n")
        let before = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.systemFileNumber] as? Int
        let editor = SettingsEditor(store: store, defaultText: defaults, readOnly: false)
        #expect(try editor.set("PageSize", "5") == "PageSize=5\n")
        // 原子写会换掉文件（新的 inode）；没写的话还是原来那个文件。
        let after = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.systemFileNumber] as? Int
        #expect(before == after)
    }
}

@Suite("数据路径")
struct DataPathsTests {
    @Test func standardLayout() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let res = URL(fileURLWithPath: "/Apps/WowType.app/Contents/Resources", isDirectory: true)
        let p = DataPaths.standard(resources: res, home: home, bundleID: "org.example.inputmethod.WowType")
        #expect(p.support.path == "/Users/someone/Library/Application Support/WowType")
        #expect(p.cache.path == "/Users/someone/Library/Caches/org.example.inputmethod.WowType")
        #expect(p.config.path == "/Users/someone/Library/Application Support/WowType/wowtype.conf")
        #expect(p.userDict.lastPathComponent == "user.tsv")
        #expect(p.history.lastPathComponent == "history.tsv")
        #expect(p.custom.lastPathComponent == "custom.tsv")
        #expect(p.nnlm.path == "/Users/someone/Library/Application Support/WowType/wetype/nlrgpt2_nnlm.bin")
    }

    @Test func userCopyOverridesBundledCopy() throws {
        let root = try tempDir()
        let res = root.appendingPathComponent("Resources", isDirectory: true)
        let sup = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sup, withIntermediateDirectories: true)
        try "r".write(to: res.appendingPathComponent("lexicon.tsv"), atomically: true, encoding: .utf8)
        try "r".write(to: res.appendingPathComponent("english.txt"), atomically: true, encoding: .utf8)
        try "u".write(to: sup.appendingPathComponent("lexicon.tsv"), atomically: true, encoding: .utf8)
        let p = DataPaths(resources: res, support: sup, cache: root.appendingPathComponent("Cache"))
        #expect(p.data("lexicon.tsv") == sup.appendingPathComponent("lexicon.tsv"))
        #expect(p.data("english.txt") == res.appendingPathComponent("english.txt"))
        #expect(p.data("words.lm") == nil)
        // 安全模式不看用户目录。
        #expect(p.data("lexicon.tsv", userOverrides: false) == res.appendingPathComponent("lexicon.tsv"))
    }

    @Test func directoryIsNotADataFile() throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("words.lm"),
                                                withIntermediateDirectories: true)
        let p = DataPaths(resources: root, support: root.appendingPathComponent("none"), cache: root)
        #expect(p.data("words.lm") == nil)
    }
}
