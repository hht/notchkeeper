import CoreGraphics
import Testing
@testable import MascotCore

private let deg = Double.pi / 180

@Suite struct GazeTests {
    private func gaze(_ x: CGFloat, _ y: CGFloat) -> Gaze { Gaze(toward: CGVector(dx: x, dy: y)) }

    /// docs/mascot.md §5「跟随鼠标」：两轴各自线性，yaw 25° × dx / 400，pitch 20° × dy / 400（dy 向上为正）
    @Test func linearPerAxis() {
        #expect(abs(gaze(200, 0).yaw - 12.5 * deg) < 1e-9 && gaze(200, 0).pitch == 0)
        #expect(abs(gaze(0, -200).pitch - 10 * deg) < 1e-9)
        #expect(abs(gaze(0, 200).pitch + 10 * deg) < 1e-9)
        #expect(gaze(-400, 0).yaw == -25 * deg)
    }

    /// 超过 400pt 停在最大角度，不跳回正
    @Test func clampsBeyondReach() {
        #expect(gaze(401, 0).yaw == 25 * deg)
        #expect(gaze(5000, -5000) == gaze(400, -400))
        #expect(gaze(0, 900).pitch == -20 * deg)
    }

    /// 取整到 0.5°：鼠标挪一两个点结果不变，App 就不重新提交动画
    @Test func quantized() {
        #expect(gaze(200, 40) == gaze(201, 40.5))
        for x in stride(from: -390.0, through: 390, by: 7) {
            let g = gaze(x, x / 3)
            for v in [g.yaw / (0.5 * deg), g.pitch / (0.5 * deg)] { #expect(abs(v - v.rounded()) < 1e-9) }
        }
    }

    @Test func centerRests() {
        #expect(gaze(0, 0) == .rest)
    }
}
