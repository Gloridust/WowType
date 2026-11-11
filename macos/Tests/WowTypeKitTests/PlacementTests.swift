import CoreGraphics
import Testing
@testable import WowTypeKit

// 候选框位置：坐标和 macOS 屏幕坐标一样，原点在左下角。

private let main = ScreenRects(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                               visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
// 右边一块屏，底边对齐
private let right = ScreenRects(frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
// 上面一块屏
private let above = ScreenRects(frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
                                visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 875))

@Suite("锚点矩形校验")
struct AnchorTests {
    @Test func caretAtEndIsClampedToLastCharacter() {
        var asked: [Int] = []
        let r = AnchorResolver.resolve(caret: 3, length: 3, lastGood: nil) { i in
            asked.append(i)
            return CGRect(x: 100 + Double(i) * 10, y: 500, width: 10, height: 18)
        }
        #expect(asked == [2])
        #expect(r == CGRect(x: 120, y: 500, width: 10, height: 18))
    }

    @Test func stepsBackOverZeroAndGarbageRects() {
        let answers: [Int: CGRect] = [
            2: .zero,
            1: CGRect(x: CGFloat.nan, y: 3, width: 1, height: 1),
            0: CGRect(x: 40, y: 300, width: 9, height: 17),
        ]
        var asked: [Int] = []
        let r = AnchorResolver.resolve(caret: 2, length: 4, lastGood: nil) { i in
            asked.append(i)
            return answers[i]
        }
        #expect(asked == [2, 1, 0])
        #expect(r == CGRect(x: 40, y: 300, width: 9, height: 17))
    }

    @Test func originAtZeroIsRejected() {
        let r = AnchorResolver.resolve(caret: 0, length: 1, lastGood: nil) { _ in
            CGRect(x: 0, y: 0, width: 16, height: 16)
        }
        #expect(r == nil)
    }

    @Test func infiniteRectIsRejected() {
        let r = AnchorResolver.resolve(caret: 0, length: 1, lastGood: nil) { _ in
            CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 16)
        }
        #expect(r == nil)
    }

    @Test func zeroWidthCaretLineIsAccepted() {
        // 光标是一条竖线：宽为 0、高不为 0，可以用。
        let line = CGRect(x: 200, y: 400, width: 0, height: 18)
        #expect(AnchorResolver.resolve(caret: 0, length: 1, lastGood: nil) { _ in line } == line)
    }

    @Test func fallsBackToLastGoodRect() {
        let last = CGRect(x: 50, y: 60, width: 8, height: 16)
        #expect(AnchorResolver.resolve(caret: 1, length: 2, lastGood: last) { _ in nil } == last)
    }

    @Test func emptyPreeditAsksIndexZero() {
        var asked: [Int] = []
        _ = AnchorResolver.resolve(caret: 0, length: 0, lastGood: nil) { i in asked.append(i); return nil }
        #expect(asked == [0])
    }
}

@Suite("选屏")
struct ScreenPickTests {
    @Test func screenContainingAnchorWins() {
        let a = CGRect(x: 2000, y: 500, width: 10, height: 18)
        #expect(ScreenPicker.pick(anchor: a, screens: [main, right], fallback: 0) == right)
    }

    @Test func notTheFirstScreenByDefault() {
        let a = CGRect(x: 300, y: 1200, width: 10, height: 18)
        #expect(ScreenPicker.pick(anchor: a, screens: [main, right, above], fallback: 0) == above)
    }

    @Test func containmentUsesFullFrameNotVisibleFrame() {
        // 菜单栏所在的那一条不在 visibleFrame 里，但仍是这块屏。
        let a = CGRect(x: 300, y: 1790, width: 10, height: 8)
        #expect(ScreenPicker.pick(anchor: a, screens: [main, above], fallback: 0) == above)
    }

    @Test func outsideAllScreensUsesLargestIntersection() {
        let a = CGRect(x: 1430, y: 1000, width: 40, height: 18)  // 左上屏和右屏之间的空隙上方
        #expect(ScreenPicker.pick(anchor: a, screens: [main, right], fallback: 0) == right)
    }

    @Test func farAwayUsesNearestScreen() {
        let a = CGRect(x: 5000, y: 500, width: 10, height: 18)
        #expect(ScreenPicker.pick(anchor: a, screens: [main, right], fallback: 0) == right)
    }

    @Test func noScreensGivesNil() {
        #expect(ScreenPicker.pick(anchor: .zero, screens: [], fallback: 0) == nil)
    }
}

@Suite("候选框摆放")
struct PlacementTests {
    let size = CGSize(width: 300, height: 40)

    @Test func belowTheLineWithGap() {
        let a = CGRect(x: 100, y: 500, width: 10, height: 18)
        let p = CandidatePlacement.place(size: size, anchor: a, screen: main, stickyAbove: false)
        #expect(p.frame == CGRect(x: 100, y: 500 - CandidatePlacement.gap - 40, width: 300, height: 40))
        #expect(p.above == false)
    }

    @Test func flipsAboveAtBottomEdge() {
        let a = CGRect(x: 100, y: 90, width: 10, height: 18)
        let p = CandidatePlacement.place(size: size, anchor: a, screen: main, stickyAbove: false)
        #expect(p.frame.minY == 108 + CandidatePlacement.gap)
        #expect(p.above)
    }

    @Test func stickyAboveStaysAbove() {
        let a = CGRect(x: 100, y: 500, width: 10, height: 18)
        let p = CandidatePlacement.place(size: size, anchor: a, screen: main, stickyAbove: true)
        #expect(p.above)
        #expect(p.frame.minY == 518 + CandidatePlacement.gap)
    }

    @Test func stickyAboveGivesUpWhenAboveDoesNotFit() {
        let a = CGRect(x: 100, y: 850, width: 10, height: 18)
        let p = CandidatePlacement.place(size: size, anchor: a, screen: main, stickyAbove: true)
        #expect(p.above == false)
    }

    @Test func clampedAtRightEdge() {
        let a = CGRect(x: 1400, y: 500, width: 10, height: 18)
        let p = CandidatePlacement.place(size: size, anchor: a, screen: main, stickyAbove: false)
        #expect(p.frame.maxX == 1440)
    }

    @Test func clampedAtLeftEdgeOfSecondScreen() {
        let a = CGRect(x: 1300, y: 500, width: 10, height: 18)
        let p = CandidatePlacement.place(size: size, anchor: a, screen: right, stickyAbove: false)
        #expect(p.frame.minX == 1440)
    }

    @Test func underMenuBarStaysInsideVisibleFrame() {
        let a = CGRect(x: 100, y: 880, width: 10, height: 18)
        let p = CandidatePlacement.place(size: size, anchor: a, screen: main, stickyAbove: false)
        #expect(p.frame.maxY <= main.visibleFrame.maxY)
        #expect(p.frame.minY >= main.visibleFrame.minY)
    }

    @Test func hugeLineHeightIsIgnoredForFlip() {
        // 有的应用给出 600pt 高的行：按 0 高处理，不翻到屏幕外。
        let a = CGRect(x: 100, y: 90, width: 10, height: 600)
        let p = CandidatePlacement.place(size: size, anchor: a, screen: main, stickyAbove: false)
        #expect(p.frame.minY == 90 + CandidatePlacement.gap)
        #expect(p.above)
    }

    @Test func tallPanelFitsNeitherSideGoesBesideAndClamps() {
        let tall = CGSize(width: 200, height: 700)
        let a = CGRect(x: 100, y: 450, width: 10, height: 18)
        let p = CandidatePlacement.place(size: tall, anchor: a, screen: main, stickyAbove: false)
        #expect(p.frame.minX >= a.maxX)
        #expect(main.visibleFrame.contains(p.frame))
    }

    @Test func fractionalSizeIsRoundedUp() {
        let a = CGRect(x: 100, y: 500, width: 10, height: 18)
        let p = CandidatePlacement.place(size: CGSize(width: 99.2, height: 30.4), anchor: a,
                                         screen: main, stickyAbove: false)
        #expect(p.frame.size == CGSize(width: 100, height: 31))
    }

    @Test func panelWiderThanScreenStartsAtLeftEdge() {
        let a = CGRect(x: 100, y: 500, width: 10, height: 18)
        let p = CandidatePlacement.place(size: CGSize(width: 2000, height: 40), anchor: a,
                                         screen: main, stickyAbove: false)
        #expect(p.frame.minX == 0)
    }
}
