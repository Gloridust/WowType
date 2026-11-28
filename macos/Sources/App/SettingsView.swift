// 设置窗口的界面（SwiftUI，macOS 12 起）。
//
// 页面、分组、文字照 Linux 的设置界面（settings/wowtype-config 的 build_general / build_input / build_emoji /
// build_voice / build_translate / build_words），名字和顺序两边一样，选项说明对得上 fcitx5-addon/src/wowtype_engine.h。macOS 还没有的功能
// 不列出来，它们的键在 wowtype.conf 里原样留着。Linux 单独一页的「更新」在 macOS 是「常规」页里的一组。
// 每行一个标题，副标题最多一行；说明、注意事项、例子、来源、许可放进 ⓘ（InfoButton）或「更多选项」折叠里。
// 样子也照 Linux：强调色渐变侧栏、强调色选中块、白色圆角卡片。主题（跟随系统 / 浅色 / 深色）和强调色在
// 「常规 → 设置窗口」里改（SettingsTheme、SettingsAccent，三端一样）：主题由 SettingsAppDelegate 换窗口的外观，
// 强调色用 WowtypeConfig.accentPresets 里的颜色，不自己算。

import AppKit
import AVFoundation
import Combine
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
    var accent = WowtypeConfig.accentPresets[0]

    /// 强调色本身：侧栏的底色、悬停、统计的图
    var accentColor: Color { Color(hex: accent.color) }
    /// 上面放白字的底（选中的导航、按钮、开关），和白字的对比度至少 4.7:1
    var accentStrong: Color { Color(hex: accent.strong) }
    /// 强调色当字用：浅色背景上用 strong，深色背景上用 light（对比度至少 4.5:1）
    var accentText: Color { Color(hex: dark ? accent.light : accent.strong) }

    var sidebar: LinearGradient {
        // 叠在窗口底色（content）上的一层半透明强调色，和 Linux 一样（文字照样是系统的字色，看得清）
        let stops: [Gradient.Stop] = [
            .init(color: accentColor.opacity(dark ? 0.22 : 0.16), location: 0),
            .init(color: accentColor.opacity(dark ? 0.12 : 0.08), location: 0.4),
            .init(color: accentColor.opacity(0.02), location: 1),
        ]
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .top, endPoint: .bottom)
    }
    var content: Color { dark ? Color(hex: 0x1D201F) : Color(hex: 0xF5F7F6) }
    var card: Color { dark ? Color(hex: 0x282C2A) : .white }
    var cardBorder: Color { dark ? Color(hex: 0x3B4144) : Color(hex: 0xE6EAE8) }
    var nested: Color { dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025) }
    // 分组标题：浅色下和底色 #F5F7F6 的对比度 5.2:1（原来的 #6B7570 是 4.4:1）
    var heading: Color { dark ? Color(hex: 0xA3ACA8) : Color(hex: 0x5F6A65) }
    var hover: Color { accentColor.opacity(dark ? 0.16 : 0.12) }
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
        let palette = Palette(dark: scheme == .dark, accent: model.config.accent)
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
        .accentColor(palette.accentStrong)
        .frame(minWidth: 640, minHeight: 460)
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .general: GeneralPage(model: model)
        case .input: InputPage(model: model)
        case .emoji: EmojiPage(model: model)
        case .voice: VoicePage(model: model)
        case .translate: TranslatePage(model: model)
        case .words: WordsPage(model: model)
        case .stats: StatsPage(model: model)
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
        .background(palette.content)
    }
}

/// 设置侧栏「统计」的图标：Tabler layout（矩形 + 三条左对齐横线），
/// 和 Linux 的 icons/hicolor/scalable/status/wowtype-stats-symbolic.svg 是同一份形状。
private struct StatsMenuIcon: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let line = 2 * scale
            let frame = CGRect(x: 3 * scale, y: 3 * scale,
                               width: 18 * scale, height: 18 * scale)
            context.stroke(Path(roundedRect: frame, cornerRadius: 2 * scale),
                           with: .color(color), lineWidth: line)
            // 三条线画成圆角细矩形：macOS 12 的 GraphicsContext.stroke 没有 style 参数，
            // 用 fill 画也能得到圆头线段。
            let cap = line / 2
            let strokes: [(CGFloat, CGFloat, CGFloat)] = [(9, 7, 17), (13, 7, 12), (11, 7, 7)]
            for (from, to, y) in strokes {
                let start = min(from, to) * scale
                let end = max(from, to) * scale
                let rect = CGRect(x: start, y: y * scale - cap,
                                  width: end - start, height: line)
                context.fill(Path(roundedRect: rect, cornerRadius: cap),
                             with: .color(color))
            }
        }
        .frame(width: 16, height: 16)
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
            if page == .stats {
                StatsMenuIcon(color: selected ? .white : .primary)
                    .frame(width: 18)
            } else {
                Image(systemName: page.icon)
                    .frame(width: 18)
            }
            Text(page.title)
            Spacer()
        }
        .font(.system(size: 13, weight: selected ? .semibold : .regular))
        .foregroundColor(selected ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? palette.accentStrong : (hovering ? palette.hover : .clear))
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
/// 系统设置的「键盘」（只打开，不改系统设置）
private let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

/// 两个快捷键行的说明，和 Linux 设置的一样（settings/wowtype-config 的 TOGGLE_KEY_INFO、TRANSLATE_MODE_KEY_INFO）
private let toggleKeyInfo = "按它在中文、英文之间切（在「译」里按回到中文）。单按 Shift 照常能用。"
/// 「翻译」页「双击 Shift 单次互译」的说明（和 Linux 设置的一样，#191）
private let oneShotInfo = "打开后单按 Shift 只在中文、英文之间切；很快连按两下 Shift（或按互译的快捷键）进「译」，只翻这一句："
    + "译文上屏、Esc、Shift+回车或单按 Shift 放弃以后，回到原来的中文或英文。拼音打到一半时连按两下，打的拼音带进「译」接着打。\n\n"
    + "关着时和以前一样：单按 Shift 在 中 → 英 → 译 之间切，连按两下 Shift 不切换。"
private let translateModeKeyInfo = "按它进「译」，在「译」里再按回到原来的模式。设了它，单按 Shift 就只在中文、英文之间切。\n\n"
    + "要先在「翻译」页打开互译；没打开、密码框里这个键交给应用。"
private let systemKeyNote = "\n\n系统的快捷键（比如 Control+空格）先处理，设成它们 WowType 收不到。"

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PrefGroup("候选词") {
            PickerRow(title: "排列方向", selection: $model.config.horizontal,
                      options: [("横排", true), ("竖排", false)])
            RowDivider()
            PickerRow(title: "方向键", subtitle: arrowKeysSubtitle,
                      info: "选「左右键移动光标」时，← → 把光标移进打了一半的拼音，打的字母插在光标处，"
                          + "退格删光标前一个，Home、End、Delete 也管用；↑ ↓ 选词，到了一页的两头接着翻页。"
                          + "翻页用 Page Up / Page Down 或下面的翻页键。「译」里没有光标。",
                      selection: $model.config.arrowKeys,
                      options: [("都用来选词", .candidates), ("左右键移动光标", .caret)])
            RowDivider()
            StepperRow(title: "每页个数", value: $model.config.pageSize, range: 3...9)
            RowDivider()
            ExpanderRow(title: "翻页键", subtitle: "除了 Page Up / Page Down") {
                SwitchRow(title: "- 和 =", isOn: $model.config.pageKeysMinus)
                RowDivider()
                SwitchRow(title: "[ 和 ]", subtitle: "打字途中不再出【】", isOn: $model.config.pageKeysBracket)
                RowDivider()
                SwitchRow(title: ", 和 .", subtitle: "打字途中要先选词再打标点", isOn: $model.config.pageKeysComma)
                RowDivider()
                SwitchRow(title: "Shift+Tab 和 Tab", isOn: $model.config.pageKeysTab)
            }
        }
        PrefGroup("外观") {
            StepperRow(title: "候选字号", value: $model.config.candidateFontSize, range: 10...40)
        }
        // 设置窗口自己的样子（不管候选框），和 Linux、Windows 的设置窗口一样
        PrefGroup("设置窗口") {
            PickerRow(title: "主题", subtitle: "跟随系统，或者固定浅色 / 深色",
                      info: "只改这个设置窗口，不影响候选框。系统是深色、窗口却是浅色（或者反过来），"
                          + "字看不清时，固定成浅色或深色。",
                      selection: $model.config.settingsTheme,
                      options: WowtypeConfig.SettingsTheme.allCases.map { ($0.name, $0) })
            RowDivider()
            PickerRow(title: "强调色", subtitle: "选中的页面、按钮和开关的颜色",
                      selection: $model.config.settingsAccent,
                      options: WowtypeConfig.accentPresets.map { ($0.name, $0.value) })
        }
        UpdateGroup(model: model, updater: model.updater)
        PrefGroup("帮助") {
            ExpanderRow(title: "小技巧") {
                ActionRow(title: "简拼", subtitle: "bjdx → 北京大学，zhch → 支持")
                RowDivider()
                ActionRow(title: "长句分段选", subtitle: "先选开头的词，剩下的接着选")
                RowDivider()
                ActionRow(title: "忘掉学错的词", subtitle: "光标移到候选上，按 Control+Delete")
                RowDivider()
                ActionRow(title: "搜符号", subtitle: "表情面板里打 gou → ✓、youjiantou → →")
                RowDivider()
                ActionRow(title: "互译", subtitle: "单按 Shift 切到「译」，打中文出外文")
            }
            RowDivider()
            ActionRow(title: "打开数据目录", action: { NSWorkspace.shared.open(model.supportDir) }) {
                Image(systemName: "folder").foregroundColor(.secondary)
            }
            RowDivider()
            ActionRow(title: "提交问题", action: { NSWorkspace.shared.open(issuesURL) }) {
                Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
            }
            RowDivider()
            ActionRow(title: "复制诊断信息", subtitle: "版本、数据文件、设置（打码）和最近的日志，贴到问题里",
                      info: "不含你打过的字、自定义词和输入习惯的内容（只有条数和大小）；翻译服务只留主机名，API Key 不在里面。",
                      action: { model.copyDiagnostics() }) {
                Image(systemName: "doc.on.clipboard").foregroundColor(.secondary)
            }
            RowDivider()
            ActionRow(title: "卸载 WowType", subtitle: "自定义词、学到的词和设置会留着",
                      action: { model.confirmUninstall() }) {
                Image(systemName: "trash").foregroundColor(.secondary)
            }
        }
        DeveloperGroup(model: model)
    }

    /// 方向键那一行的副标题：这种用法和候选排列下各个方向键做什么（和 Linux 设置一样）
    private var arrowKeysSubtitle: String {
        switch (model.config.arrowKeys, model.config.horizontal) {
        case (.caret, _): return "↑ ↓ 选词，← → 在拼音里移动光标"
        case (.candidates, true): return "← → 选词，↑ 上一页，↓ 展开更多候选"
        case (.candidates, false): return "↑ ↓ 选词，← → 翻页"
        }
    }
}

/// 「更新」：当前版本 / 有新版本，下载并安装（交给系统的 installer，不要密码），自动检查的开关
private struct UpdateGroup: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var updater: UpdateModel
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("更新", info: "从 GitHub 发布页下载这台 Mac 的安装包（WowType-<版本>-macos.pkg），按同一页的 SHA256SUMS 校验，"
                  + "再交给系统的安装器只装给你自己，不要管理员密码。装的时候输入法和设置窗口会重启一下，装好后设置窗口自动重新打开。\n\n"
                  + "自动检查：输入法每天最多查一次，有新版本时菜单栏的输入法菜单里多一项；打开设置窗口时也查。",
                  links: [("发布页", UpdateInstaller.releasesPage)]) {
            HStack(spacing: 10) {
                RowLabel(title: updater.title, subtitle: updater.subtitle,
                         subtitleColor: updater.error != nil ? palette.warning : nil)
                if let (done, total) = updater.downloadProgress {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 90)
                    Button("取消") { updater.cancelDownload() }
                } else if updater.installing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    if updater.error != nil {
                        Button("打开发布页") { updater.openReleasePage() }
                    }
                    if updater.hasUpdate {
                        Button("下载并安装") { updater.downloadAndInstall() }
                    } else {
                        Button("检查更新") { updater.check() }
                            .disabled(updater.checking)
                    }
                }
            }
            .rowPadding()
            RowDivider()
            SwitchRow(title: "自动检查更新", subtitle: "有新版本时输入法菜单里提示", isOn: $model.config.checkUpdate)
            RowDivider()
            SwitchRow(title: "Beta 计划", subtitle: "也接收预发布版的更新",
                      info: "预发布版（pre-release）先带上新功能给想尝鲜的人试，可能不稳定。"
                          + "关掉以后已经装上的预发布版不会退回，等下一个正式版出来再提示更新。",
                      isOn: $model.config.betaUpdates)
        }
        // 有新版时下面列出「这一版」改了什么（和 Linux 设置「更新」页的「更新内容」一样）
        if updater.hasUpdate, let notes = updater.release.map({ AppUpdate.notesText($0.notes) }), !notes.isEmpty {
            PrefGroup("更新内容") {
                Text(Self.rendered(notes))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
    }

    /// 行内的粗体、行内代码、链接照 Markdown 画；认不出来时原样
    private static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: 输入

private let shuangpinSchemes: [(String, String)] = [
    ("自然码", "Ziranma"), ("小鹤双拼", "Xiaohe"), ("微软双拼", "Microsoft"), ("搜狗双拼", "Sogou"),
    ("智能 ABC", "ABC"), ("紫光双拼", "Ziguang"), ("拼音加加", "PinyinJiajia"),
]

private let fuzzyGroups: [(String, WritableKeyPath<WowtypeConfig, Bool>)] = [
    ("z = zh", \.fuzzyZh), ("c = ch", \.fuzzyCh), ("s = sh", \.fuzzySh), ("n = l", \.fuzzyNL),
    ("f = h", \.fuzzyFH), ("r = l", \.fuzzyRL), ("an = ang", \.fuzzyAn), ("an = ai", \.fuzzyAnAi),
    ("ian = iang", \.fuzzyIan), ("uan = uang", \.fuzzyUan), ("huang = wang", \.fuzzyHuangWang),
    ("en = eng", \.fuzzyEn), ("eng = ong", \.fuzzyEngOng), ("in = ing", \.fuzzyIn), ("un = ong", \.fuzzyUn),
    ("un = iong", \.fuzzyUnIong),
]

private struct InputPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("词库", info: "换词库几秒后生效，自定义词和学到的习惯都会保留。\n\n"
                  + "雾凇拼音在安装包里，跟着 WowType 一起更新。\n\n"
                  + "万象拼音词更多，比雾凇多占约 60 MB 内存；从 amzxyz/rime_wanxiang（CC BY 4.0）转换，只用了它的词条。"
                  + "装在 ~/Library/Application Support/WowType/dicts/wanxiang。",
                  links: [("万象拼音项目主页", URL(string: "https://github.com/amzxyz/rime_wanxiang")!)]) {
            RadioRow(title: "雾凇拼音（默认）", subtitle: "在安装包里，不用下载", selected: model.lexiconKind == .rimeIce) {
                model.useRimeIce()
            }
            .disabled(model.lexiconBusy)
            RowDivider()
            RadioRow(title: "万象拼音", subtitle: wanxiangSubtitle, selected: model.lexiconKind == .wanxiang) {
                if model.lexiconKind != .wanxiang { model.useWanxiang() }
            } trailing: {
                if !model.lexiconBusy {
                    // 发布页上没有万象包时不显示「下载」（和 Linux 一样，可以从文件安装）
                    let noAsset = model.release != nil && model.release?.wanxiang == nil
                    if (model.wanxiangVersion == nil || model.wanxiangUpdate != nil) && !noAsset {
                        Button(model.wanxiangVersion == nil ? "下载" : "更新") { model.installWanxiang() }
                    }
                    IconButton(symbol: "folder", help: "从文件安装（wowtype-data-wanxiang-*.tar.gz）") { model.chooseWanxiangFile() }
                    if model.wanxiangVersion != nil && model.lexiconKind != .wanxiang {
                        IconButton(symbol: "trash", help: "删除万象拼音") { model.removeWanxiang() }
                    }
                }
            }
            .disabled(model.lexiconBusy)
            RowDivider()
            RadioRow(title: "自定义词库", subtitle: lexiconSubtitle, subtitleColor: lexiconColor,
                     selected: model.lexiconKind == .custom) {
                if model.lexiconKind != .custom { model.chooseLexicon() }
            } trailing: {
                Button("选择…") { model.chooseLexicon() }
            }
            .disabled(model.lexiconBusy)
        }
        .onAppear { model.checkRelease() }

        NnlmGroup(nnlm: model.nnlm)

        PrefGroup("输入方案") {
            RadioRow(title: WowtypeConfig.InputScheme.quanpin.name, subtitle: "全拼，也能只打声母", selected: model.config.inputScheme == .quanpin) {
                model.config.inputScheme = .quanpin
            }
            RowDivider()
            RadioRow(title: WowtypeConfig.InputScheme.shuangpin.name, subtitle: "每个字打两个键", selected: model.config.shuangpin) {
                model.config.inputScheme = .shuangpin
            }
            if model.config.shuangpin {
                RowDivider()
                PickerRow(title: "双拼方案", selection: $model.config.shuangpinScheme, options: schemeOptions)
                RowDivider()
                SwitchRow(title: "编辑区显示打的键", subtitle: "不翻成全拼，中英混打时看得出打了什么",
                          isOn: $model.config.shuangpinShowKeys)
                RowDivider()
                SwitchRow(title: "简拼", subtitle: "只打声母也出词，sm 出「什么」；按双拼读得通的排在前面",
                          isOn: $model.config.shuangpinAbbrev)
            }
            RowDivider()
            RadioRow(title: WowtypeConfig.InputScheme.wubi86.name,
                     subtitle: model.wubiTableAvailable ? "86 版，z 键临时打拼音"
                         : "没有找到五笔码表 wubi86.tsv，重新安装 WowType 可以修好",
                     selected: model.config.wubi) {
                model.config.inputScheme = .wubi86
            }
            .disabled(!model.wubiTableAvailable)
            if model.config.wubi {
                RowDivider()
                SwitchRow(title: "四码唯一自动上屏", subtitle: "打满四码、只有一个字词时直接上屏",
                          isOn: $model.config.wubiAutoCommit)
                RowDivider()
                SwitchRow(title: "编码提示", subtitle: "候选后面显示还要打的码", isOn: $model.config.wubiHint)
            }
        }

        // 和 Linux 设置的「默认状态」一样（#254）：换到新窗口、新应用时的中 / 英，标点全角还是半角
        PrefGroup("默认状态", info: "换到新窗口、新应用时用哪种模式。默认「和上次一样」，每个应用记着自己的中英文；"
                  + "选了中文或英文，每次换到新窗口、新应用都先定成它。") {
            PickerRow(title: "默认中/英文", subtitle: "换到新窗口、新应用时；和上次一样就不变",
                      selection: $model.config.windowMode,
                      options: [("和上次一样", .same), ("中文", .chinese), ("英文", .english)])
            RowDivider()
            PickerRow(title: "默认全角/半角", subtitle: "中文标点还是英文标点",
                      info: "数字写法里的符号保持半角，比如 3.14、20:22；顿号、问号照常全角。",
                      selection: $model.config.halfwidthPunct, options: [("全角 ，。", false), ("半角 , .", true)])
        }

        PrefGroup("中英文切换", info: "单按一下 Shift 切到英文，字母和半角标点直接上屏，再按一下回到中文。"
                  + "打到一半切英文，已经打的字母原样上屏。") {
            // macOS 自己的切换：不经过输入法，哪个应用里都管用
            ActionRow(title: "中/英 键（大写锁定键）", subtitle: "系统设置里打开后，在 WowType 和 ABC 之间切，所有应用里都管用",
                      info: "在「系统设置 → 键盘 → 文字输入 → 输入法」点「编辑…」，打开"
                          + "「使用“中/英”键切换“ABC”输入法」（键盘上没有 中/英 键时叫「使用大写锁定键切换“ABC”输入法」）。"
                          + "打开以后按一下这个键在 WowType 和 ABC 之间切。") {
                Button("打开键盘设置") { NSWorkspace.shared.open(keyboardSettingsURL) }
            }
            RowDivider()
            PickerRow(title: "单按 Shift",
                      info: "个别应用（比如一些用 Electron 做的）里单按 Shift 有时不灵，可以用上面的 中/英 键，或者下面另设的快捷键。",
                      selection: $model.config.shiftToggle,
                      options: [("左右 Shift 都行", .both), ("左 Shift", .left), ("右 Shift", .right), ("不用 Shift 切换", .off)])
            RowDivider()
            PickerRow(title: "另设一个切换键", info: toggleKeyInfo + systemKeyNote,
                      selection: shortcutBinding(\.toggleKey),
                      options: shortcutOptions([("不用（单按 Shift 照常）", "")] + shortcuts(Array(Shortcut.toggleKeyPresets.dropFirst())),
                                               current: model.config.toggleKey?.name ?? ""))
            RowDivider()
            PickerRow(title: "互译的快捷键",
                      subtitle: model.config.translateModeKey != nil && !model.translateReady ? "先在「翻译」页打开互译" : nil,
                      info: translateModeKeyInfo + systemKeyNote,
                      selection: shortcutBinding(\.translateModeKey),
                      options: shortcutOptions([("不用", "")] + shortcuts(Array(Shortcut.translateModeKeyPresets.dropFirst())),
                                               current: model.config.translateModeKey?.name ?? ""))
            RowDivider()
            PickerRow(title: "切到 WowType 时", subtitle: "从别的输入法切过来、开机后第一次用时；换窗口见「默认中/英文」",
                      info: "「和上次切走时一样」：每个应用记着自己切走时是中文还是英文。"
                          + "关掉了单按 Shift、也没另设切换键时总是中文（切过去就切不回来了）。",
                      selection: $model.config.initialMode,
                      options: [("中文", .chinese), ("英文", .english), ("和上次切走时一样", .last)])
        }

        PrefGroup("拼音") {
            ExpanderRow(title: "模糊音", subtitle: "比如 n 和 l 不分", enabled: $model.config.fuzzy) {
                ForEach(fuzzyGroups.indices, id: \.self) { i in
                    if i > 0 { RowDivider() }
                    SwitchRow(title: fuzzyGroups[i].0, isOn: $model.config[dynamicMember: fuzzyGroups[i].1])
                }
            }
            RowDivider()
            SwitchRow(title: "按错键自动纠正", subtitle: "zhognguo → 中国（全拼时）", isOn: $model.config.typoCorrection)
            RowDivider()
            SwitchRow(title: "繁体字", isOn: $model.config.traditional)
            RowDivider()
            SwitchRow(title: "更多生僻字", subtitle: "要装能显示它们的字体，比如花园明朝",
                      info: "候选里也列出极少用的生僻字。系统自带的字体一般显示不了，会是方块。",
                      isOn: $model.config.rareExtChars)
            RowDivider()
            SwitchRow(title: "输入框里的拼音用空格分音节", subtitle: "ni hao，不用 ni'hao；候选框里照旧",
                      info: "网页里的代码块（比如 ChatGPT）会把 ' 当引号上色，边打边重画，可能留下半截拼音。遇到这种情况时打开。",
                      isOn: $model.config.inlineSpaceSeparator)
            RowDivider()
            SwitchRow(title: "中文标点自动配对", subtitle: "打（【《「“‘ 时自动补上右半边",
                      info: "中文标点下打左括号、左引号，上屏成对的，光标放到中间；"
                          + "在里面打完再按右半边，跳过补好的那个，不会多出一个。"
                          + "里面空着时按退格，两个一起删。按了方向键、回车，或者点到别处以后照常打字。"
                          + "数字后面的括号照常是英文的。\n\n"
                          + "要应用告诉输入法光标在哪、旁边是什么字；有些程序（比如终端）里不配对，照常一个一个上屏。",
                      isOn: $model.config.autoPairPunct)
        }

        PrefGroup("快捷输入") {
            SwitchRow(title: "日期和时间", subtitle: "打 riqi、shijian、xingqi（五笔前面加 z）", isOn: $model.config.dateTime)
            RowDivider()
            SwitchRow(title: "计算器", subtitle: schemeName.map { "\($0)时打大写 V：V1+2*3 → 7" } ?? "v1+2*3 → 7",
                      isOn: $model.config.calculator)
            RowDivider()
            SwitchRow(title: "工具栏",
                      subtitle: schemeName.map { "\($0)时不可用" } ?? "打 v 再按空格：剪贴板、常用语、符号、表情",
                      // 双拼、五笔时用不了：显示成关着（不改设置，换回全拼还是原来的）
                      isOn: Binding(get: { schemeName == nil && model.config.toolbar },
                                    set: { model.config.toolbar = $0 }))
                .disabled(schemeName != nil)
            RowDivider()
            SwitchRow(title: "记录剪贴板历史", subtitle: "复制的密码也可能被记下",
                      info: "给工具栏里的「剪贴板」用，最多记 20 条，只在内存里，关掉开关或重启输入法就清空。"
                          + "密码管理器标了「不要记」的不记，没标的密码会被记下并显示出来。",
                      isOn: $model.config.clipboardHistory)
            RowDivider()
            PickerRow(title: "分号、引号选词", info: "用引号选词后，引号不能再用来隔开拼音（xi'an）。",
                      selection: $model.config.selectKeys,
                      options: [("不用", .off), ("分号选第 2 个", .semicolon), ("分号选第 2 个、引号选第 3 个", .semicolonQuote)])
            RowDivider()
            SwitchRow(title: "以词定字", subtitle: "按 [ 取第一个字，按 ] 取最后一个字", isOn: $model.config.pickChar)
            RowDivider()
            SwitchRow(title: "联想", subtitle: "上屏以后给出常跟在后面的词，按 Tab 选",
                      info: "联想出来以后接着打字、数字、标点、空格、回车都照常，不会选到联想；"
                          + "按 Tab 进联想行，再用空格、回车或数字上屏，Esc 退出，也可以用鼠标点。五笔、互译和密码框里不出。",
                      isOn: $model.config.association)
            RowDivider()
            ExpanderRow(title: "中英文之间自动加空格", subtitle: "第5章 → 第 5 章",
                        info: "你好Mac → 你好 Mac。只在程序告诉输入法光标前是什么字时加，有些程序（比如终端）里不起作用。",
                        enabled: $model.config.autoSpace) {
                SwitchRow(title: "汉字和英文字母之间", isOn: $model.config.autoSpaceLetters)
                RowDivider()
                SwitchRow(title: "汉字和数字之间", isOn: $model.config.autoSpaceDigits)
            }
        }
        SyncGroup(model: model)
    }

    /// 快捷键下拉框选的键名（同 wowtype.conf）；空串是不用
    private func shortcutBinding(_ path: WritableKeyPath<WowtypeConfig, Shortcut?>) -> Binding<String> {
        Binding(get: { model.config[keyPath: path]?.name ?? "" },
                set: { model.config[keyPath: path] = $0.isEmpty ? nil : Shortcut(name: $0) })
    }

    /// 双拼、五笔时 v 是字母键（计算器换大写 V、工具栏不开）：副标题里说是哪个；全拼是 nil。
    private var schemeName: String? {
        model.config.inputScheme == .quanpin ? nil : model.config.shuangpin ? "双拼" : "五笔"
    }

    private var schemeOptions: [(String, String)] {
        let current = model.config.shuangpinScheme
        if shuangpinSchemes.contains(where: { $0.1 == current }) {
            return shuangpinSchemes
        }
        return shuangpinSchemes + [("其他（\(current)）", current)]
    }

    /// 和 Linux 设置里的一样：装了的版本、有没有新版、下载进度
    private var wanxiangSubtitle: String {
        if let progress = model.lexiconProgress {
            return progress
        }
        if let version = model.wanxiangVersion {
            return "已下载 \(version)" + (model.wanxiangUpdate.map { "，有新版 \($0)" } ?? "")
        }
        if let release = model.release, release.wanxiang == nil {
            return "暂时没有下载包，可以从文件安装"
        }
        return "词更多，要下载约 20 MB"
    }

    /// 没选时不写（文件格式在选文件的对话框里说）
    private var lexiconSubtitle: String? {
        guard model.lexiconKind == .custom else { return nil }
        let path = model.config.lexicon
        return model.customLexiconMissing ? "找不到 \(path)，现在用的是雾凇拼音" : path
    }

    private var lexiconColor: Color? {
        model.lexiconKind == .custom && model.customLexiconMissing ? palette.warning : nil
    }
}

/// 开发者模式（docs/DEVLOG.md，和 Linux 设置的「常规 → 开发者」一样）：默认关，打开要先确认——记下来的是
/// 明文的打字记录；记录能导出、清空。只有输入法写记录文件，这里只看条数和大小。
private struct DeveloperGroup: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmOn = false
    @State private var confirmClear = false
    @State private var status = ""
    @State private var hasRecords = false
    @State private var hasFiles = false
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var path: String {
        model.supportDir.appendingPathComponent(DevLog.fileName).path
    }

    var body: some View {
        PrefGroup("开发者", info: DevLog.info) {
            SwitchRow(title: "开发者模式", subtitle: "把打的字、候选和选了第几个明文记在本机，调试用",
                      isOn: Binding(get: { model.config.developerMode },
                                    set: { on in
                                        if on {
                                            // 先不打开：点了「打开，开始记录」才真的打开
                                            confirmOn = true
                                        } else {
                                            model.config.developerMode = false
                                            reload()
                                        }
                                    }))
                .alert("打开开发者模式？", isPresented: $confirmOn) {
                    Button("打开，开始记录") {
                        model.config.developerMode = true
                        reload()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(DevLog.warning)
                }
            RowDivider()
            ActionRow(title: "打字记录", subtitle: status) {
                Button("导出…") { export() }
                    .disabled(!hasRecords)
                Button("清空", role: .destructive) { confirmClear = true }
                    .disabled(!hasFiles)
            }
            .confirmationDialog("清空打字记录？", isPresented: $confirmClear) {
                Button("清空", role: .destructive) { clear() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已经记下的都会删掉，不能恢复。开关保持现在的位置。")
            }
        }
        .onAppear { reload() }
        .onReceive(tick) { _ in reload() }
    }

    private func reload() {
        status = DevLog.statusText(path: path, enabled: model.config.developerMode)
        hasRecords = DevLog.summary(path).count > 0
        hasFiles = !DevLog.files(path).isEmpty
    }

    private func clear() {
        model.showToast(DevLog.clear(path: path) ? "打字记录已清空" : "清空失败")
        reload()
    }

    private func export() {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "wowtype-devlog-\(stamp.string(from: Date())).jsonl"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try DevLog.export(from: path, to: url.path)
            model.showToast("\(count) 条打字记录已保存（明文，别随手发给别人）")
        } catch {
            model.showToast("导出失败：\(error.localizedDescription)")
        }
    }
}

/// 跨设备复制粘贴（docs/SYNC.md）：开关、配对（显示配对码 / 输入配对码 / 取消配对），中转服务这些收进
/// 「更多选项」。和 Linux 设置的一样；配对的状态在 SyncSettings。
private struct SyncGroup: View {
    @ObservedObject var model: SettingsModel
    @StateObject private var sync = SyncSettings()
    @State private var code = ""
    @State private var token = ""

    private static let guide = URL(string: "https://github.com/Gloridust/WowType/tree/main/relay/cloudflare")!

    var body: some View {
        PrefGroup("跨设备复制粘贴",
                  info: "一台电脑上复制的文字，在另一台装了 WowType 的电脑上直接粘贴：按 Command+V，"
                      + "或者打 v 再按空格，在「剪贴板」里选。只传文字（最多 16 KB），不传图片和文件。\n\n"
                      + "没有账号，也不经过 WowType 的服务器。两台设备用 6 位配对码配一次对，之后的内容都在设备上加密，"
                      + "只有配过对的设备解得开。\n\n"
                      + "同一个局域网里设备之间直接传（防火墙要放行 39217 端口的 UDP 和 TCP）。"
                      + "不在同一个局域网时，可以自己部署一个中转服务（Cloudflare Worker，免费套餐够用），它只看得到密文。\n\n"
                      + "密码管理器标了「不要记」的不传，没标的密码会被传过去。",
                  links: [("怎么部署中转服务", Self.guide)]) {
            SwitchRow(title: "跨设备复制粘贴", isOn: $model.config.clipboardSync)
            RowDivider()
            HStack(spacing: 8) {
                RowLabel(title: "配对", subtitle: sync.summary)
                Button(sync.hosting ? "取消" : "显示配对码") {
                    sync.toggleCode(config: model.config) { model.showToast($0) }
                }
                .disabled(sync.busy)
                if sync.paired && !sync.hosting {
                    Button("取消配对") { sync.unpair { model.showToast($0) } }
                        .disabled(sync.busy)
                }
            }
            .rowPadding()
            RowDivider()
            HStack(spacing: 8) {
                RowLabel(title: "输入另一台设备上显示的配对码")
                TextField("6 位数字", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit(join)
                Button("配对", action: join)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .rowPadding()
            .disabled(sync.hosting || sync.busy)
            RowDivider()
            ExpanderRow(title: "更多选项") {
                SwitchRow(title: "同一个局域网里直接传", isOn: $model.config.clipboardSyncLan)
                RowDivider()
                TextRow(title: "中转服务地址", subtitle: "不用就留空", placeholder: "https://…",
                        text: trimmed(\.clipboardSyncRelayUrl))
                RowDivider()
                HStack(spacing: 8) {
                    RowLabel(title: "中转服务的访问口令", subtitle: sync.tokenSet ? "已设置（不显示）" : nil)
                    SecureField(sync.tokenSet ? "换一个" : "部署时设的口令", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit(saveToken)
                    Button("保存", action: saveToken)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if sync.tokenSet {
                        Button("删除") { sync.setToken("") { model.showToast($0) } }
                    }
                }
                .rowPadding()
                RowDivider()
                HStack(spacing: 8) {
                    RowLabel(title: "测试中转服务", subtitle: sync.pingResult)
                    Button("测试") { sync.ping(config: model.config) }
                        .disabled(sync.busy)
                }
                .rowPadding()
                RowDivider()
                TextRow(title: "这台设备的名字", placeholder: sync.defaultName,
                        text: trimmed(\.clipboardSyncDeviceName))
                RowDivider()
                SwitchRow(title: "收到的放进系统剪贴板", subtitle: "关掉以后只出现在 v + 空格的「剪贴板」里",
                          isOn: $model.config.clipboardSyncPaste)
            }
        }
    }

    private func join() {
        sync.join(code: code, config: model.config, toast: { model.showToast($0) }, done: { code = "" })
    }

    private func saveToken() {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        sync.setToken(value) { model.showToast($0) }
        token = ""
    }

    private func trimmed(_ path: WritableKeyPath<WowtypeConfig, String>) -> Binding<String> {
        Binding(get: { model.config[keyPath: path] },
                set: { model.config[keyPath: path] = $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }
}

/// 整句增强模型：一行状态，「导入…」，导入过的能删，安装包自带的不能删（和 Linux 设置的一样）
private struct NnlmGroup: View {
    @ObservedObject var nnlm: NnlmModel
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("整句增强", info: "整句增强模型是一个按字预测下一个字的小模型，"
                  + "WowType 用它给整句候选重排，长句的首选更准，每次按键多 2 毫秒左右。"
                  + "安装包自带 WowType 自己训的（nnlm.bin，用 LCCC 和中文维基训练，CC BY-SA 4.0）。\n\n"
                  + "也可以导入微信输入法自带的（\(NnlmInstaller.fileName)，效果相近），导入了就先用它。"
                  + "模型属于腾讯，WowType 不分发它。手上有微信输入法 macOS 版的安装包（.zip）或装好的 WeType.app 时，"
                  + "点「导入…」选它，也可以直接选模型文件。导入后几秒生效，"
                  + "放在 ~/Library/Application Support/WowType/wetype；删掉以后换回自带的。") {
            HStack(spacing: 10) {
                RowLabel(title: "整句增强模型", subtitle: nnlm.status,
                         subtitleColor: nnlm.error != nil && !nnlm.busy ? palette.warning : nil)
                if nnlm.busy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("导入…") { nnlm.choose() }
                    if nnlm.imported {
                        IconButton(symbol: "trash", help: "删除导入的模型") { nnlm.remove() }
                    }
                }
            }
            .rowPadding()
        }
    }
}

// MARK: 表情

private struct EmojiPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        PrefGroup("表情") {
            SwitchRow(title: "打字时推荐 emoji", subtitle: "打「开心」「点赞」时，候选里有对应的 emoji",
                      isOn: $model.config.emojiSuggest)
            RowDivider()
            PickerRow(title: "表情面板快捷键",
                      info: "按快捷键打开表情面板，打拼音或英文搜 emoji 和符号（xiao、pizza、youjiantou），"
                          + "方向键挑，空格或回车上屏，Esc 关闭。打了一半的拼音再按快捷键，直接拿它来搜。\n\n"
                          + "Command 组合键多半被程序的菜单先拿走，所以用 Control。",
                      selection: emojiKey, options: emojiKeyOptions)
        }
    }

    /// 键名同 wowtype.conf 的 EmojiKey；空串是不用快捷键
    private var emojiKey: Binding<String> {
        Binding(get: { model.config.emojiKey?.name ?? "" },
                set: { model.config.emojiKey = $0.isEmpty ? nil : Shortcut(name: $0) })
    }

    private var emojiKeyOptions: [(String, String)] {
        shortcutOptions(shortcuts(["Control+period", "Control+semicolon", "Control+Shift+E"]) + [("不用快捷键", "")],
                        current: emojiKey.wrappedValue)
    }
}

/// 快捷键（键名同 wowtype.conf）配上 Mac 键盘上的叫法：Control + .、Option + X
private func shortcuts(_ names: [String]) -> [(String, String)] {
    names.map { (Shortcut(name: $0)?.label ?? $0, $0) }
}

/// 设置文件里写的不是预设的快捷键：加一项「其他（Option + X）」
private func shortcutOptions(_ options: [(String, String)], current: String) -> [(String, String)] {
    options.contains { $0.1 == current } ? options : options + [("其他（\(shortcuts([current])[0].0)）", current)]
}

// MARK: 语音

/// 和 Linux 设置的「语音」页一样：开关、语音键、复制到剪贴板，下面是识别模型。没有模型时开关灰掉、显示成关着。
private struct VoicePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let ready = model.voiceModelReady
        PrefGroup("语音输入", info: "按住语音键说话，松开就上屏；或者点一下语音键开始说，停顿一会儿自动上屏。"
                  + "说的时候按 Esc 取消。正在打拼音时语音键不起作用。\n\n"
                  + "右 Option 按下时就开始听，Option+方向键这类组合会让麦克风亮一下就停；不想这样可以换成别的键。"
                  + "F8–F10 在 Mac 笔记本上默认是媒体键，要在「系统设置 → 键盘」里打开「将 F1、F2 等键用作标准功能键」。") {
            SwitchRow(title: "语音输入", subtitle: ready ? nil : "先在下面下载语音模型",
                      isOn: Binding(get: { ready && model.config.voice }, set: { model.config.voice = $0 }))
                .disabled(!ready)
            RowDivider()
            PickerRow(title: "语音键", selection: $model.config.voiceKey, options: voiceKeyOptions)
                .disabled(!ready || !model.config.voice)
            RowDivider()
            PickerRow(title: VoiceSilence.title, subtitle: VoiceSilence.info,
                      selection: $model.config.voiceSilenceTimeout,
                      options: VoiceSilence.options(current: model.config.voiceSilenceTimeout))
                .disabled(!ready || !model.config.voice)
            RowDivider()
            SwitchRow(title: "同时复制到剪贴板", isOn: $model.config.voiceCopy)
                .disabled(!ready || !model.config.voice)
        }
        PrefGroup("识别模型", info: "在本机识别，录音不上传。语音模型是微信输入法的离线语音包，属于腾讯，"
                  + "从腾讯的服务器下载，WowType 不分发它；和这台电脑装没装微信输入法无关。\n\n"
                  + "模型放在 ~/Library/Application Support/WowType/wtlocal。第一次用语音时系统会问要不要允许 WowType 使用麦克风；"
                  + "WowType 每次更新后系统可能会再问一次。") {
            HStack(spacing: 10) {
                RowLabel(title: "语音模型", subtitle: model.voiceModelStatus)
                if let (done, total) = model.voiceProgress {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 90)
                    Button("取消") { model.cancelVoiceDownload() }
                } else if ready {
                    IconButton(symbol: "trash", help: "删除语音模型（语音输入会关掉）") { model.removeVoiceModel() }
                } else {
                    Button(model.voiceError == nil ? "下载" : "重试") { model.downloadVoiceModel() }
                }
            }
            .rowPadding()
            RowDivider()
            MicrophoneRow()
        }
    }

    /// 键名同 wowtype.conf 的 VoiceKey（fcitx5 键名）；Linux 拷过来的 Mac 上没有的键（Menu）单独列出来
    private var voiceKeyOptions: [(String, String)] {
        let options = VoiceKey.presets.map { ($0.label, $0.name) }
        let current = model.config.voiceKey
        if options.contains(where: { $0.1 == current }) { return options }
        let label = current.isEmpty ? "不用语音键"
            : VoiceKey(name: current) == nil ? "\(current)（Mac 上没有这个键）" : "其他（\(current)）"
        return options + [(label, current)]
    }
}

/// 系统设置「隐私与安全性 → 麦克风」（只打开，不改系统设置）
private let microphoneSettingsURL =
    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

/// 麦克风权限：设置窗口和输入法是同一个程序，这里允许了输入法也能用。被拒了给按钮打开系统设置；
/// 从系统设置切回来时重新看一眼。
private struct MicrophoneRow: View {
    @State private var status = AVCaptureDevice.authorizationStatus(for: .audio)
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            RowLabel(title: "麦克风", subtitle: subtitle, subtitleColor: denied ? palette.warning : nil)
            if status == .notDetermined {
                Button("允许使用…") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { refresh() }
                    }
                }
            } else if denied {
                Button("打开系统设置") { NSWorkspace.shared.open(microphoneSettingsURL) }
            }
        }
        .rowPadding()
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        status = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private var denied: Bool { status == .denied || status == .restricted }

    private var subtitle: String {
        switch status {
        case .authorized: return "已允许"
        case .notDetermined: return "还没问过：第一次说话时系统会问"
        case .restricted: return "被系统限制了（家长控制或描述文件），WowType 用不了麦克风"
        default: return "没允许：在「系统设置 → 隐私与安全性 → 麦克风」里打开 WowType"
        }
    }
}

// MARK: 翻译

/// 和 Linux 设置里的一样：名字、接口地址、模型框空着时建议的模型。列表在 Shared/Config.swift，
/// 按键测试对照 spec/config.json
private let translateProviders = WowtypeConfig.translateProviders

private let translateLanguages = WowtypeConfig.translateLanguages

private struct TranslatePage: View {
    @ObservedObject var model: SettingsModel
    @State private var key = ""
    @State private var showModels = false
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("互译", info: "单按 Shift 切到「译」，照常打中文，停一下就翻成外文。"
                  + "回车用译文，Shift+回车用原文，Esc 取消。打的是外文就翻成中文。") {
            SwitchRow(title: "互译", subtitle: translateStatus, isOn: $model.config.translate)
            RowDivider()
            SwitchRow(title: "双击 Shift 单次互译", subtitle: "单按 Shift 只切中英，翻完一句自动回来",
                      info: oneShotInfo, isOn: $model.config.translateOneShot)
            RowDivider()
            PickerRow(title: "翻译成", info: "中文翻成这种语言；这种语言（和别的外文）翻成中文。",
                      selection: $model.config.translateTarget, options: translateLanguages)
            RowDivider()
            SwitchRow(title: "正式语气", subtitle: "默认是聊天的口吻", isOn: $model.config.translateFormal)
            RowDivider()
            // 翻译引擎：选哪个下面就出现哪个的设置（和 Linux 设置一样）。选中的是哪个从配置推出来
            PickerRow(title: "翻译引擎", subtitle: model.config.translateEngine.note,
                      selection: $model.translateEngine,
                      options: WowtypeConfig.TranslateEngine.allCases.map { ($0.name, $0) })
        }
        switch model.config.translateEngine {
        case .local:
            localGroup
        case .bilibili:
            bilibiliGroup
        case .custom:
            serviceGroup
        }
    }

    /// 「互译」那一行的状态（和 Linux 设置一样）：还差什么、Shift 关掉了切不到「译」、怎么切
    private var translateStatus: String {
        if !model.translateConfigured {
            return model.config.translateLocal ? "先在下面下载翻译模型" : "先在下面填好翻译服务"
        }
        let oneShot = model.config.translateOneShot
        if let key = model.config.translateModeKey {
            return "按 \(key.label) 进出「译」" + (oneShot && model.config.shiftToggle != .off ? "，双击 Shift 也行" : "")
        }
        if model.config.shiftToggle == .off {
            return "「输入」页关掉了 Shift 切换，切不到「译」；可以在那里设一个互译的快捷键"
        }
        return oneShot ? "双击 Shift 翻一句，单按只切中英" : "单按 Shift：中 → 英 → 译 → 中"
    }

    private var serviceGroup: some View {
        PrefGroup("翻译服务", info: "选一家服务商，填它给你的 Key，再挑一个模型。翻译要等服务回话，"
                  + "名字里带 mini、flash、turbo 的小模型更快。\n\n"
                  + "隐私：只在切到「译」时把打的字发给你选的服务，密码框里不翻译；WowType 自己不经手、不收集。"
                  + "Key 只存在这台电脑上（~/Library/Application Support/WowType/translate.key，只有你能读）。") {
            PickerRow(title: "服务商", selection: provider, options: translateProviders.map { ($0.name, $0.name) })
            RowDivider()
            TextRow(title: "接口地址", placeholder: "https://…/v1", text: trimmed(\.translateBaseUrl))
            RowDivider()
            HStack(spacing: 8) {
                RowLabel(title: "API Key", subtitle: model.translateKeySet ? "已设置（不显示）" : "本机服务可以不填")
                SecureField(model.translateKeySet ? "换一个" : "粘贴 Key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(saveKey)
                Button("保存", action: saveKey)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.translateKeySet {
                    Button("删除") { model.setTranslateKey("") }
                }
            }
            .rowPadding()
            RowDivider()
            HStack(spacing: 12) {
                RowLabel(title: "模型")
                TextField(suggestedModel.isEmpty ? "服务商给的模型名" : suggestedModel, text: trimmed(\.translateModel))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 252)
                IconButton(symbol: "list.bullet", help: "从服务里挑模型") { showModels = true }
                    .popover(isPresented: $showModels, arrowEdge: .bottom) {
                        ModelPicker(model: model, pick: { picked in
                            model.config.translateModel = picked
                            showModels = false
                        })
                    }
            }
            .rowPadding()
            RowDivider()
            testRow
        }
    }

    private var testRow: some View {
        ActionRow(title: "测试连接", subtitle: model.translateTestResult ?? "用「你好」试一下") {
            if model.translateTesting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("测试") { model.testTranslate() }
            }
        }
    }

    /// 选了哔哩哔哩：挑模型、测试连接，组标题下面一行隐私说明；不用填 Key
    private var bilibiliGroup: some View {
        PrefGroup("哔哩哔哩 Index-Translate", description: WowtypeConfig.bilibiliPrivacy + "。",
                  info: "哔哩哔哩开源的翻译模型 Index-Translate，官方提供免费的公开接口，不用注册、不用 API Key。"
                  + "2B 最快；9B 译得更好一点，稍慢；35B-A3B 是预览版。\n\n"
                  + "隐私：只在切到「译」时把打的字发给哔哩哔哩，密码框里不翻译；WowType 自己不经手、不收集。"
                  + "不会带上「自定义翻译服务」里存的 Key。",
                  links: [("Index-Translate 项目主页", URL(string: "https://github.com/bilibili/Index-Translate")!)]) {
            PickerRow(title: "模型", selection: bilibiliModel, options: bilibiliModelOptions)
            RowDivider()
            testRow
        }
    }

    /// 哔哩哔哩的模型：空着算 2B
    private var bilibiliModel: Binding<String> {
        Binding(get: {
            model.config.translateModel.isEmpty ? WowtypeConfig.bilibiliDefaultModel : model.config.translateModel
        }, set: { id in
            model.config.translateModel = id
        })
    }

    /// 配置文件里手写了别的模型也列出来，不悄悄换掉（和 Linux 设置一样）
    private var bilibiliModelOptions: [(String, String)] {
        var options = WowtypeConfig.bilibiliModels.map { ($0.name, $0.id) }
        let current = model.config.translateModel
        if !current.isEmpty && !options.contains(where: { $0.1 == current }) {
            options.append((current, current))
        }
        return options
    }

    /// 选了本地模型：一行状态（下载 / 进度 / 已就绪），别的都收进「更多选项」；说明和许可在组标题旁的 ⓘ
    private var localGroup: some View {
        PrefGroup("离线翻译模型", info: "腾讯混元的翻译模型 Hy-MT3。翻译时占 2 GB 左右内存，一会儿不用就自动释放。"
                  + "找不到 llama-server 时一起下载 llama.cpp 官方的（MIT 许可）。\n\n" + LocalModel.terms,
                  links: [("许可全文", URL(string: LocalModel.license)!)]) {
            LocalModelRow(model: model)
            RowDivider()
            ExpanderRow(title: "更多选项") {
                TextRow(title: "模型文件", placeholder: "留空用数据目录里的", text: trimmed(\.translateLocalModel))
                RowDivider()
                TextRow(title: "llama-server", subtitle: model.localServerSummary, placeholder: "留空自动找",
                        text: trimmed(\.translateLlamaServer))
                RowDivider()
                StepperRow(title: "闲置几分钟后释放内存", subtitle: "0 表示一直留着",
                           value: $model.config.translateIdleMinutes, range: 0...240)
                if model.localDeletable {
                    RowDivider()
                    ActionRow(title: "删除模型", info: "连同 WowType 下载的 llama-server 一起删；Homebrew 装的、"
                              + "自己写了位置的模型不动。") {
                        Button("删除") { model.removeLocalModel() }
                            .disabled(model.localBusy)
                    }
                }
            }
        }
    }

    /// 服务商：接口地址是哪家的就选哪家；换服务商时填上它的地址，模型框空着就填上建议的模型
    private var provider: Binding<String> {
        Binding(get: {
            let url = model.config.translateBaseUrl
            return translateProviders.first { !$0.url.isEmpty && $0.url == url }?.name ?? translateProviders.last!.name
        }, set: { name in
            guard let p = translateProviders.first(where: { $0.name == name }), !p.url.isEmpty else { return }
            model.config.translateBaseUrl = p.url
            if model.config.translateModel.isEmpty {
                model.config.translateModel = p.model
            }
        })
    }

    private var suggestedModel: String {
        translateProviders.first { $0.url == model.config.translateBaseUrl }?.model ?? ""
    }

    private func trimmed(_ path: WritableKeyPath<WowtypeConfig, String>) -> Binding<String> {
        Binding(get: { model.config[keyPath: path] },
                set: { model.config[keyPath: path] = $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private func saveKey() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model.setTranslateKey(value)
        key = ""
    }
}

/// 「从服务里挑模型」的小窗：搜索框、提示、服务列出来的模型，点一个填进模型框（和 Linux 设置的模型弹出框一样）。
private struct ModelPicker: View {
    @ObservedObject var model: SettingsModel
    let pick: (String) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("搜模型", text: $query)
                .textFieldStyle(.roundedBorder)
            if let status = model.translateModelsStatus {
                Text(status)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.self) { id in
                        Button(action: { pick(id) }) {
                            Text(id)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 280)
        }
        .padding(8)
        .frame(width: 320)
        .onAppear { model.loadTranslateModels() }
    }

    /// 按搜索框筛（不分大小写）
    private var shown: [String] {
        let all = model.translateModels ?? []
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.lowercased().contains(q) }
    }
}

/// 本地模型那一行：没下载给「下载」和大小，下载中给进度和「取消」，好了写「已就绪」；
/// 还在用上一代模型时给「升级」。
private struct LocalModelRow: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        let plan = model.localPlan
        HStack(spacing: 10) {
            RowLabel(title: "翻译模型", subtitle: problem(plan), subtitleColor: palette.warning)
            if let progress = model.localProgress {
                ProgressView(value: Double(progress.percent), total: 100)
                    .frame(width: 90)
                Text(status(progress))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Button("取消") { model.cancelLocalDownload() }
            } else if plan.canUpgrade {
                Text("在用上一代的 \(LocalModel.legacyName)，可以升级到 Hy-MT3（\(LocalModel.sizeText(LocalModel.size))）")
                    .foregroundColor(.secondary)
                Button("升级") { model.downloadLocalModel() }
            } else if plan.ready {
                Label("已就绪", systemImage: "checkmark.circle.fill")
                    .foregroundColor(palette.accentText)
            } else if plan.canDownload {
                Text((plan.llamaOutdated && !plan.wantModel ? "llama-server 要更新，" : "要下载 ")
                     + LocalModel.sizeText(plan.bytes))
                    .foregroundColor(.secondary)
                Button("下载") { model.downloadLocalModel() }
            }
        }
        .rowPadding()
    }

    private func status(_ progress: LocalModelInstaller.Progress) -> String {
        switch progress.stage {
        case .connecting: return "正在连接…"
        case .model, .llama: return "下载中 \(progress.percent)%"
        case .unpacking: return "正在安装…"
        }
    }

    /// 只在有问题时写一行：上次没下完的原因、llama-server 下载不了
    private func problem(_ plan: LocalModel.Plan) -> String? {
        if model.localBusy { return nil }
        if let error = model.localError { return error }
        guard plan.llamaUnavailable else { return nil }
        return model.config.translateLlamaServer.isEmpty
            ? "还差 llama-server：要 macOS 13.3 以上才能下载，或者自己装 llama.cpp"
            : "「更多选项」里写的 llama-server 不在"
    }
}

// MARK: 自定义词

private struct WordsPage: View {
    @ObservedObject var model: SettingsModel
    @FocusState private var wordFocused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        PrefGroup("添加自定义词", info: "人名、公司名、常用的长句、邮箱地址都可以加。加进来的词总排在候选第一个，"
                  + "简拼也能打出来。\n\n编码按词自动填好拼音，多音字请检查；也可以是 mail、addr 这类字母，"
                  + "正好打这几个字母时出现。\n\n词里写 \\n 表示换行，比如「四川省\\n宜宾市」。") {
            EntryRow(label: "词") {
                TextField("要加的词", text: $model.newWord)
                    .focused($wordFocused)
                    .onSubmit(add)
            }
            RowDivider()
            EntryRow(label: "编码") {
                TextField("拼音或字母", text: $model.newCode)
                    .foregroundColor(model.codeIsInvalid ? .red : .primary)
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(model.canAddWord ? palette.accentStrong : Color.gray.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!model.canAddWord)
                .help("添加")
            }
        }

        PrefGroup(model.words.isEmpty ? "已添加" : "已添加（\(model.words.count)）") {
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
                IconButton(symbol: "square.and.arrow.down", help: "从文件导入", action: model.importWords)
                IconButton(symbol: "square.and.arrow.up", help: "导出到文件", action: model.exportWords)
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
                Text(CustomWords.shown(entry.word))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.code)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 12)
            IconButton(symbol: "trash", help: "删除", action: remove)
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
//
// 页面上只放标题和最多一行的副标题。说明、注意事项、例子、来源、许可这类放进 ⓘ：
//   - 组：PrefGroup("词库", info: "…", links: [("项目主页", url)]) { … }，ⓘ 在组标题右边
//   - 行：SwitchRow / PickerRow / RadioRow / ActionRow / ExpanderRow 的 info: "…"，ⓘ 在开关、下拉框前面
//   - 别的地方：InfoButton("…", links: […]) 直接放
// Linux 那边对应的是 SettingsWindow.info_button / add_info（settings/wowtype-config）。

/// ⓘ 小按钮，点开弹出说明文字（可以选中拷贝），links 是说明下面的链接。
private struct InfoButton: View {
    let text: String
    var links: [(String, URL)] = []
    @State private var shown = false

    init(_ text: String, links: [(String, URL)] = []) {
        self.text = text
        self.links = links
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
        }
        .buttonStyle(.borderless)
        .help("说明")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(links.indices, id: \.self) { i in
                    Link(links[i].0, destination: links[i].1)
                }
            }
            .font(.callout)
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}

/// 只有图标的小按钮（从文件安装、删除、导入导出），鼠标停上去显示 help
private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).foregroundColor(.secondary) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

private struct PrefGroup<Content: View, Trailing: View>: View {
    let title: String
    let description: String?
    let info: String?
    let links: [(String, URL)]
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing
    @Environment(\.palette) private var palette

    init(_ title: String, description: String? = nil, info: String? = nil, links: [(String, URL)] = [],
         @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.info = info
        self.links = links
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
                if let info {
                    InfoButton(info, links: links)
                }
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
    init(_ title: String, description: String? = nil, info: String? = nil, links: [(String, URL)] = [],
         @ViewBuilder content: () -> Content) {
        self.init(title, description: description, info: info, links: links, content: content,
                  trailing: { EmptyView() })
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
    var info: String?
    var dim = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle, dim: dim)
            if let info { InfoButton(info) }
            trailing
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}

private extension ActionRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, info: String? = nil, dim: Bool = false) {
        self.init(title: title, subtitle: subtitle, info: info, dim: dim, action: nil, trailing: { EmptyView() })
    }
}

private struct SwitchRow: View {
    let title: String
    var subtitle: String?
    var info: String?
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle)
            if let info { InfoButton(info) }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(palette.accentStrong)
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { isOn.toggle() } }
    }
}

private struct PickerRow<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    var info: String?
    @Binding var selection: Value
    let options: [(String, Value)]

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle)
            if let info { InfoButton(info) }
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
    var info: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 16))
                .foregroundColor(selected ? palette.accentStrong : .secondary)
            RowLabel(title: title, subtitle: subtitle, subtitleColor: subtitleColor)
            if let info { InfoButton(info) }
            trailing
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { action() } }
    }
}

private extension RadioRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, info: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.init(title: title, subtitle: subtitle, subtitleColor: nil, info: info, selected: selected, action: action,
                  trailing: { EmptyView() })
    }
}

/// 可以展开的一行。带开关时（模糊音、自动加空格）：开关打开就展开，关上就收起、不能展开（和 libadwaita 一样）。
/// 不带开关的当「更多选项」「小技巧」这类折叠用。
private struct ExpanderRow<Content: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    var enabled: Binding<Bool>?
    @ViewBuilder var content: Content
    @State private var expanded = false
    @Environment(\.palette) private var palette

    init(title: String, subtitle: String? = nil, info: String? = nil, enabled: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.info = info
        self.enabled = enabled
        self.content = content()
    }

    private var canExpand: Bool { enabled?.wrappedValue ?? true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RowLabel(title: title, subtitle: subtitle)
                if let info { InfoButton(info) }
                if let enabled {
                    Toggle("", isOn: Binding(get: { enabled.wrappedValue }, set: { on in
                        enabled.wrappedValue = on
                        withAnimation(.easeInOut(duration: 0.15)) { expanded = on }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(palette.accentStrong)
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

private struct TextRow: View {
    let title: String
    var subtitle: String?
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            RowLabel(title: title, subtitle: subtitle)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
        }
        .rowPadding()
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

// MARK: 统计

private struct StatsPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.palette) private var palette
    @State private var document = StatsDocument()
    @State private var tab = "keys"
    @State private var showClear = false
    @State private var visible = false

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let tabs: [(String, String)] = [
        ("keys", "按键"), ("trend", "趋势"), ("kind", "类型"),
        ("mode", "模式"), ("scheme", "方案"), ("ranks", "候选"),
    ]

    private var path: String {
        model.supportDir.appendingPathComponent("stats.json").path
    }

    private var metrics: StatsMetrics { StatsMath.metrics(document) }

    /// 和 Linux 设置界面的 STATS_PRIVACY 一样。
    private static let privacy = "打开以后只在本机按天记计数：上屏的字数和各类字符数、活跃时长、每个键按了几次、"
        + "各输入模式的字数、选了第几个候选。不记打的字、拼音、按键顺序和时刻，密码框里的不算。"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            controls
            if model.config.typingStats {
                overview
                Text("速度统计汉字与字母；两次上屏间隔超过 10 秒视为休息，不计入活跃时长。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                tabBar
                content
            } else {
                offNote
            }
        }
        .onAppear {
            visible = true
            reload()
        }
        .onDisappear { visible = false }
        .onReceive(tick) { _ in
            if visible { reload() }
        }
    }

    // MARK: 概览

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading),
                                     count: 3),
                      alignment: .leading, spacing: 16) {
                metric("今日输入", "\(metrics.todayChars)", "字符", bestNote)
                metric("累计输入", "\(metrics.totalChars)", "字符",
                       "日均 \(Int(metrics.averagePerDay.rounded())) 字符 · \(metrics.recordedDays) 天有记录")
                metric("今日活跃", StatsMath.formatActive(metrics.todayActive), "",
                       metrics.totalActive > 0
                           ? "累计 \(StatsMath.formatActive(metrics.totalActive))"
                           : "还没有测量到活跃时长")
                metric("今日速度", "\(Int(metrics.todaySpeed.rounded()))", "字 / 分钟", fastestNote)
                metric("平均速度", "\(Int(metrics.averageSpeed.rounded()))", "字 / 分钟", "")
                metric("连续天数", "\(metrics.streak)", "天", "最长 \(metrics.longestStreak) 天")
            }
            if !bestLine.isEmpty {
                HStack {
                    Spacer()
                    Text(bestLine)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(18)
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(palette.cardBorder, lineWidth: 1))
    }

    private var bestNote: String {
        guard let day = metrics.bestDay else { return "" }
        return "单日最多 \(metrics.bestChars) 字符 · \(StatsMath.dayLabel(day))"
    }

    private var fastestNote: String {
        guard let day = metrics.fastestDay else { return "" }
        return "单日最快 \(Int(metrics.fastestSpeed.rounded())) 字 / 分钟 · \(StatsMath.dayLabel(day))"
    }

    private var bestLine: String {
        var parts: [String] = []
        if let day = metrics.bestDay {
            parts.append("最多 \(StatsMath.dayLabel(day))，\(metrics.bestChars) 字符")
        }
        if let day = metrics.fastestDay {
            parts.append("最快 \(StatsMath.dayLabel(day))，\(Int(metrics.fastestSpeed.rounded())) 字 / 分钟")
        }
        return parts.joined(separator: " · ")
    }

    private func metric(_ label: String, _ value: String, _ unit: String,
                        _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(palette.heading)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(palette.accentText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundColor(palette.heading)
                }
            }
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 标签

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(tabs.indices, id: \.self) { index in
                let name = tabs[index].0
                let label = tabs[index].1
                Button {
                    tab = name
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: tab == name ? .semibold : .regular))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(tab == name ? palette.card : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(palette.nested)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case "trend": trendPage
        case "kind": kindPage
        case "mode": modePage
        case "scheme": schemePage
        case "ranks": ranksPage
        default: keysPage
        }
    }

    // MARK: 按键

    private var keyCounts: [String: Int] { StatsKeyboard.totals(document) }

    private var keysPage: some View {
        let counts = keyCounts
        let total = counts.values.reduce(0, +)
        let maximum = max(1, counts.values.max() ?? 0)
        let drawn = StatsKeyboard.drawnCodes
        let others = counts.filter { !drawn.contains($0.key) }
            .map { KeyCount(code: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
        let keyboardRows = StatsKeyboard.rows
        let top = counts.map { KeyCount(code: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
            .prefix(5)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("按键热力图 · 累计",
                         note: "共 \(total) 次按键，颜色越深按得越多")
            if total == 0 {
                empty("还没有按键记录。用 WowType 打几个字，再回来看。")
            } else {
                VStack(alignment: .center, spacing: 4) {
                    ForEach(keyboardRows.indices, id: \.self) { rowIndex in
                        let row = keyboardRows[rowIndex]
                        HStack(spacing: 4) {
                            ForEach(row) { key in
                                if let code = key.code {
                                    keyCap(code, label: key.label, weight: key.weight,
                                           count: counts[code] ?? 0, maximum: maximum)
                                } else {
                                    Color.clear
                                        .frame(width: CGFloat(max(1, key.weight * StatsKeyboard.unit - 4)),
                                               height: 32)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                if !others.isEmpty {
                    Text("其他键")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(others) { item in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(heatColor(StatsKeyboard.level(item.count, maximum: maximum)))
                                    .frame(width: 10, height: 10)
                                Text(StatsKeyboard.name(item.code))
                                    .font(.system(size: 11))
                                Text("\(item.count)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(palette.cardBorder, lineWidth: 1))
                        }
                    }
                }
                HStack(spacing: 4) {
                    Text("少")
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(heatColor(level))
                            .frame(width: 10, height: 10)
                    }
                    Text("多")
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(top.indices, id: \.self) { index in
                        let item = top[index]
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 16, alignment: .trailing)
                            Text(StatsKeyboard.name(item.code))
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(item.count) 次")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(palette.cardBorder, lineWidth: 1))
    }

    private func keyCap(_ code: String, label: String, weight: Double, count: Int,
                        maximum: Int) -> some View {
        let level = StatsKeyboard.level(count, maximum: maximum)
        return Text(label)
            .font(.system(size: 9))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: CGFloat(max(1, weight * StatsKeyboard.unit - 4)), height: 32)
            .background(heatColor(level))
            .foregroundColor(level >= 3 ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .help("\(StatsKeyboard.name(code))，\(count) 次")
    }

    private func heatColor(_ level: Int) -> Color {
        switch level {
        case 0: return palette.dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
        case 1: return palette.accentColor.opacity(0.20)
        case 2: return palette.accentColor.opacity(0.40)
        case 3: return palette.accentColor.opacity(0.60)
        default: return palette.accentStrong
        }
    }

    // MARK: 趋势

    private var trendPage: some View {
        let series = StatsMath.recentDays(document, length: 30)
        let maxCount = max(1, series.map(\.count).max() ?? 0)
        let total = series.map(\.count).reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("每日趋势 · 近 30 天",
                         note: "共 \(total) 字符 · 最高一天 \(maxCount) 字符")
            if total == 0 {
                empty("这 30 天还没有输入记录。")
            } else {
                let barColor = palette.accentColor
                Canvas { context, size in
                    let gap: CGFloat = 3
                    let bar = max(1, (size.width - gap * CGFloat(series.count - 1))
                        / CGFloat(series.count))
                    for (index, item) in series.enumerated() {
                        guard item.count > 0 else { continue }
                        let height = (size.height - 6) * CGFloat(item.count) / CGFloat(maxCount)
                        let rect = CGRect(x: CGFloat(index) * (bar + gap),
                                          y: size.height - height,
                                          width: bar, height: height)
                        context.fill(Path(rect), with: .color(barColor))
                    }
                }
                .frame(height: 150)
                HStack {
                    Text(series.first.map { StatsMath.dayLabel($0.key) } ?? "")
                    Spacer()
                    Text(series.last.map { StatsMath.dayLabel($0.key) } ?? "")
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
        }
    }

    // MARK: 类型 / 模式

    private var kindPage: some View {
        let totals = StatsStore.totals(document)
        let slices: [(String, Int, Color)] = [
            ("汉字", totals.kinds["han"] ?? 0, palette.accentColor),
            ("字母", totals.kinds["latin"] ?? 0, Color(hex: 0x4C9AFF)),
            ("数字", totals.kinds["number"] ?? 0, Color(hex: 0xF5A623)),
            ("标点", totals.kinds["punct"] ?? 0, Color(hex: 0x8A93A6)),
            ("表情", totals.kinds["emoji"] ?? 0, Color(hex: 0xE86AA6)),
            ("其他", totals.kinds["other"] ?? 0, Color(hex: 0xC4C9C7)),
        ].filter { $0.1 > 0 }
        return ratioPage(title: "字符类型", slices: slices, emptyText: "还没有字符记录。")
    }

    private var modePage: some View {
        let totals = StatsStore.totals(document)
        let names = [("quanpin", "拼音"), ("shuangpin", "双拼"),
                     ("english", "英文"), ("translate", "互译")]
        let colors: [Color] = [palette.accentColor, Color(hex: 0x4C9AFF),
                               Color(hex: 0xF5A623), Color(hex: 0xE86AA6)]
        var slices: [(String, Int, Color)] = []
        for (index, item) in names.enumerated() {
            let value = totals.sources[item.0] ?? 0
            if value > 0 {
                slices.append((item.1, value, colors[index]))
            }
        }
        return ratioPage(title: "语言模式", slices: slices, emptyText: "还没有输入记录。")
    }

    private func ratioPage(title: String, slices: [(String, Int, Color)],
                           emptyText: String) -> some View {
        let total = max(1, slices.map(\.1).reduce(0, +))
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, note: "")
            if slices.isEmpty {
                empty(emptyText)
            } else {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(slices.indices, id: \.self) { index in
                            let slice = slices[index]
                            Rectangle()
                                .fill(slice.2)
                                .frame(width: geometry.size.width * CGFloat(slice.1) / CGFloat(total))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                ForEach(slices.indices, id: \.self) { index in
                    let slice = slices[index]
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(slice.2)
                            .frame(width: 10, height: 10)
                        Text(slice.0)
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(slice.1) · \(Int((Double(slice.1) / Double(total) * 100).rounded()))%")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 方案 / 候选

    private var schemePage: some View {
        let totals = StatsStore.totals(document)
        let names = ["ziranma": "自然码", "xiaohe": "小鹤双拼", "microsoft": "微软双拼",
                     "sogou": "搜狗双拼", "abc": "智能 ABC", "ziguang": "紫光双拼",
                     "pinyinjiajia": "拼音加加"]
        let rows = totals.schemes.map { KeyCount(code: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.code < $1.code }
        let maximum = max(1, rows.first?.count ?? 0)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("输入方案", note: "")
            if rows.isEmpty {
                empty("还没有双拼输入记录。用双拼打几个字，这里会显示各方案的占比。")
            } else {
                ForEach(rows) { row in
                    barRow(names[row.code] ?? row.code, value: row.count, maximum: maximum)
                }
            }
        }
    }

    private var ranksPage: some View {
        let totals = StatsStore.totals(document)
        let total = totals.selections.reduce(0, +) + totals.beyond
        let maximum = max(1, (totals.selections + [totals.beyond]).max() ?? 0)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("候选命中位置",
                         note: total > 0
                             ? "首选命中 \(Int((Double(totals.selections[0]) / Double(total) * 100).rounded()))% · 共 \(total) 次上屏"
                             : "")
            if total == 0 {
                empty("还没有候选记录。选几次候选再回来看看。")
            } else {
                ForEach(totals.selections.indices, id: \.self) { index in
                    barRow("第 \(index + 1) 个", value: totals.selections[index],
                           maximum: maximum, suffix: "\(totals.selections[index]) 次")
                }
                if totals.beyond > 0 {
                    barRow("第 10 个以后", value: totals.beyond, maximum: maximum,
                           suffix: "\(totals.beyond) 次")
                }
            }
        }
    }

    private func barRow(_ label: String, value: Int, maximum: Int,
                        suffix: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 96, alignment: .leading)
            ProgressView(value: Double(value), total: Double(maximum))
                .progressViewStyle(.linear)
            Text(suffix ?? "\(value) · \(Int((Double(value) / Double(maximum) * 100).rounded()))%")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .trailing)
        }
    }

    // MARK: 开关和清除

    /// 开关是 wowtype.conf 的 TypingStats（默认关），输入法读设置文件生效；清除关着时也能点。
    private var controls: some View {
        PrefGroup("打字统计", info: Self.privacy) {
            SwitchRow(title: "记录打字统计", subtitle: "默认关；只在本机记每天的计数，不记打的内容",
                      isOn: $model.config.typingStats)
            RowDivider()
            ActionRow(title: "清除统计", subtitle: "删掉已经记下的全部计数", action: { showClear = true }) {
                Button("清除", role: .destructive) { showClear = true }
            }
            .confirmationDialog("清除打字统计？", isPresented: $showClear) {
                Button("清除", role: .destructive) { clear() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已经记下的每天的字数、按键次数和候选位置都会删掉，不能恢复。开关保持现在的位置。")
            }
        }
    }

    /// 关着时：说清楚开了以后记什么、不记什么。
    private var offNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("打字统计关着")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.heading)
            Text("关着时 WowType 什么都不记：不计数，也不建统计文件。")
            Text(Self.privacy)
            Text("文件在 \(path)，随时可以在上面清除。")
            if !document.days.isEmpty {
                Text("以前记下的 \(document.days.count) 天还在，打开开关后接着记；不要了点「清除」。")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(palette.cardBorder, lineWidth: 1))
    }

    private func clear() {
        do {
            try StatsStore.clear(path: path)
            model.showToast("已清除打字统计")
        } catch {
            model.showToast("清除失败：\(error.localizedDescription)")
        }
        reload()
    }

    private func reload() {
        document = StatsStore.load(path)
    }

    private func sectionTitle(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.heading)
            if !note.isEmpty {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }
}
