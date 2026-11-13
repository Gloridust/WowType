// 候选框：一个不抢焦点的小窗口，照 WowType 主题自己画。颜色、圆角、边距和 Linux 上的
// themes/fcitx5/wowtype、wowtype-dark 一样，系统换深色模式时跟着换：圆角白底（深色是深灰底），
// 当前候选绿底白字，序号灰色，最右边是绿色的翻页箭头（翻不动的那边变淡）。
// 横排一行「1 是  2 十 …」，竖排（设置里 CandidateLayout=Vertical、v + 空格的工具栏）一行一个。
// 展开面板（横排按下键）和表情面板一行 6 个排成网格：光标所在行浅绿底、标 1–6（数字选这一行的第几个），
// 光标处的词绿底白字，翻页箭头在右下角。工具栏、表情面板在候选上方多一行灰色的提示。
// 互译时候选上面多一行「中→英 互译：」+ 原文，下面多一行状态（灰色小字）；没有候选时只有这两行。

import AppKit

/// WowType 主题的颜色，取自 themes/fcitx5/wowtype*/theme.conf 和 themes/src/*.svg。
struct CandidateTheme {
    var background: NSColor
    var border: NSColor
    var text: NSColor
    var label: NSColor
    var highlight: NSColor
    var highlightText: NSColor
    var arrow: NSColor
    /// 展开面板里光标所在行的底色
    var row: NSColor

    static let light = CandidateTheme(
        background: .rgb(0xFFFFFF), border: .rgb(0xDCE3DF), text: .rgb(0x1D2321), label: .rgb(0x7A8580),
        highlight: .rgb(0x0EAF76), highlightText: .rgb(0xFFFFFF), arrow: .rgb(0x0EAF76),
        row: .rgb(0x0EAF76, alpha: 0.12))
    static let dark = CandidateTheme(
        background: .rgb(0x25292B), border: .rgb(0x3B4144), text: .rgb(0xE6EAE8), label: .rgb(0x8E9894),
        highlight: .rgb(0x13B57C), highlightText: .rgb(0xFFFFFF), arrow: .rgb(0x3CCB93),
        row: .rgb(0x13B57C, alpha: 0.2))

    static func matching(_ appearance: NSAppearance) -> CandidateTheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

private extension NSColor {
    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// 一页候选摆在哪（左上角为原点）。只算位置，画由 CandidateView 来。
struct CandidateLayout {
    struct Cell {
        /// 高亮底的范围，序号和词在里面居中
        var frame: NSRect
        var label: String
        var text: String
        /// 词后面的小字（五笔的编码提示），空串不画
        var comment = ""
        /// 展开面板里只有光标所在行标序号，别的行留出序号的位置，各行的词才对得齐
        var showLabel: Bool
        var current: Bool
        /// 靠左摆（竖排）；false 在高亮底里居中
        var leading = false
    }

    static let cornerRadius: CGFloat = 12
    static let cellRadius: CGFloat = 7
    /// 框边到候选底
    static let inset = NSSize(width: 7, height: 7)
    /// 候选底到字
    static let cellPadding = NSSize(width: 8, height: 4)
    /// 候选之间（左右、上下）
    static let spacing: CGFloat = 2
    /// 序号和词之间
    static let labelGap: CGFloat = 4
    /// 一个翻页箭头占的宽度；箭头和最后一个候选隔开 arrowGap
    static let arrowWidth: CGFloat = 13
    static let arrowGap: CGFloat = 4
    /// 展开面板最底下放箭头的那一行有多高
    static let arrowRowHeight: CGFloat = 16
    /// 提示和候选之间
    static let auxGap: CGFloat = 3
    /// 互译的原文最多显示这么多个字（太长只留后面的）
    static let maxSourceLength = 40

    let textFont: NSFont
    let labelFont: NSFont
    /// 候选上方的提示（工具栏、表情面板）
    let aux: String?
    private(set) var auxFrame: NSRect?
    private(set) var size = NSSize.zero
    private(set) var cells: [Cell] = []
    /// 展开面板光标所在行；没有时 nil
    private(set) var row: NSRect?
    /// 两个翻页箭头；都翻不动时 nil
    private(set) var arrows: (prev: NSRect, next: NSRect)?
    let hasPrev: Bool
    let hasNext: Bool
    /// 互译：候选上面那行（标题 + 原文）和下面那行（状态）的位置；不在互译时 nil
    private(set) var header: (title: String, source: String, origin: NSPoint)?
    private(set) var footer: (text: String, origin: NSPoint)?

    init(page: CandidatePage, fontSize: CGFloat) {
        textFont = .systemFont(ofSize: fontSize)
        labelFont = .monospacedDigitSystemFont(ofSize: (fontSize * 0.76).rounded(), weight: .regular)
        hasPrev = page.hasPrev
        hasNext = page.hasNext
        aux = page.aux
        var top = Self.inset.height
        if let aux {
            let size = auxContent(aux, color: .clear).size()
            let frame = NSRect(x: Self.inset.width + Self.cellPadding.width, y: top,
                               width: ceil(size.width), height: ceil(size.height))
            auxFrame = frame
            top = frame.maxY + Self.auxGap
        }
        if let translate = page.translate {
            layOutTranslate(page, translate, top: top)
        } else if page.texts.isEmpty {
            // 只有提示（剪贴板还没有记录、表情没找到）
            let bottom = auxFrame.map { $0.maxY } ?? top
            size = NSSize(width: Self.inset.width, height: bottom + Self.inset.height)
        } else {
            layOutCandidates(page, top: top)
        }
        // 提示比候选宽时框跟着宽
        if let auxFrame {
            size.width = max(size.width, auxFrame.maxX + Self.cellPadding.width + Self.inset.width)
        }
    }

    /// 互译：先摆标题和原文，候选往下挪，最后摆状态，框的宽度取最宽的那行
    private mutating func layOutTranslate(_ page: CandidatePage, _ translate: TranslatePanel, top: CGFloat) {
        let source = translate.source.count > Self.maxSourceLength
            ? "…" + translate.source.suffix(Self.maxSourceLength) : translate.source
        let left = Self.inset.width + Self.cellPadding.width
        let headerSize = headerContent(title: translate.title, source: source, titleColor: .clear,
                                       textColor: .clear).size()
        header = (translate.title, source, NSPoint(x: left, y: top + Self.cellPadding.height))
        var bottom = top + ceil(headerSize.height) + Self.cellPadding.height * 2
        var width = left + ceil(headerSize.width) + Self.cellPadding.width
        if !page.texts.isEmpty {
            layOutCandidates(page, top: bottom + Self.spacing)
            bottom = size.height - Self.inset.height
            width = max(width, size.width - Self.inset.width)
        }
        if !translate.status.isEmpty {
            let status = footerContent(translate.status, color: .clear).size()
            footer = (translate.status, NSPoint(x: left, y: bottom + Self.spacing))
            bottom += Self.spacing + ceil(status.height) + Self.cellPadding.height
            width = max(width, left + ceil(status.width) + Self.cellPadding.width)
        }
        size = NSSize(width: width + Self.inset.width, height: bottom + Self.inset.height)
    }

    private mutating func layOutCandidates(_ page: CandidatePage, top: CGFloat) {
        if page.expanded {
            layOutGrid(page, top: top)
        } else if page.vertical {
            layOutColumn(page, top: top)
        } else {
            layOutRow(page, top: top)
        }
    }

    /// 互译那一行：「中→英 互译：」用序号的颜色和字号，原文用候选的。
    func headerContent(title: String, source: String, titleColor: NSColor, textColor: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString(string: title, attributes: [.font: labelFont, .foregroundColor: titleColor])
        out.append(NSAttributedString(string: source, attributes: [.font: textFont, .foregroundColor: textColor]))
        return out
    }

    func auxContent(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: labelFont, .foregroundColor: color])
    }

    func footerContent(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: labelFont, .foregroundColor: color])
    }

    /// 序号、词、词后面的小字（编码提示）连成一串：序号和小字用小一号的字、序号的颜色，基线对齐。
    func content(label: String, text: String, comment: String = "", labelColor: NSColor, textColor: NSColor,
                 commentColor: NSColor = .clear) -> NSAttributedString {
        let out = NSMutableAttributedString(string: label, attributes: [
            .font: labelFont, .foregroundColor: labelColor, .kern: Self.labelGap,
        ])
        out.append(NSAttributedString(string: text, attributes: [.font: textFont, .foregroundColor: textColor]))
        if !comment.isEmpty {
            out.append(NSAttributedString(string: " " + comment, attributes: [.font: labelFont, .foregroundColor: commentColor]))
        }
        return out
    }

    private var cellHeight: CGFloat {
        // 量一个汉字：系统字体里没有汉字，实际画的是回退字体（苹方），行高以它为准
        let line = NSAttributedString(string: "中", attributes: [.font: textFont]).size().height
        return ceil(line) + Self.cellPadding.height * 2
    }

    private func contentWidth(label: String, text: String, comment: String = "") -> CGFloat {
        ceil(content(label: label, text: text, comment: comment, labelColor: .clear, textColor: .clear).size().width)
    }

    private mutating func layOutRow(_ page: CandidatePage, top: CGFloat) {
        let height = cellHeight
        let y = top
        var x = Self.inset.width
        for (i, text) in page.texts.enumerated() {
            let label = "\(i + 1)"
            let comment = page.comment(i)
            let width = contentWidth(label: label, text: text, comment: comment) + Self.cellPadding.width * 2
            cells.append(Cell(frame: NSRect(x: x, y: y, width: width, height: height), label: label, text: text,
                              comment: comment, showLabel: true, current: i == page.cursor))
            x += width + Self.spacing
        }
        x -= Self.spacing
        if page.hasPrev || page.hasNext {
            x += Self.arrowGap
            let prev = NSRect(x: x, y: y, width: Self.arrowWidth, height: height)
            arrows = (prev, prev.offsetBy(dx: Self.arrowWidth, dy: 0))
            x += Self.arrowWidth * 2 + Self.arrowGap
        }
        size = NSSize(width: x + Self.inset.width, height: y + height + Self.inset.height)
    }

    /// 竖排：一行一个，都和最宽的一样宽，翻页箭头在右下角。
    private mutating func layOutColumn(_ page: CandidatePage, top: CGFloat) {
        let height = cellHeight
        let widest = page.texts.enumerated().map {
            contentWidth(label: "\($0.offset + 1)", text: $0.element, comment: page.comment($0.offset))
        }.max() ?? 0
        let width = max(widest + Self.cellPadding.width * 2, Self.arrowWidth * 2)
        var y = top
        for (i, text) in page.texts.enumerated() {
            cells.append(Cell(frame: NSRect(x: Self.inset.width, y: y, width: width, height: height),
                              label: "\(i + 1)", text: text, comment: page.comment(i), showLabel: true,
                              current: i == page.cursor, leading: true))
            y += height + Self.spacing
        }
        var bottom = y - Self.spacing
        let right = Self.inset.width + width
        if page.hasPrev || page.hasNext {
            let next = NSRect(x: right - Self.arrowWidth, y: bottom + Self.spacing,
                              width: Self.arrowWidth, height: Self.arrowRowHeight)
            arrows = (next.offsetBy(dx: -Self.arrowWidth, dy: 0), next)
            bottom = next.maxY
        }
        size = NSSize(width: right + Self.inset.width, height: bottom + Self.inset.height)
    }

    private mutating func layOutGrid(_ page: CandidatePage, top: CGFloat) {
        let columns = CandidatePage.columns
        let height = cellHeight
        let cursorRow = page.cursor >= 0 ? page.cursor / columns : -1
        // 每一列和这一屏里这一列最宽的词一样宽，上下键才是在同一列里走
        var widths = [CGFloat](repeating: 0, count: columns)
        for (i, text) in page.texts.enumerated() {
            let column = i % columns
            widths[column] = max(widths[column], contentWidth(label: "\(column + 1)", text: text, comment: page.comment(i)))
        }
        var xs: [CGFloat] = []
        var x = Self.inset.width
        for width in widths where width > 0 {
            xs.append(x)
            x += width + Self.cellPadding.width * 2 + Self.spacing
        }
        let right = x - Self.spacing
        var bottom = top
        for (i, text) in page.texts.enumerated() {
            let (r, column) = (i / columns, i % columns)
            let y = top + CGFloat(r) * (height + Self.spacing)
            let frame = NSRect(x: xs[column], y: y, width: widths[column] + Self.cellPadding.width * 2, height: height)
            cells.append(Cell(frame: frame, label: "\(column + 1)", text: text, comment: page.comment(i),
                              showLabel: r == cursorRow, current: i == page.cursor))
            if r == cursorRow {
                row = NSRect(x: Self.inset.width, y: y, width: right - Self.inset.width, height: height)
            }
            bottom = y + height
        }
        if page.hasPrev || page.hasNext {
            let next = NSRect(x: right - Self.arrowWidth, y: bottom + Self.spacing,
                              width: Self.arrowWidth, height: Self.arrowRowHeight)
            arrows = (next.offsetBy(dx: -Self.arrowWidth, dy: 0), next)
            bottom = next.maxY
        }
        size = NSSize(width: right + Self.inset.width, height: bottom + Self.inset.height)
    }
}

/// 照 CandidateLayout 画候选框。颜色按自己的外观（跟着系统的浅色 / 深色）挑。
final class CandidateView: NSView {
    var layout: CandidateLayout? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        let theme = CandidateTheme.matching(effectiveAppearance)

        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: CandidateLayout.cornerRadius - 0.5,
                                 yRadius: CandidateLayout.cornerRadius - 0.5)
        theme.background.setFill()
        panel.fill()
        theme.border.setStroke()
        panel.lineWidth = 1
        panel.stroke()

        if let aux = layout.aux, let frame = layout.auxFrame {
            layout.auxContent(aux, color: theme.label).draw(at: frame.origin)
        }
        if let header = layout.header {
            layout.headerContent(title: header.title, source: header.source, titleColor: theme.label,
                                 textColor: theme.text).draw(at: header.origin)
        }
        if let footer = layout.footer {
            layout.footerContent(footer.text, color: theme.label).draw(at: footer.origin)
        }
        if let row = layout.row {
            theme.row.setFill()
            roundedRect(row).fill()
        }
        for cell in layout.cells {
            if cell.current {
                theme.highlight.setFill()
                roundedRect(cell.frame).fill()
            }
            let label: NSColor = !cell.showLabel ? .clear : cell.current ? theme.highlightText : theme.label
            let content = layout.content(label: cell.label, text: cell.text, comment: cell.comment, labelColor: label,
                                         textColor: cell.current ? theme.highlightText : theme.text,
                                         commentColor: cell.current ? theme.highlightText : theme.label)
            let size = content.size()
            let x = cell.leading ? cell.frame.minX + CandidateLayout.cellPadding.width : cell.frame.midX - size.width / 2
            content.draw(at: NSPoint(x: x, y: cell.frame.midY - size.height / 2))
        }
        if let arrows = layout.arrows {
            drawChevron(in: arrows.prev, pointingLeft: true, color: theme.arrow, enabled: layout.hasPrev)
            drawChevron(in: arrows.next, pointingLeft: false, color: theme.arrow, enabled: layout.hasNext)
        }
    }

    private func roundedRect(_ rect: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: CandidateLayout.cellRadius, yRadius: CandidateLayout.cellRadius)
    }

    /// 和 themes/src/prev.svg、next.svg 一样的尖角：高 9、宽 4.5，线宽 1.8，圆头。
    private func drawChevron(in rect: NSRect, pointingLeft: Bool, color: NSColor, enabled: Bool) {
        let (cx, cy) = (rect.midX, rect.midY)
        let dx: CGFloat = pointingLeft ? 2.25 : -2.25
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx + dx, y: cy - 4.5))
        path.line(to: NSPoint(x: cx - dx, y: cy))
        path.line(to: NSPoint(x: cx + dx, y: cy + 4.5))
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (enabled ? color : color.withAlphaComponent(0.3)).setStroke()
        path.stroke()
    }
}

final class CandidatePanel {
    private let panel: NSPanel
    private let view = CandidateView()
    /// 候选的字号（磅）；序号小一号
    var fontSize: CGFloat = 17
    /// 输入框这一行和候选框之间
    private let gap: CGFloat = 4

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        // 窗口本身透明，圆角框由 CandidateView 画；系统按画出来的形状投影
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = view
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// line 是输入框光标所在行的矩形（屏幕坐标，左下角为原点）；拿不到时是空矩形。
    func show(_ page: CandidatePage, below line: NSRect) {
        let layout = CandidateLayout(page: page, fontSize: fontSize)
        view.layout = layout
        panel.setContentSize(layout.size)
        panel.setFrameOrigin(origin(for: layout.size, line: line))
        panel.orderFrontRegardless()
        // 投影是照窗口里画出来的形状算的，大小一变就得先画好再重算
        panel.displayIfNeeded()
        panel.invalidateShadow()
    }

    private func origin(for size: NSSize, line: NSRect) -> NSPoint {
        // 有的应用给不出光标位置（返回全零），就放在鼠标旁边
        let anchor = line.origin == .zero && line.size == .zero
            ? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 0, height: 18))
            : line
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 10000, height: 10000)
        // 第一个候选的序号对着编辑区的第一个字母
        var x = anchor.minX - CandidateLayout.inset.width - CandidateLayout.cellPadding.width
        var y = anchor.minY - size.height - gap
        if y < visible.minY {
            // 下面放不下就放到这一行上面
            y = anchor.maxY + gap
        }
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return NSPoint(x: x, y: y)
    }
}
