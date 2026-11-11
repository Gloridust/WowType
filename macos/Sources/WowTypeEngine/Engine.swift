// 引擎句柄和后台载入。
//
// 载入（读词库、语言模型）在后台队列上做，做完把句柄交给主线程；之后引擎只在主线程上用。
// 载入期间 engine 是 nil：会话照样收字母，只是没有候选（核心保证）。
// 载入顺序和 fcitx5 插件的 loadCore 一样：词库（带快照目录）→ 语言模型（坏了就不带它再试）
// → 英文词表 → 神经语言模型（有才用）→ 用户词 → 输入习惯；之后按设置再载入简繁表和自定义词。
import CWowTypeCore
import Foundation
import os
import WowTypeKit

/// 引擎句柄。只在主线程上用（后台载入时除外，那时还没交出去）。
public final class Engine: @unchecked Sendable {
    let raw: OpaquePointer
    private var conversionLoaded = false

    fileprivate init(raw: OpaquePointer) { self.raw = raw }

    deinit { wowtype_engine_free(raw) }

    /// 核心给的全部默认设置（第一次写 wowtype.conf 用）。
    public static var defaultIni: String {
        String(cString: wowtype_config_default_ini())
    }

    /// 把设置用到引擎上。Traditional 打开时先载入简繁表（只载一次）。
    @MainActor
    @discardableResult
    public func configure(_ ini: String, paths: DataPaths, logger: Logger) -> Int {
        if !conversionLoaded, IniDocument(text: ini).value(for: "Traditional")?.lowercased() == "true" {
            if let s2t = paths.data("s2t.tsv"), wowtype_engine_load_conversion(raw, s2t.path) > 0 {
                conversionLoaded = true
            } else {
                logger.error("简繁表载入失败")
            }
        }
        return Int(wowtype_engine_configure(raw, ini))
    }

    /// 光标前已经上屏的字（会话上屏以后由 Session 交过来，给下一次输入排序）。
    @MainActor
    func setContext(_ text: String) {
        _ = wowtype_engine_set_context(raw, text)
    }

    /// 重读自定义词（custom.tsv）；文件不在就清空。
    @MainActor
    public func reloadCustomWords(_ url: URL, logger: Logger) {
        if wowtype_engine_load_custom_words(raw, url.path) < 0 {
            logger.error("自定义词载入失败: \(Self.lastError, privacy: .public)")
        }
    }

    /// 把用户词库和输入习惯存盘。
    @MainActor
    public func save(paths: DataPaths, logger: Logger) {
        try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        if wowtype_engine_save_user_dict(raw, paths.userDict.path) != 0 {
            logger.error("用户词库存盘失败: \(Self.lastError, privacy: .public)")
        }
        if wowtype_engine_save_history(raw, paths.history.path) != 0 {
            logger.error("输入习惯存盘失败: \(Self.lastError, privacy: .public)")
        }
    }

    /// 核心的错误串只含文件名、原因，不含用户打的字。
    static var lastError: String {
        wowtype_last_error().map { String(cString: $0) } ?? ""
    }

    // MARK: - 后台载入

    /// 在当前线程上载入（由 EngineStore 放到后台队列上调）。
    /// safeMode 时不读用户目录里的东西（用户词、输入习惯、盖过自带数据的文件、神经模型）。
    static func load(paths: DataPaths, safeMode: Bool, logger: Logger) -> Engine? {
        let user = !safeMode
        guard let lexicon = paths.data("lexicon.tsv", userOverrides: user) else {
            logger.fault("找不到 lexicon.tsv")
            return nil
        }
        try? FileManager.default.createDirectory(at: paths.cache, withIntermediateDirectories: true)
        let started = Date()
        let lm = paths.data("words.lm", userOverrides: user)
        var handle = wowtype_engine_new_with_cache(lexicon.path, lm?.path, paths.cache.path)
        if handle == nil, lm != nil {
            logger.error("语言模型载入失败，不用它: \(lastError, privacy: .public)")
            handle = wowtype_engine_new_with_cache(lexicon.path, nil, paths.cache.path)
        }
        guard let handle else {
            logger.fault("引擎初始化失败: \(lastError, privacy: .public)")
            return nil
        }
        let engine = Engine(raw: handle)
        if let english = paths.data("english.txt", userOverrides: user) {
            _ = wowtype_engine_load_english(handle, english.path)
        }
        if user, DataPaths.isFile(paths.nnlm), wowtype_engine_load_nnlm(handle, paths.nnlm.path) < 0 {
            logger.error("神经语言模型载入失败: \(lastError, privacy: .public)")
        }
        if user {
            if DataPaths.isFile(paths.userDict) { _ = wowtype_engine_load_user_dict(handle, paths.userDict.path) }
            if DataPaths.isFile(paths.history), wowtype_engine_load_history(handle, paths.history.path) < 0 {
                logger.error("输入习惯载入失败: \(lastError, privacy: .public)")
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        logger.info("引擎载入完成，用时 \(ms, privacy: .public) ms，语言模型 \(lm != nil, privacy: .public)")
        return engine
    }
}

/// 管引擎：后台载入，载完交给主线程并让所有活着的会话重算候选。
@MainActor
public final class EngineStore {
    public private(set) var engine: Engine?
    public let paths: DataPaths
    public let safeMode: Bool
    private let logger: Logger
    private var sessions: [ObjectIdentifier: () -> Session?] = [:]
    private var settingsText: String = ""

    public init(paths: DataPaths, safeMode: Bool, logger: Logger) {
        self.paths = paths
        self.safeMode = safeMode
        self.logger = logger
    }

    /// 开始在后台载入。ready 在主线程上调，参数表示成功与否。
    public func load(ready: (@MainActor (Bool) -> Void)? = nil) {
        let paths = self.paths, safe = safeMode, logger = self.logger
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Engine.load(paths: paths, safeMode: safe, logger: logger)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.install(loaded)
                    ready?(loaded != nil)
                }
            }
        }
    }

    private func install(_ loaded: Engine?) {
        guard let loaded else { return }
        engine = loaded
        applyToEngine()
        forEachSession { $0.refresh(engine: loaded) }
    }

    /// 登记一个会话（弱引用），设置变了、引擎载好了都会通知它。
    public func register(_ session: Session) {
        sessions[ObjectIdentifier(session)] = { [weak session] in session }
        session.configure(settingsText)
    }

    public func unregister(_ session: Session) {
        sessions[ObjectIdentifier(session)] = nil
    }

    /// 设置全文变了（第一次读到也算）：用到引擎和所有会话上，再重算候选。
    public func apply(settings text: String) {
        settingsText = text
        applyToEngine()
        forEachSession {
            $0.configure(text)
            $0.refresh(engine: engine)
        }
    }

    /// custom.tsv 变了。
    public func reloadCustomWords() {
        guard let engine else { return }
        engine.reloadCustomWords(paths.custom, logger: logger)
        forEachSession { $0.refresh(engine: engine) }
    }

    public func save() {
        guard let engine, !safeMode else { return }
        engine.save(paths: paths, logger: logger)
    }

    private func applyToEngine() {
        guard let engine else { return }
        let bad = engine.configure(settingsText, paths: paths, logger: logger)
        if bad > 0 { logger.notice("设置里有 \(bad, privacy: .public) 行认不出，按默认值处理") }
        if !safeMode { engine.reloadCustomWords(paths.custom, logger: logger) }
    }

    private func forEachSession(_ body: (Session) -> Void) {
        for (id, get) in sessions {
            if let s = get() { body(s) } else { sessions[id] = nil }
        }
    }
}
