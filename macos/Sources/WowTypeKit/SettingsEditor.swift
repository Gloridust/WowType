// 设置窗口改设置的入口。
//
// - 每改一项都从文件现在的内容改起，不用窗口里存的旧副本：窗口开着时用户在编辑器里改过文件，
//   那些改动（别的键、注释）不会被冲掉；
// - 安全模式（连续崩溃后）只读：显示核心的默认全文，不写文件，用户的设置原样留着。
// 不知道有哪些键、默认值是什么：默认全文由调用方给（核心的 wowtype_config_default_ini）。
import Foundation

public struct SettingsEditor: Sendable {
    public enum Failure: Error, Equatable {
        /// 安全模式下不能改设置。
        case readOnly
    }

    public let store: SettingsStore
    public let defaultText: String
    public let readOnly: Bool

    public init(store: SettingsStore, defaultText: String, readOnly: Bool) {
        self.store = store
        self.defaultText = defaultText
        self.readOnly = readOnly
    }

    /// 现在用的设置全文：只读时是默认全文；否则是文件内容，没有文件时是默认全文。
    public var text: String {
        readOnly ? defaultText : (store.read() ?? defaultText)
    }

    /// 把 key 改成 value 并写回文件，返回改后的全文。文件里已经是这个值就不写，返回现在的全文。
    public func set(_ key: String, _ value: String) throws -> String {
        guard !readOnly else { throw Failure.readOnly }
        var doc = IniDocument(text: text)
        guard doc.value(for: key) != value else { return doc.text }
        doc.set(key, value)
        try store.write(doc.text)
        return doc.text
    }
}
