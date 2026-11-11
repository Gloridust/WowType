import Foundation
import Testing
@testable import WowTypeKit

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wowtype-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("连续崩溃检测")
struct LaunchGuardTests {
    @Test func thirdLaunchWithinTenSecondsIsALoop() throws {
        let g = LaunchGuard(file: try tempDir().appendingPathComponent("launch"))
        let t = Date(timeIntervalSince1970: 1_000)
        #expect(g.recordLaunch(now: t) == false)
        #expect(g.recordLaunch(now: t.addingTimeInterval(3)) == false)
        #expect(g.recordLaunch(now: t.addingTimeInterval(6)) == true)
    }

    @Test func spreadOutLaunchesAreFine() throws {
        let g = LaunchGuard(file: try tempDir().appendingPathComponent("launch"))
        let t = Date(timeIntervalSince1970: 1_000)
        #expect(g.recordLaunch(now: t) == false)
        #expect(g.recordLaunch(now: t.addingTimeInterval(6)) == false)
        #expect(g.recordLaunch(now: t.addingTimeInterval(12)) == false)
        #expect(g.recordLaunch(now: t.addingTimeInterval(30)) == false)
    }

    @Test func garbageFileIsIgnored() throws {
        let file = try tempDir().appendingPathComponent("launch")
        try "abc\n\n1e999\n-5\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(LaunchGuard(file: file).recordLaunch(now: Date(timeIntervalSince1970: 50)) == false)
    }

    @Test func clockGoingBackwardsDoesNotCount() throws {
        let g = LaunchGuard(file: try tempDir().appendingPathComponent("launch"))
        let t = Date(timeIntervalSince1970: 1_000)
        _ = g.recordLaunch(now: t)
        _ = g.recordLaunch(now: t.addingTimeInterval(1))
        #expect(g.recordLaunch(now: t.addingTimeInterval(-3600)) == false)
    }
}

@Suite("编辑区（UTF-8 字节 -> UTF-16）")
struct MarkedTextLayoutTests {
    @Test func asciiOnly() {
        let l = MarkedTextLayout(text: "ni'hao", plainBytes: 0, cursorBytes: 6)
        #expect(l.plainUTF16 == 0)
        #expect(l.caretUTF16 == 6)
        #expect(l.lengthUTF16 == 6)
    }

    @Test func chinesePrefix() {
        // 「你好」6 字节、2 个 UTF-16 单位；shi'jie 7 字节。
        let l = MarkedTextLayout(text: "你好shi'jie", plainBytes: 6, cursorBytes: 13)
        #expect(l.plainUTF16 == 2)
        #expect(l.caretUTF16 == 9)
        #expect(l.lengthUTF16 == 9)
    }

    @Test func emojiCountsTwoUnits() {
        let l = MarkedTextLayout(text: "😀a", plainBytes: 4, cursorBytes: 5)
        #expect(l.plainUTF16 == 2)
        #expect(l.caretUTF16 == 3)
    }

    @Test func offsetsInsideACharacterSnapDown() {
        let l = MarkedTextLayout(text: "你好", plainBytes: 4, cursorBytes: 5)
        #expect(l.plainUTF16 == 1)
        #expect(l.caretUTF16 == 1)
    }

    @Test func offsetsPastTheEndAreClamped() {
        let l = MarkedTextLayout(text: "ab", plainBytes: 99, cursorBytes: 99)
        #expect(l.plainUTF16 == 2)
        #expect(l.caretUTF16 == 2)
    }
}

@Suite("安装：先放好再替换")
struct BundleInstallerTests {
    private func makeApp(_ dir: URL, name: String = "WowType.app", marker: String) throws -> URL {
        let app = dir.appendingPathComponent(name, isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try marker.write(to: macos.appendingPathComponent("WowType"), atomically: true, encoding: .utf8)
        return app
    }

    private func marker(_ app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/WowType"), encoding: .utf8)
    }

    @Test func freshInstallCreatesDirectory() throws {
        let root = try tempDir()
        let src = try makeApp(root.appendingPathComponent("dmg"), marker: "new")
        let target = root.appendingPathComponent("Library/Input Methods", isDirectory: true)
        let dest = try BundleInstaller.install(source: src, into: target)
        #expect(dest == target.appendingPathComponent("WowType.app"))
        #expect(marker(dest) == "new")
        #expect(marker(src) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["WowType.app"])
    }

    @Test func upgradeReplacesOldBundle() throws {
        let root = try tempDir()
        let target = root.appendingPathComponent("IM", isDirectory: true)
        _ = try makeApp(target, marker: "old")
        let src = try makeApp(root.appendingPathComponent("dmg"), marker: "new")
        let dest = try BundleInstaller.install(source: src, into: target)
        #expect(marker(dest) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["WowType.app"])
    }

    @Test func failedCopyKeepsOldBundle() throws {
        let root = try tempDir()
        let target = root.appendingPathComponent("IM", isDirectory: true)
        let old = try makeApp(target, marker: "old")
        let missing = root.appendingPathComponent("nope/WowType.app")
        #expect(throws: (any Error).self) { try BundleInstaller.install(source: missing, into: target) }
        #expect(marker(old) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["WowType.app"])
    }

    @Test func installingOverItselfIsRefused() throws {
        let root = try tempDir()
        let app = try makeApp(root, marker: "same")
        #expect(throws: BundleInstaller.Failure.sameLocation) {
            try BundleInstaller.install(source: app, into: root)
        }
        #expect(marker(app) == "same")
    }

    @Test func isInstalledComparesResolvedPaths() throws {
        let root = try tempDir()
        let target = root.appendingPathComponent("IM", isDirectory: true)
        let app = try makeApp(target, marker: "x")
        let viaDots = target.appendingPathComponent("../IM/WowType.app")
        #expect(BundleInstaller.isInside(viaDots, directory: target))
        #expect(BundleInstaller.isInside(app, directory: target))
        #expect(!BundleInstaller.isInside(root.appendingPathComponent("WowType.app"), directory: target))
    }

    @Test func oldProcessesAreQuitAfterTheNewBundleIsInPlace() {
        // 先关旧进程再复制的话，系统会在复制的这段时间里从还没换的旧 .app 再把旧版本启动起来。
        #expect(BundleInstaller.installSteps(alreadyInPlace: false)
            == [.copy, .quitRunning, .register, .enable, .select])
        #expect(BundleInstaller.installSteps(alreadyInPlace: true)
            == [.quitRunning, .register, .enable, .select])
    }

    @Test func uninstallRemovesOnlyTheBundle() throws {
        let root = try tempDir()
        let target = root.appendingPathComponent("IM", isDirectory: true)
        _ = try makeApp(target, marker: "x")
        try "keep".write(to: target.appendingPathComponent("Other.txt"), atomically: true, encoding: .utf8)
        #expect(try BundleInstaller.uninstall(from: target) == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["Other.txt"])
        #expect(try BundleInstaller.uninstall(from: target) == false)
    }
}

@Suite("安装：选中等待批准")
struct SelectApprovalTests {
    @Test func paramErrMeansNeedsApproval() {
        #expect(BundleInstaller.selectStatusNeedsApproval(-50))
    }

    @Test func otherStatusesAreFailuresNotApproval() {
        #expect(!BundleInstaller.selectStatusNeedsApproval(0))
        #expect(!BundleInstaller.selectStatusNeedsApproval(-108))
        #expect(!BundleInstaller.selectStatusNeedsApproval(1))
    }
}
