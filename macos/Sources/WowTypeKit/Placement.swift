// 候选框放在哪：纯计算，不碰 AppKit，屏幕以矩形传进来，方便测试。
//
// 坐标和 macOS 屏幕坐标一样，原点在左下角。做法参考：
// - 锚点校验：McBopomofo（光标在末尾时取最后一个字）、fcitx5-macos（第 n 个位置返回 (0,0)，往回退）；
// - 选屏：按锚点所在的屏（frame 含菜单栏），不用 NSScreen.main；都不含时取相交最多的，再取最近的；
// - 摆放：先放行下面，放不下翻到上面，上下都放不下放到旁边，最后夹进 visibleFrame；
//   已经在上面时只要放得下就留在上面，免得高度一变就上下跳（fcitx5-webview）；
//   行高超过半屏当作 0（vChewing）。
import CoreGraphics

/// 一块屏：frame 是整块，visibleFrame 去掉菜单栏和 Dock。
public struct ScreenRects: Sendable, Hashable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum AnchorResolver {
    /// 找候选框的锚点（编辑区里某个字所在的行矩形）。
    /// - caret、length：编辑区里光标位置和总长度（UTF-16 单位，和 IMK 的下标一致）。
    /// - query：问应用第 i 个字的矩形（attributes(forCharacterIndex:lineHeightRectangle:)）。
    /// 光标在末尾时问最后一个字；结果不可用就往前一个个问；都不行用上一次好的；再不行返回 nil。
    public static func resolve(caret: Int, length: Int, lastGood: CGRect?,
                               query: (Int) -> CGRect?) -> CGRect? {
        let start = length > 0 ? min(max(caret, 0), length - 1) : 0
        for index in stride(from: start, through: 0, by: -1) {
            if let rect = query(index), isUsable(rect) { return rect }
        }
        if let lastGood, isUsable(lastGood) { return lastGood }
        return nil
    }

    /// 应用给的矩形能不能用：要有限、不能是空矩形、不能落在 (0,0)（应用没算出来时常给这个）。
    public static func isUsable(_ rect: CGRect) -> Bool {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        guard values.allSatisfy({ $0.isFinite }) else { return false }
        if rect.size.width == 0 && rect.size.height == 0 { return false }
        if rect.origin == .zero { return false }
        return true
    }
}

public enum ScreenPicker {
    /// 按锚点选屏。fallback 是锚点坐标不可用时用的屏的下标（一般是主屏）。
    public static func pick(anchor: CGRect, screens: [ScreenRects], fallback: Int) -> ScreenRects? {
        guard !screens.isEmpty else { return nil }
        let fallbackScreen = screens.indices.contains(fallback) ? screens[fallback] : screens[0]
        let point = anchor.origin
        guard point.x.isFinite, point.y.isFinite else { return fallbackScreen }

        if let hit = screens.first(where: { $0.frame.contains(point) }) { return hit }

        let overlaps = screens.map { screen -> CGFloat in
            let i = screen.frame.intersection(anchor)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0 {
            return screens[best]
        }
        return screens.min { distance(point, $0.frame) < distance(point, $1.frame) } ?? fallbackScreen
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}

public enum CandidatePlacement {
    /// 候选框和行之间的空隙。
    public static let gap: CGFloat = 4

    public struct Result: Sendable, Hashable {
        public var frame: CGRect
        /// 放在行的上面。候选框还开着时下一次把它作为 stickyAbove 传回来。
        public var above: Bool
    }

    public static func place(size: CGSize, anchor: CGRect, screen: ScreenRects, stickyAbove: Bool) -> Result {
        let width = size.width.rounded(.up)
        let height = size.height.rounded(.up)
        let visible = screen.visibleFrame
        var line = anchor.standardized
        if line.height > visible.height / 2 { line.size.height = 0 }

        let belowY = line.minY - gap - height
        let aboveY = line.maxY + gap
        let fitsBelow = belowY >= visible.minY
        let fitsAbove = aboveY + height <= visible.maxY

        var x = line.minX
        let y: CGFloat
        let above: Bool
        if stickyAbove && fitsAbove {
            (y, above) = (aboveY, true)
        } else if fitsBelow {
            (y, above) = (belowY, false)
        } else if fitsAbove {
            (y, above) = (aboveY, true)
        } else {
            // 上下都放不下：放到行的右边，右边也放不下就放左边，竖直方向和行居中。
            x = line.maxX + gap + width <= visible.maxX ? line.maxX + gap : line.minX - gap - width
            (y, above) = (line.midY - height / 2, false)
        }

        let clampedX = clamp(x, visible.minX, max(visible.minX, visible.maxX - width))
        let clampedY = clamp(y, visible.minY, max(visible.minY, visible.maxY - height))
        return Result(frame: CGRect(x: clampedX, y: clampedY, width: width, height: height), above: above)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
}
