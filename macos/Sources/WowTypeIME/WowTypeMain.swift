// 启动：命令行安装、安装窗口、输入法服务三选一。
import AppKit
import InputMethodKit
import WowTypeEngine
import WowTypeKit

enum WowTypeMain {
    static func run(arguments: [String]) -> Int32 {
        let flags = Array(arguments.dropFirst()).filter { $0.hasPrefix("--") }
        if !flags.isEmpty {
            return InstallerCLI.run(flags: flags)
        }
        if !BundleInstaller.isInside(Bundle.main.bundleURL, directory: Installer.inputMethodsDirectory) {
            InstallerWindow.runApp()
            return 0
        }
        IMEApp.start()
        NSApplication.shared.run()
        return 0
    }
}

/// 输入法服务运行时的全局对象。
@MainActor
final class IMEApp {
    static private(set) var shared: IMEApp!

    let bundleID: String
    let paths: DataPaths
    let safeMode: Bool
    let store: EngineStore
    let settings: SettingsStore
    let customWords: SettingsStore
    /// 设置窗口读写设置都经过它；安全模式下只读。
    let settingsEditor: SettingsEditor
    private let server: IMKServer

    private init(bundleID: String, paths: DataPaths, safeMode: Bool, server: IMKServer) {
        self.bundleID = bundleID
        self.paths = paths
        self.safeMode = safeMode
        self.server = server
        self.store = EngineStore(paths: paths, safeMode: safeMode, logger: Log.engine)
        self.settings = SettingsStore(directory: paths.support)
        self.customWords = SettingsStore(directory: paths.support, fileName: paths.custom.lastPathComponent)
        self.settingsEditor = SettingsEditor(store: settings, defaultText: Engine.defaultIni, readOnly: safeMode)
    }

    static func start() {
        let bundle = Bundle.main
        let bundleID = bundle.bundleIdentifier ?? "WowType"
        let guardFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(bundleID).launches")
        let safeMode = LaunchGuard(file: guardFile).recordLaunch(now: Date())
        if safeMode {
            Log.app.fault("短时间内连续启动，可能在崩溃循环里：这次用安全模式，不读用户数据和设置")
        }

        let connection = bundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String
            ?? "\(bundleID)_Connection"
        guard let server = IMKServer(name: connection, bundleIdentifier: bundleID) else {
            Log.app.fault("IMKServer 创建失败")
            exit(1)
        }
        let paths = DataPaths.standard(resources: bundle.resourceURL ?? bundle.bundleURL,
                                       home: FileManager.default.homeDirectoryForCurrentUser,
                                       bundleID: bundleID)
        let app = IMEApp(bundleID: bundleID, paths: paths, safeMode: safeMode, server: server)
        shared = app
        app.startEngine()
    }

    private func startEngine() {
        let defaults = Engine.defaultIni
        let text: String
        if safeMode {
            text = defaults
        } else {
            do {
                text = try settings.ensureExists(defaultText: defaults)
            } catch {
                Log.app.error("设置文件写不进去，用默认设置: \(error.localizedDescription, privacy: .public)")
                text = defaults
            }
        }
        store.apply(settings: text)
        store.load { ok in
            if !ok { Log.engine.fault("引擎载入失败：只能打字母，没有候选") }
        }
        guard !safeMode else { return }
        let store = self.store
        settings.startWatching(queue: .main) { text in
            MainActor.assumeIsolated { store.apply(settings: text) }
        }
        customWords.startWatching(queue: .main) { _ in
            MainActor.assumeIsolated { store.reloadCustomWords() }
        }
    }

    /// 设置窗口改了一项：从文件现在的内容改起、写回，再马上用上（自己写的文件不会触发监视回调）。
    /// 返回改后的全文；安全模式下不改（用户的设置不动），写不进去也返回 nil。
    func setSetting(_ key: String, _ value: String) -> String? {
        do {
            let text = try settingsEditor.set(key, value)
            store.apply(settings: text)
            return text
        } catch SettingsEditor.Failure.readOnly {
            Log.app.notice("安全模式下不改设置")
        } catch {
            Log.app.error("设置保存失败: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    /// 当前设置全文（安全模式下是核心的默认值，见 SettingsEditor.text）。
    var settingsText: String { settingsEditor.text }
}
