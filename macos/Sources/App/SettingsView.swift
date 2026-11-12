// 设置窗口的界面（SwiftUI，macOS 12 起）。
//
// 页面、分组、文字照 Linux 的设置界面（settings/wowtype-config 的 build_general / build_input / build_emoji /
// build_words），选项说明对得上 fcitx5-addon/src/wowtype_engine.h。macOS 还没有的功能（工具栏、剪贴板历史、
// 语音、表情面板、互译、检查更新）不列出来，它们在 wowtype.conf 里的键原样留着。
// 样子也照 Linux：薄荷绿渐变侧栏、绿色选中块、白色圆角卡片。

import AppKit
import SwiftUI

// MARK: 颜色

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

private struct Palette {
    let dark: Bool
    static let green = Color(hex: 0x0EAF76)

    var sidebar: LinearGradient {
        let stops: [Gradient.Stop] = dark
            ? [.init(color: Color(hex: 0x17332A), location: 0), .init(color: Color(hex: 0x1C2A25), location: 0.45),
               .init(color: Color(hex: 0x202523), location: 1)]
            : [.init(color: Color(hex: 0xD9F3E6), location: 0), .init(color: Color(hex: 0xE9F8F0), location: 0.4),
               .init(color: Color(hex: 0xF5FBF8), location: 1)]
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .top, endPoint: .bottom)
    }
    var content: Color { dark ? Color(hex: 0x1D201F) : Color(hex: 0xF5F7F6) }
    var card: Color { dark ? Color(hex: 0x282C2A) : .white }
    var cardBorder: Color { dark ? Color(hex: 0x3B4144) : Color(hex: 0xE6EAE8) }
    var nested: Color { dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025) }
    var heading: Color { dark ? Color(hex: 0xA3ACA8) : Color(hex: 0x6B7570) }
    var hover: Color { Palette.green.opacity(dark ? 0.12 : 0.10) }
    var warning: Color { dark ? Color(hex: 0xF8C66D) : Color(hex: 0xB86E00) }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette(dark: false)
}

private extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: 窗口

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(dark: scheme == .dark)
        HStack(spacing: 0) {
            Sidebar(model: model)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text(model.page.title)
                        .font(.system(size: 26, weight: .heavy))
                    page
                }
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .padding(.bottom, 32)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(palette.content)
            .overlay(alignment: .bottom) { ToastView(model: model) }
        }
        .environment(\.palette, palette)
        .frame(minWidth: 640, minHeight: 460)
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .general: GeneralPage(model: model)
        case .input: InputPage(model: model)
        case .emoji: EmojiPage(model: model)
        case .words: WordsPage(model: model)
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WowType").font(.system(size: 17, weight: .heavy))
                    Text("设置").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 44)  // 红绿灯按钮下面
            .padding(.bottom, 18)
            ForEach(SettingsPage.allCases) { page in
                NavRow(page: page, selected: model.page == page) { model.page = page }
            }
            Spacer()
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(palette.sidebar)
    }
}

private struct NavRow: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: page.icon)
                .frame(width: 18)
            Text(page.title)
            Spacer()
        }
        .font(.system(size: 13, weight: selected ? .semibold : .regular))
        .foregroundColor(selected ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Palette.green : (hovering ? palette.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .padding(.horizontal, 12)
    }
}

private struct ToastView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 14) {
                    Text(toast.text)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    if let title = toast.actionTitle {
                        Button(title) { model.runToastAction() }
                            .buttonStyle(.borderless)
                            .foregroundColor(Color(hex: 0x3CCB93))
                            .font(.body.weight(.semibold))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.82)))
                .padding(.bottom, 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast?.id)
    }
}

// MARK: 常规

private let issuesURL = URL(string: "https://github.com/Gloridust/WowType/issues/new")!

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PrefGroup("候选词") {
            PickerRow(title: "排列方向", selection: $model.config.horizontal,
                      options: [("横排", true), ("竖排", false)])
            RowDivider()
            StepperRow(title: "每页个数", subtitle: "用数字键 1–9 选词", value: $model.config.pageSize, range: 3...9)
            RowDivider()
            ExpanderRow(title: "翻页键", subtitle: "Page Up / Page Down 和方向键一直能翻页；下面的可以另外打开") {
                SwitchRow(title: "- 和 =", isOn: $model.config.pageKeysMinus)
                RowDivider()
                SwitchRow(title: "[ 和 ]", subtitle: "打开后打字途中 [ ] 不再出【】", isOn: $model.config.pageKeysBracket)
                RowDivider()
                SwitchRow(title: ", 和 .", subtitle: "打开后打字途中逗号句号用来翻页，要先选词再打标点",
                          isOn: $model.config.pageKeysComma)
                RowDivider()
                SwitchRow(title: "Shift+Tab 和 Tab", isOn: $model.config.pageKeysTab)
            }
        }
        PrefGroup("外观") {
            StepperRow(title: "候选字号", subtitle: "候选框里字的大小（磅），下一次打字时生效",
                       value: $model.config.candidateFontSize, range: 10...40)
        }
        PrefGroup("小技巧") {
            ActionRow(title: "简拼", subtitle: "只打声母也行：bjdx → 北京大学，kyi → 可以，zhch → 支持")
            RowDivider()
            ActionRow(title: "长句分段选", subtitle: "第一个候选不对时，先选开头的词，剩下的接着选")
            RowDivider()
            ActionRow(title: "忘掉学错的词", subtitle: "打字时把光标移到学错的候选上，按 Control+Delete")
        }
        PrefGroup("问题反馈") {
            ActionRow(title: "打开数据目录", subtitle: "设置文件、自定义词、学到的词都在这里",
                      action: { NSWorkspace.shared.open(model.supportDir) }) {
                Image(systemName: "folder").foregroundColor(.secondary)
            }
            RowDivider()
            ActionRow(title: "提交问题", subtitle: "到 GitHub 上告诉我们哪里不好用",
                      action: { NSWorkspace.shared.open(issuesURL) }) {
                Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
            }
        }
    }
}

// MARK: 输入

private let shuangpinSchemes: [(String, String)] = [
    ("自然码", "Ziranma"), ("小鹤双拼", "Xiaohe"), ("微软双拼", "Microsoft"), ("搜狗双拼", "Sogou"),
    ("智能 ABC", "ABC"), ("紫光双拼", "Ziguang"), ("拼音加加", "PinyinJiajia"),
]

private let fuzzyGroups: [(String, WritableKeyPath<WowtypeConfig, Bool>)] = [
    ("z = zh", \.fuzzyZh), ("c = ch", \.fuzzyCh), ("s = sh", \.fuzzySh), ("n = l", \.fuzzyNL),
    ("f = h", \.fuzzyFH), ("r = l", \.fuzzyRL), ("an = ang", \.fuzzyAn), ("ian = iang", \.fuzzyIan),
    ("uan = uang", \.fuzzyUan), ("en = eng", \.fuzzyEn), ("in = ing", \.fuzzyIn), ("un = ong", \.fuzzyUn),
]

private struct InputPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("词库", description: "换词库后几秒内生效，你加的词和输入法学到的习惯都还在。") {
            RadioRow(title: "雾凇拼音（默认）", subtitle: "约 89 万条，在安装包里，跟着 WowType 一起更新",
                     selected: model.config.lexicon.isEmpty) { model.config.lexicon = "" }
            RowDivider()
            RadioRow(title: "自己的词库文件", subtitle: lexiconSubtitle, subtitleColor: lexiconColor,
                     selected: !model.config.lexicon.isEmpty) {
                if model.config.lexicon.isEmpty { model.chooseLexicon() }
            } trailing: {
                Button("选择…") { model.chooseLexicon() }
            }
        }

        PrefGroup("输入方式") {
            RadioRow(title: "拼音输入", subtitle: "全拼，也可以只打声母：bjdx → 北京大学",
                     selected: !model.config.shuangpin) { model.config.shuangpin = false }
            RowDivider()
            RadioRow(title: "双拼输入", subtitle: "每个字两个键，编辑区显示成全拼",
                     selected: model.config.shuangpin) { model.config.shuangpin = true }
            RowDivider()
            PickerRow(title: "双拼方案", selection: $model.config.shuangpinScheme, options: schemeOptions)
                .disabled(!model.config.shuangpin)
        }

        PrefGroup("中英文切换", description: "单按一下 Shift 切到英文，字母和半角标点直接上屏，再按一下回到中文。"
                  + "打到一半切英文，打的字母原样上屏。") {
            PickerRow(title: "切换键", selection: $model.config.shiftToggle,
                      options: [("左右 Shift 都行", .both), ("左 Shift", .left), ("右 Shift", .right), ("不用 Shift 切换", .off)])
        }

        PrefGroup("拼音") {
            ExpanderRow(title: "模糊音", subtitle: "打开后选哪几组音不分，比如 n 和 l 分不清就打开 n = l",
                        enabled: $model.config.fuzzy) {
                ForEach(fuzzyGroups.indices, id: \.self) { i in
                    if i > 0 { RowDivider() }
                    SwitchRow(title: fuzzyGroups[i].0, isOn: $model.config[dynamicMember: fuzzyGroups[i].1])
                }
            }
            RowDivider()
            SwitchRow(title: "按错键自动纠正", subtitle: "比如 zhognguo 也能打出「中国」（全拼时）",
                      isOn: $model.config.typoCorrection)
            RowDivider()
            SwitchRow(title: "繁体字", subtitle: "候选词转成繁体", isOn: $model.config.traditional)
            RowDivider()
            SwitchRow(title: "更多生僻字",
                      subtitle: "候选里也列出极少用的生僻字。系统自带的字体有些显示不了，会是方块，要先装能显示它们的字体（比如花园明朝）",
                      isOn: $model.config.rareExtChars)
            RowDivider()
            PickerRow(title: "标点样式", subtitle: "打中文时标点用中文的（，。）还是英文的（, .）。数字后面的符号总是英文的（3.14）",
                      selection: $model.config.halfwidthPunct, options: [("全角 ，。", false), ("半角 , .", true)])
        }

        PrefGroup("快捷输入") {
            SwitchRow(title: "日期和时间", subtitle: "打 riqi、shijian、xingqi，候选里会多出今天的日期、现在的时间",
                      isOn: $model.config.dateTime)
            RowDivider()
            SwitchRow(title: "计算器", subtitle: "先打 v 再打算式，比如 v1+2*3 出 7，按空格用结果（双拼时不可用）",
                      isOn: $model.config.calculator)
                .disabled(model.config.shuangpin)
            RowDivider()
            PickerRow(title: "分号、引号选词", subtitle: "按 ; 选第 2 个候选，按 ' 选第 3 个。用引号选词后，引号不能再用来隔开拼音",
                      selection: $model.config.selectKeys,
                      options: [("不用", .off), ("分号选第 2 个", .semicolon), ("分号选第 2 个、引号选第 3 个", .semicolonQuote)])
            RowDivider()
            SwitchRow(title: "以词定字", subtitle: "只想要词里的一个字时用：打拼音时按 [ 取第一个字，按 ] 取最后一个字（nihao 按 [ → 你）",
                      isOn: $model.config.pickChar)
            RowDivider()
            ExpanderRow(title: "中英文之间自动加空格",
                        subtitle: "你好Mac → 你好 Mac、第5章 → 第 5 章。只在程序告诉输入法光标前是什么字时加，有些程序里不起作用",
                        enabled: $model.config.autoSpace) {
                SwitchRow(title: "汉字和英文字母之间", isOn: $model.config.autoSpaceLetters)
                RowDivider()
                SwitchRow(title: "汉字和数字之间", isOn: $model.config.autoSpaceDigits)
            }
        }
    }

    private var schemeOptions: [(String, String)] {
        let current = model.config.shuangpinScheme
        if shuangpinSchemes.contains(where: { $0.1 == current }) {
            return shuangpinSchemes
        }
        return shuangpinSchemes + [("其他（\(current)）", current)]
    }

    private var lexiconSubtitle: String {
        let path = model.config.lexicon
        if path.isEmpty {
            return "每行：拼音<TAB>词<TAB>频次"
        }
        return model.customLexiconMissing ? "\(path) 不在，现在用的是自带的词库" : path
    }

    private var lexiconColor: Color? {
        model.customLexiconMissing ? palette.warning : nil
    }
}

// MARK: 表情

private struct EmojiPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PrefGroup("表情") {
            SwitchRow(title: "打字时推荐 emoji", subtitle: "打「开心」「点赞」这类词时，第三个候选是对应的 emoji",
                      isOn: $model.config.emojiSuggest)
        }
    }
}

// MARK: 自定义词

private struct WordsPage: View {
    @ObservedObject var model: SettingsModel
    @FocusState private var wordFocused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("添加自定义词", description: "人名、公司名、常用的长句、邮箱地址都可以加。加进来的词总是排在候选第一个，"
                  + "简拼也能打出来。编码也可以是 mail、addr 这类字母，正好打这几个字母时出现。"
                  + "词里写 \\n 表示换行，比如「四川省\\n宜宾市」。") {
            EntryRow(label: "词") {
                TextField("要加的词", text: $model.newWord)
                    .focused($wordFocused)
                    .onSubmit(add)
            }
            RowDivider()
            EntryRow(label: "编码") {
                TextField("拼音（自动填好，多音字请检查）或字母", text: $model.newCode)
                    .foregroundColor(model.codeIsInvalid ? .red : .primary)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(model.canAddWord ? Palette.green : Color.gray.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!model.canAddWord)
                .help("添加")
            }
        }

        PrefGroup(model.words.isEmpty ? "我的词" : "我的词（\(model.words.count)）") {
            let shown = model.shownWords
            if shown.isEmpty {
                ActionRow(title: model.words.isEmpty ? "还没有自定义词" : "没找到", dim: true)
            } else {
                ForEach(shown.indices, id: \.self) { i in
                    if i > 0 { RowDivider() }
                    WordRow(entry: shown[i]) { model.removeWord(shown[i].word) }
                }
            }
        } trailing: {
            HStack(spacing: 6) {
                if model.words.count > 8 {
                    SearchField(text: $model.search)
                        .frame(width: 160)
                }
                Button(action: model.importWords) { Image(systemName: "square.and.arrow.down").foregroundColor(.secondary) }
                    .buttonStyle(.borderless)
                    .help("从文件导入")
                Button(action: model.exportWords) { Image(systemName: "square.and.arrow.up").foregroundColor(.secondary) }
                    .buttonStyle(.borderless)
                    .help("导出到文件")
            }
        }
    }

    private func add() {
        if model.addWord() {
            wordFocused = true
        }
    }
}

private struct WordRow: View {
    let entry: CustomWords.Entry
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.word.replacingOccurrences(of: "\\n", with: "⏎"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.code)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            Button(action: remove) { Image(systemName: "trash").foregroundColor(.secondary) }
                .buttonStyle(.borderless)
                .help("删除")
        }
        .rowPadding()
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("搜索", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: 分组和行（照 libadwaita 的 PreferencesGroup / ActionRow / SwitchRow / ComboRow / ExpanderRow）

private struct PrefGroup<Content: View, Trailing: View>: View {
    let title: String
    let description: String?
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing
    @Environment(\.palette) private var palette

    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(palette.heading)
                Spacer()
                trailing
            }
            if let description {
                Text(description)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }
            VStack(spacing: 0) { content }
                .background(palette.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.cardBorder, lineWidth: 1))
        }
    }
}

private extension PrefGroup where Trailing == EmptyView {
    init(_ title: String, description: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, description: description, content: content, trailing: { EmptyView() })
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}

private extension View {
    func rowPadding() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 46)
    }
}

private struct RowLabel: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color?
    var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundColor(dim ? .secondary : .primary)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundColor(subtitleColor ?? .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActionRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var dim = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle, dim: dim)
            trailing
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

private extension ActionRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, dim: Bool = false) {
        self.init(title: title, subtitle: subtitle, dim: dim, action: nil, trailing: { EmptyView() })
    }
}

private struct SwitchRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Palette.green)
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { isOn.toggle() } }
    }
}

private struct PickerRow<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    @Binding var selection: Value
    let options: [(String, Value)]

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle)
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].0).tag(options[i].1)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .rowPadding()
    }
}

private struct StepperRow: View {
    let title: String
    var subtitle: String?
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            RowLabel(title: title, subtitle: subtitle)
            Text("\(value)")
                .monospacedDigit()
                .frame(minWidth: 24, alignment: .trailing)
            Stepper("", value: $value, in: range)
                .labelsHidden()
        }
        .rowPadding()
    }
}

private struct RadioRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 16))
                .foregroundColor(selected ? Palette.green : .secondary)
            RowLabel(title: title, subtitle: subtitle, subtitleColor: subtitleColor)
            trailing
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { action() } }
    }
}

private extension RadioRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, subtitleColor: nil, selected: selected, action: action,
                  trailing: { EmptyView() })
    }
}

/// 可以展开的一行。带开关时（模糊音、自动加空格）：开关打开就展开，关上就收起、不能展开（和 libadwaita 一样）。
private struct ExpanderRow<Content: View>: View {
    let title: String
    var subtitle: String?
    var enabled: Binding<Bool>?
    @ViewBuilder var content: Content
    @State private var expanded = false
    @Environment(\.palette) private var palette

    init(title: String, subtitle: String? = nil, enabled: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.enabled = enabled
        self.content = content()
    }

    private var canExpand: Bool { enabled?.wrappedValue ?? true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RowLabel(title: title, subtitle: subtitle)
                if let enabled {
                    Toggle("", isOn: Binding(get: { enabled.wrappedValue }, set: { on in
                        enabled.wrappedValue = on
                        withAnimation(.easeInOut(duration: 0.15)) { expanded = on }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Palette.green)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(expanded && canExpand ? 90 : 0))
                    .opacity(canExpand ? 1 : 0.35)
            }
            .rowPadding()
            .contentShape(Rectangle())
            .onTapGesture {
                if canExpand {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            }
            if expanded && canExpand {
                Divider()
                VStack(spacing: 0) { content }
                    .padding(.leading, 16)
                    .background(palette.nested)
            }
        }
    }
}

private struct EntryRow<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .leading)
            field
                .textFieldStyle(.plain)
        }
        .rowPadding()
    }
}
