// 候选框：自己画的无边框、不抢焦点的 NSPanel，整个进程只有一个。
//
// - 不用 IMKCandidates（vChewing、hallelujahIM 都弃用了）；
// - 永远不成为 key / main 窗口，程序失去焦点时也不藏（fcitx5-webview、McBopomofo）；
// - 出现在所有桌面和全屏应用上，层级在应用和弹出菜单之上，每次显示时重新算；
// - 顺序：排版 -> 算大小 -> 定位置 -> orderFront，不先显示再挪（免得闪）；
// - 鼠标在同一个候选上按下又松开才选，滚轮攒够一段距离翻一页（鼠须管）；
// - 颜色只用系统语义色，跟着浅色/深色走。
import AppKit
import WowTypeEngine
import WowTypeKit

final class CandidatePanel: NSPanel {
    static let shared = CandidatePanel()

    private let view = CandidateView()
    private weak var owner: WowTypeInputController?
    private var above = false
    private var shownOnce = false

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.addSubview(view)
        contentView = effect
        view.onSelect = { [weak self] index in self?.owner?.selectFromPanel(index) }
        view.onPage = { [weak self] delta in self?.owner?.pageFromPanel(delta) }
        setAccessibilityRole(.list)
        setAccessibilityLabel("WowType 候选")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ snap: SessionSnapshot, anchor: CGRect, level: Int, owner: WowTypeInputController) {
        self.owner = owner
        let size = view.layout(snap)
        let screens = NSScreen.screens.map { ScreenRects(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let screen = ScreenPicker.pick(anchor: anchor, screens: screens, fallback: 0) else { return }
        let placed = CandidatePlacement.place(size: size, anchor: anchor, screen: screen,
                                              stickyAbove: isVisible && above)
        above = placed.above
        view.frame = NSRect(origin: .zero, size: placed.frame.size)
        self.level = NSWindow.Level(rawValue: level)
        if frame != placed.frame { setFrame(placed.frame, display: false) }
        view.needsDisplay = true
        if !isVisible {
            orderFront(nil)
            if !shownOnce {
                shownOnce = true
                NSAccessibility.post(element: self, notification: .created)
            }
        }
        view.postSelectionChanged()
    }

    /// owner 为 nil 时不管是谁的都关；否则只关这个控制器打开的。
    func hide(owner: WowTypeInputController?) {
        if let owner, let current = self.owner, current !== owner { return }
        orderOut(nil)
        above = false
        view.cancelMouse()
    }
}

/// 画候选、处理鼠标。
final class CandidateView: NSView {
    var onSelect: ((Int) -> Void)?
    var onPage: ((Int) -> Void)?

    private var snap = SessionSnapshot.empty
    private var cells: [CGRect] = []
    private var auxRect = CGRect.zero
    private var pressed: Int?
    private var scrollSum: CGFloat = 0
    private var items: [CandidateItem] = []

    private let padding: CGFloat = 6
    private let spacing: CGFloat = 10
    private var font: NSFont { .systemFont(ofSize: 17) }
    private var labelFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    private var auxFont: NSFont { .systemFont(ofSize: 12) }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 排版并返回需要的大小。每个格子量一次，点击时直接用存下的矩形。
    func layout(_ snap: SessionSnapshot) -> CGSize {
        self.snap = snap
        cells = []
        var y = padding
        var width: CGFloat = 0
        if !snap.aux.isEmpty {
            let s = (snap.aux as NSString).size(withAttributes: [.font: auxFont])
            auxRect = CGRect(x: padding, y: y, width: ceil(s.width), height: ceil(s.height))
            y += auxRect.height + 4
            width = auxRect.maxX
        } else {
            auxRect = .zero
        }
        let sizes = snap.candidates.map { cellSize($0) }
        let lineHeight = ceil(sizes.map(\.height).max() ?? 0)
        if snap.columns > 0 {
            // 展开的网格：每列取这一列最宽的。
            let cols = snap.columns
            var colWidths = Array(repeating: CGFloat(0), count: cols)
            for (i, s) in sizes.enumerated() { colWidths[i % cols] = max(colWidths[i % cols], s.width) }
            for i in sizes.indices {
                let row = i / cols, col = i % cols
                let x = padding + colWidths[..<col].reduce(0, +) + CGFloat(col) * spacing
                cells.append(CGRect(x: x, y: y + CGFloat(row) * (lineHeight + 4), width: colWidths[col], height: lineHeight))
            }
        } else if snap.vertical {
            for (i, s) in sizes.enumerated() {
                cells.append(CGRect(x: padding, y: y + CGFloat(i) * (lineHeight + 2), width: s.width, height: lineHeight))
            }
            let w = sizes.map(\.width).max() ?? 0
            cells = cells.map { CGRect(x: $0.minX, y: $0.minY, width: w, height: $0.height) }
        } else {
            var x = padding
            for s in sizes {
                cells.append(CGRect(x: x, y: y, width: s.width, height: lineHeight))
                x += s.width + spacing
            }
        }
        width = max(width, cells.map(\.maxX).max() ?? 0)
        let height = max(auxRect.maxY, cells.map(\.maxY).max() ?? 0)
        updateAccessibility()
        return CGSize(width: ceil(width + padding), height: ceil(height + padding))
    }

    private func cellSize(_ c: SessionSnapshot.Candidate) -> CGSize {
        let t = (c.text as NSString).size(withAttributes: [.font: font])
        let l = c.label.isEmpty ? .zero : (c.label as NSString).size(withAttributes: [.font: labelFont])
        return CGSize(width: ceil(t.width + (l.width > 0 ? l.width + 4 : 0)) + 8, height: ceil(t.height) + 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if !snap.aux.isEmpty {
                (snap.aux as NSString).draw(in: auxRect, withAttributes: [
                    .font: auxFont, .foregroundColor: NSColor.secondaryLabelColor])
            }
            for (i, c) in snap.candidates.enumerated() where i < cells.count {
                let rect = cells[i]
                let selected = i == snap.cursor
                if selected {
                    NSColor.selectedContentBackgroundColor.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                }
                let textColor: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
                let labelColor: NSColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
                var x = rect.minX + 4
                if !c.label.isEmpty {
                    let ls = (c.label as NSString).size(withAttributes: [.font: labelFont])
                    (c.label as NSString).draw(at: CGPoint(x: x, y: rect.midY - ls.height / 2), withAttributes: [
                        .font: labelFont, .foregroundColor: labelColor])
                    x += ls.width + 4
                }
                let ts = (c.text as NSString).size(withAttributes: [.font: font])
                (c.text as NSString).draw(at: CGPoint(x: x, y: rect.midY - ts.height / 2), withAttributes: [
                    .font: font, .foregroundColor: textColor])
            }
        }
    }

    // MARK: - 鼠标

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return cells.firstIndex { $0.contains(p) }
    }

    override func mouseDown(with event: NSEvent) { pressed = index(at: event) }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let down = pressed, index(at: event) == down else { return }
        onSelect?(down)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { scrollSum = 0 }
        scrollSum += event.scrollingDeltaY
        // 一次手势翻一页：攒够 10pt 翻，翻完清零等下一次手势（没有 phase 的普通滚轮每格都翻）。
        if abs(scrollSum) >= 10 || (event.phase.isEmpty && event.momentumPhase.isEmpty && event.scrollingDeltaY != 0) {
            onPage?(scrollSum > 0 ? -1 : 1)
            scrollSum = 0
        }
    }

    func cancelMouse() {
        pressed = nil
        scrollSum = 0
    }

    // MARK: - 辅助功能（VoiceOver）

    private func updateAccessibility() {
        while items.count < snap.candidates.count { items.append(CandidateItem(parent: self)) }
        for (i, c) in snap.candidates.enumerated() {
            let item = items[i]
            item.setAccessibilityLabel(c.label.isEmpty ? c.text : "\(c.label) \(c.text)")
            item.setAccessibilitySelected(i == snap.cursor)
            item.setAccessibilityFrameInParentSpace(i < cells.count ? cells[i] : .zero)
        }
        setAccessibilityChildren(Array(items.prefix(snap.candidates.count)))
    }

    func postSelectionChanged() {
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
}

/// 一个候选的辅助功能元素；跨重绘复用，VoiceOver 不会丢位置。
final class CandidateItem: NSAccessibilityElement {
    nonisolated override init() {
        super.init()
    }

    init(parent: NSView) {
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(.staticText)
    }
}
