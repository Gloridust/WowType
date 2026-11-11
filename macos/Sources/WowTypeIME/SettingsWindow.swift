// 设置窗口（SwiftUI）：改的就是 wowtype.conf，改一项写一次，马上生效。
// 每次打开窗口都重新读文件；改一项时从文件现在的内容改起（SettingsEditor），不会冲掉别处的改动。
// 安全模式下只显示默认值，不能改。
//
// 这里不写默认值：每一项都从当前设置全文里读，文件里没有就读核心给的默认全文
// （wowtype_config_default_ini）。键名、取值的含义见 docs/CONFIG.md。
import AppKit
import SwiftUI
import WowTypeEngine
import WowTypeKit

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var model: SettingsModel?

    func show() {
        if let model {
            model.reload()
        } else {
            let model = SettingsModel()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "WowType 设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
            self.model = model
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var doc: IniDocument
    private let defaults = IniDocument(text: Engine.defaultIni)
    let readOnly = IMEApp.shared.settingsEditor.readOnly

    init() {
        doc = IniDocument(text: IMEApp.shared.settingsText)
    }

    /// 重新读文件（窗口关着的时候文件可能被改过）。
    func reload() {
        doc = IniDocument(text: IMEApp.shared.settingsText)
    }

    func string(_ key: String) -> String {
        doc.value(for: key) ?? defaults.value(for: key) ?? ""
    }

    func set(_ key: String, _ value: String) {
        guard string(key) != value else { return }
        if let text = IMEApp.shared.setSetting(key, value) {
            doc = IniDocument(text: text)
        } else {
            reload()  // 没改成：界面回到文件里的值
        }
    }

    func bool(_ key: String) -> Binding<Bool> {
        Binding(get: { self.string(key).lowercased() == "true" },
                set: { self.set(key, $0 ? "True" : "False") })
    }

    func choice(_ key: String) -> Binding<String> {
        Binding(get: { self.string(key) }, set: { self.set(key, $0) })
    }

    func int(_ key: String) -> Binding<Int> {
        Binding(get: { Int(self.string(key)) ?? 0 }, set: { self.set(key, String($0)) })
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private let schemes: [(String, String)] = [
        ("Ziranma", "自然码"), ("Xiaohe", "小鹤"), ("Microsoft", "微软"), ("Sogou", "搜狗"),
        ("ABC", "智能 ABC"), ("Ziguang", "紫光"), ("PinyinJiajia", "拼音加加"),
    ]
    private let fuzzyGroups: [(String, String)] = [
        ("FuzzyZh", "z = zh"), ("FuzzyCh", "c = ch"), ("FuzzySh", "s = sh"), ("FuzzyNL", "n = l"),
        ("FuzzyFH", "f = h"), ("FuzzyRL", "r = l"), ("FuzzyAn", "an = ang"), ("FuzzyEn", "en = eng"),
        ("FuzzyIn", "in = ing"),
    ]

    var body: some View {
        Form {
            if model.readOnly {
                Section {
                    Text("WowType 短时间内连续启动了好几次，这次用的是默认设置，不能修改。你的设置文件没有动，下次正常启动后就会用上。")
                        .foregroundStyle(.secondary)
                }
            }
            Group {
                Section("候选") {
                    Picker("排列", selection: model.choice("CandidateLayout")) {
                        Text("横排").tag("Horizontal")
                        Text("竖排").tag("Vertical")
                    }
                    Stepper("每页 \(model.int("PageSize").wrappedValue) 个", value: model.int("PageSize"), in: 3...9)
                    Picker("分号、引号选词", selection: model.choice("SelectKeys")) {
                        Text("不用").tag("Off")
                        Text("; 选第 2 个").tag("Semicolon")
                        Text("; 选第 2 个，' 选第 3 个").tag("SemicolonQuote")
                    }
                }
                Section("拼音") {
                    Toggle("模糊音", isOn: model.bool("Fuzzy"))
                    if model.bool("Fuzzy").wrappedValue {
                        LazyVGrid(columns: [GridItem(), GridItem(), GridItem()], alignment: .leading) {
                            ForEach(fuzzyGroups, id: \.0) { key, title in
                                Toggle(title, isOn: model.bool(key))
                            }
                        }
                    }
                    Toggle("按错键纠错", isOn: model.bool("TypoCorrection"))
                    Toggle("双拼", isOn: model.bool("Shuangpin"))
                    if model.bool("Shuangpin").wrappedValue {
                        Picker("双拼方案", selection: model.choice("ShuangpinScheme")) {
                            ForEach(schemes, id: \.0) { key, title in Text(title).tag(key) }
                        }
                    }
                    Toggle("繁体输出", isOn: model.bool("Traditional"))
                }
                Section("切换和候选内容") {
                    Picker("单按 Shift 切中英文", selection: model.choice("ShiftToggle")) {
                        Text("左右都行").tag("Both")
                        Text("左 Shift").tag("Left")
                        Text("右 Shift").tag("Right")
                        Text("不用").tag("Off")
                    }
                    Toggle("日期、时间（riqi、shijian）", isOn: model.bool("DateTime"))
                    Toggle("计算器（v 开头）", isOn: model.bool("Calculator"))
                    Toggle("打字时推荐 emoji", isOn: model.bool("EmojiSuggest"))
                }
            }
            .disabled(model.readOnly)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
