// 安装、注册、启用、选中输入源，卸载。
//
// - 装到 ~/Library/Input Methods（只给当前用户，不要管理员密码），先放好再替换，不删一半；
// - 新文件换好之后再关掉正在运行的旧版本（按 bundle id 找，先 terminate，等一会儿再 forceTerminate）；
//   顺序见 BundleInstaller.installSteps；
// - 注册后重新查一遍，查不到就报错（McBopomofo）；
// - 启用不先看「是否已启用」：macOS 12 起这个属性可能是假的（McBopomofo）；
// - 选中只在已启用、可选、还没选中时做（鼠须管）。
import AppKit
import Carbon
import WowTypeKit

enum Installer {
    enum Failure: Error, CustomStringConvertible {
        case notRegistered(String)
        case tis(String, OSStatus)
        case noBundleID
        /// 输入法装好也启用了，但 macOS 在等用户在系统设置里批准，还没法自动选中。
        case needsApproval(String)

        var description: String {
            switch self {
            case .notRegistered(let id): return "注册后找不到输入源 \(id)"
            case .tis(let what, let status): return "\(what) 失败（OSStatus \(status)）"
            case .noBundleID: return "程序没有 bundle id"
            case .needsApproval(let id):
                return "已安装并启用，但系统在等批准：打开 系统设置 › 键盘 › 文本输入（或点输入菜单里的「键盘设置…」），在提示里点「允许 WowType 启用 WowType Pinyin」；批准后从输入菜单选 WowType 就行。\(id)"
            }
        }
    }

    static var inputMethodsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
    }

    static var installedURL: URL {
        inputMethodsDirectory.appendingPathComponent(BundleInstaller.bundleName, isDirectory: true)
    }

    static func bundleID() throws -> String {
        guard let id = Bundle.main.bundleIdentifier else { throw Failure.noBundleID }
        return id
    }

    /// 唯一的输入模式：拼音。和 Info.plist 模板里的 TISInputSourceID 是同一个规则。
    static func modeID(_ bundleID: String) -> String { "\(bundleID).pinyin" }

    // MARK: - 整套

    /// 复制到 ~/Library/Input Methods（已经在那里就跳过），关掉旧进程，注册、启用、选中。
    static func install() throws {
        let id = try bundleID()
        let here = Bundle.main.bundleURL
        var target = here
        let inPlace = BundleInstaller.isInside(here, directory: inputMethodsDirectory)
        for step in BundleInstaller.installSteps(alreadyInPlace: inPlace) {
            switch step {
            case .copy:
                target = try BundleInstaller.install(source: here, into: inputMethodsDirectory)
                Log.install.notice("已复制到 \(target.path, privacy: .public)")
            case .quitRunning: quitRunning(bundleID: id)
            case .register: try register(at: target, bundleID: id)
            case .enable: try enable(bundleID: id)
            case .select:
                do { try select(bundleID: id) }
                catch Failure.needsApproval(let sourceID) {
                    // 装好了、也启用了，只差用户在系统设置里批准（2026-11 首次安装实测）。
                    // 安装本身算成功；把该做什么告诉用户，别让 --install 报「安装失败」。
                    Log.install.notice("等待批准：\(sourceID, privacy: .private)")
                    FileHandle.standardOutput.write(Data("WowType：\(Failure.needsApproval(sourceID).description)\n".utf8))
                }
            }
        }
    }

    /// 停用输入源、关掉进程、删掉 ~/Library/Input Methods/WowType.app。用户数据不动。
    static func uninstall() throws {
        let id = try bundleID()
        for source in sources(bundleID: id, includeAll: false) {
            let status = TISDisableInputSource(source)
            if status != noErr { Log.install.error("停用输入源失败 \(status, privacy: .public)") }
        }
        quitRunning(bundleID: id)
        let removed = try BundleInstaller.uninstall(from: inputMethodsDirectory)
        Log.install.notice("卸载完成，删除了程序：\(removed, privacy: .public)")
    }

    // MARK: - 单步

    static func register(at url: URL, bundleID id: String) throws {
        let status = TISRegisterInputSource(url as CFURL)
        guard status == noErr else { throw Failure.tis("TISRegisterInputSource", status) }
        guard source(modeID(id), includeAll: true) != nil else { throw Failure.notRegistered(modeID(id)) }
        Log.install.notice("已注册 \(url.path, privacy: .public)")
    }

    static func enable(bundleID id: String) throws {
        guard let source = source(modeID(id), includeAll: true) else { throw Failure.notRegistered(modeID(id)) }
        let status = TISEnableInputSource(source)
        guard status == noErr else { throw Failure.tis("TISEnableInputSource", status) }
        Log.install.notice("已启用 \(modeID(id), privacy: .public)")
    }

    static func select(bundleID id: String) throws {
        guard let source = source(modeID(id), includeAll: true) else { throw Failure.notRegistered(modeID(id)) }
        guard bool(source, kTISPropertyInputSourceIsEnabled),
              bool(source, kTISPropertyInputSourceIsSelectCapable),
              !bool(source, kTISPropertyInputSourceIsSelected) else { return }
        let status = TISSelectInputSource(source)
        guard status == noErr else {
            if BundleInstaller.selectStatusNeedsApproval(status) { throw Failure.needsApproval(modeID(id)) }
            throw Failure.tis("TISSelectInputSource", status)
        }
    }

    /// 关掉别的同 bundle id 的进程（不含自己）。
    static func quitRunning(bundleID id: String) {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, others.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in others where !app.isTerminated {
            app.forceTerminate()
        }
        Log.install.notice("关掉了 \(others.count, privacy: .public) 个旧进程")
    }

    // MARK: - TIS 查询

    static func sources(bundleID id: String, includeAll: Bool) -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, includeAll)?.takeRetainedValue() else { return [] }
        return list as! [TISInputSource]
    }

    static func source(_ inputSourceID: String, includeAll: Bool) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, includeAll)?.takeRetainedValue() else { return nil }
        return (list as! [TISInputSource]).first
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
}

/// 命令行：--install --uninstall --register --enable --select --quit，按给的顺序执行，出错就停并返回非 0。
enum InstallerCLI {
    static let usage = "用法：WowType [--install | --uninstall | --register | --enable | --select | --quit]..."

    static func run(flags: [String]) -> Int32 {
        do {
            let id = try Installer.bundleID()
            for flag in flags {
                switch flag {
                case "--install": try Installer.install()
                case "--uninstall": try Installer.uninstall()
                case "--register": try Installer.register(at: Bundle.main.bundleURL, bundleID: id)
                case "--enable": try Installer.enable(bundleID: id)
                case "--select": try Installer.select(bundleID: id)
                case "--quit": Installer.quitRunning(bundleID: id)
                default:
                    FileHandle.standardError.write(Data("不认识的参数 \(flag)\n\(usage)\n".utf8))
                    return 2
                }
            }
            return 0
        } catch {
            Log.install.error("失败：\(String(describing: error), privacy: .public)")
            FileHandle.standardError.write(Data("WowType：\(error)\n".utf8))
            return 1
        }
    }
}
