import CoreGraphics
import Testing
@testable import DundunCore

@Suite struct GazeTests {
    private func gaze(_ x: CGFloat, _ y: CGFloat) -> Gaze { Gaze(toward: CGVector(dx: x, dy: y)) }

    /// docs/dundun.md §5：400pt 以外不跟
    @Test func outOfReachRests() {
        #expect(gaze(401, 0) == .rest)
        #expect(gaze(0, -900) == .rest)
    }

    /// 死区：鼠标就在盾盾身上时不斜眼
    @Test func deadZoneRests() {
        #expect(gaze(3, -2) == .rest)
    }

    /// 眼睛最多偏 1.5 单位，身体最多倾斜 4°
    @Test func capped() {
        for (x, y) in [(200.0, 0.0), (-150, 120), (0, 250), (90, -90), (299, 1)] {
            let g = gaze(x, y)
            #expect(hypot(g.eyes.dx, g.eyes.dy) <= 1.5 + 1e-9)
            #expect(abs(g.tilt) <= 4 * .pi / 180 + 1e-9)
        }
        #expect(abs(hypot(gaze(200, 0).eyes.dx, gaze(200, 0).eyes.dy) - 1.5) < 1e-9)
        #expect(abs(gaze(250, 0).tilt - 4 * .pi / 180) < 1e-9)
    }

    /// 眼睛朝鼠标看，身体往鼠标那边歪（+ = 顺时针，向右）
    @Test func direction() {
        let right = gaze(200, 0), left = gaze(-200, 0), below = gaze(0, 200)
        #expect(right.eyes.dx > 0 && right.tilt > 0)
        #expect(left.eyes.dx < 0 && left.tilt < 0)
        #expect(below.eyes.dy > 0 && below.tilt == 0)
    }

    /// 快到 400pt 时渐弱，不在边界上一下跳回正
    @Test func fadesNearEdge() {
        let near = gaze(360, 0), mid = gaze(250, 0)
        #expect(near.eyes.dx > 0 && near.eyes.dx < mid.eyes.dx)
    }

    /// 结果按格取整：鼠标挪一两个点，结果不变，App 就不重新提交动画
    @Test func quantized() {
        #expect(gaze(200, 40) == gaze(201, 40.5))
        #expect(gaze(200, 40) != gaze(-200, 40))
    }

    /// 格子是 0.25 单位、0.5°：眼睛最多偏 1.5 单位，6 档足够，弹簧会把台阶抹平；
    /// 格子太细时鼠标每动一下都要提交一次动画（实测 0.1 单位的格子，鼠标绕圈时跟随要多花约 1% CPU）
    @Test func gridIsCoarse() {
        for x in stride(from: -390.0, through: 390, by: 7) {
            for y in stride(from: -390.0, through: 390, by: 11) {
                let g = gaze(x, y)
                for v in [g.eyes.dx / 0.25, g.eyes.dy / 0.25, g.tilt / (0.5 * .pi / 180)] {
                    #expect(abs(v - v.rounded()) < 1e-6, "\(x),\(y) → \(g)")
                }
            }
        }
    }
}
