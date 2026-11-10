// 候选框：一个不抢焦点的小窗口，横排「1 是  2 十 …」，当前候选高亮，右边是页码。

import AppKit

final class CandidatePanel {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let padding = NSSize(width: 10, height: 6)
    private let gap: CGFloat = 4

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        panel.contentView = background

        label.translatesAutoresizingMaskIntoConstraints = true
        label.lineBreakMode = .byClipping
        background.addSubview(label)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// line 是输入框光标所在行的矩形（屏幕坐标，左下角为原点）；拿不到时是空矩形。
    func show(_ page: CandidatePage, below line: NSRect) {
        label.attributedStringValue = render(page)
        let text = label.fittingSize
        let size = NSSize(width: ceil(text.width) + padding.width * 2, height: ceil(text.height) + padding.height * 2)
        label.frame = NSRect(x: padding.width, y: padding.height, width: ceil(text.width), height: ceil(text.height))
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size, line: line))
        panel.orderFrontRegardless()
    }

    private func origin(for size: NSSize, line: NSRect) -> NSPoint {
        // 有的应用给不出光标位置（返回全零），就放在鼠标旁边
        let anchor = line.origin == .zero && line.size == .zero
            ? NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 0, height: 18))
            : line
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 10000, height: 10000)
        var x = anchor.minX
        var y = anchor.minY - size.height - gap
        if y < visible.minY {
            // 下面放不下就放到这一行上面
            y = anchor.maxY + gap
        }
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    private func render(_ page: CandidatePage) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 17)
        let small = NSFont.systemFont(ofSize: 12)
        let out = NSMutableAttributedString()
        for (i, text) in page.texts.enumerated() {
            if i > 0 {
                out.append(NSAttributedString(string: "  ", attributes: [.font: font]))
            }
            let current = i == page.cursor
            let color: NSColor = current ? .selectedMenuItemTextColor : .labelColor
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            var numberAttrs: [NSAttributedString.Key: Any] = [.font: small,
                                                              .foregroundColor: current ? color : NSColor.secondaryLabelColor]
            if current {
                attrs[.backgroundColor] = NSColor.controlAccentColor
                numberAttrs[.backgroundColor] = NSColor.controlAccentColor
            }
            out.append(NSAttributedString(string: " \(i + 1) ", attributes: numberAttrs))
            out.append(NSAttributedString(string: "\(text) ", attributes: attrs))
        }
        if page.pageCount > 1 {
            let arrows = (page.hasPrev ? "◀" : "◁") + (page.hasNext ? "▶" : "▷")
            out.append(NSAttributedString(string: "   \(arrows) \(page.pageIndex + 1)/\(page.pageCount)",
                                          attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return out
    }
}
