import SwiftUI
import Testing
@testable import Notchkeeper

@Suite struct ClaudeMarkPath {
    /// 小写是相对上一个点，大写是绝对；m 后面多出来的坐标对是隐式的 l
    @Test func relativeAndAbsoluteCommands() {
        var expected = Path()
        expected.move(to: CGPoint(x: 1, y: 2))
        expected.addLine(to: CGPoint(x: 4, y: 6))
        expected.addLine(to: CGPoint(x: 9, y: 6))
        expected.addLine(to: CGPoint(x: 9, y: 0.5))
        expected.addCurve(to: CGPoint(x: 10, y: 3.5), control1: CGPoint(x: 9.5, y: 0.5), control2: CGPoint(x: 10, y: 1.5))
        expected.addLine(to: CGPoint(x: 0, y: 0))
        expected.closeSubpath()
        #expect(ClaudeMark.path("m1 2 3 4h5v-5.5c.5 0 1 1 1 3L0 0Z") == expected)
    }

    /// 照抄的路径大量省略命令字母（l / h / c 连着写多组）、把数字挤在一起（`1.5.5` 是 1.5 和 .5，`.25-1` 是 .25 和 -1）
    @Test func implicitRepeatsAndPackedNumbers() {
        var expected = Path()
        expected.move(to: .zero)
        expected.addLine(to: CGPoint(x: 1.5, y: 0.5))
        expected.addLine(to: CGPoint(x: 1.75, y: -0.5))
        expected.addLine(to: CGPoint(x: 2.75, y: -0.5))
        expected.addLine(to: CGPoint(x: 3.75, y: -0.5))
        expected.addCurve(to: CGPoint(x: 4.75, y: -0.5), control1: CGPoint(x: 3.75, y: 0.5), control2: CGPoint(x: 4.75, y: 0.5))
        expected.addCurve(to: CGPoint(x: 5.75, y: -0.5), control1: CGPoint(x: 4.75, y: -1.5), control2: CGPoint(x: 5.75, y: -1.5))
        #expect(ClaudeMark.path("M0 0l1.5.5.25-1h1 1c0 1 1 1 1 0 0-1 1-1 1 0") == expected)
    }

    /// 照抄的整条路径解得完，并且铺满 100 × 100 画布
    @Test func markFillsItsCanvas() {
        let box = ClaudeMark.unit.boundingRect
        #expect(box.minX >= 0 && box.minY >= 0 && box.maxX <= 100 && box.maxY <= 100)
        #expect(box.width > 95 && box.height > 95)
    }
}
