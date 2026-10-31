import CoreGraphics
import Testing
@testable import MascotCore

private let deg = Double.pi / 180

@Suite struct LookTests {
    /// docs/mascot.md §2：16 个造型
    @Test func sixteenLooks() {
        #expect(Look.allCases.count == 16)
    }

    /// docs/mascot.md §2：sign 造型（收起时装饰挪到右耳）
    @Test func signs() {
        #expect(Set(Look.allCases.filter(\.isSign)) == [.error, .offline, .mismatch, .stale, .danger, .shielded])
    }

    /// 新增 4 个造型的渐变
    @Test(arguments: [
        (Look.longTurn, 0xDCEBFF as UInt32, 0x9CC6F5 as UInt32), (.approval, 0xF0F7D4, 0xC6DE7E),
        (.offline, 0xE6E8EC, 0xB4BAC4), (.shielded, 0xFFC9C2, 0xE8857B),
    ])
    func newGradients(_ look: Look, _ top: UInt32, _ bottom: UInt32) {
        #expect(look.gradient.top == RGB(top) && look.gradient.bottom == RGB(bottom))
    }

    /// 各造型的朝向（度）
    @Test(arguments: [
        (Look.sleeping, 0.0, -14.0, 0.0), (.thinking, 10, 10, 4), (.working, 0, -10, 0), (.longTurn, 0, -10, 0),
        (.question, 0, 0, -10), (.approval, 0, 8, 0), (.finished, 0, 10, 0), (.error, 0, -8, 0),
        (.stale, 0, -6, 0), (.shielded, 0, 4, 0), (.idle, 0, 0, 0), (.danger, 0, 0, 0),
    ])
    func pose(_ look: Look, _ yaw: Double, _ pitch: Double, _ roll: Double) {
        let p = look.pose
        #expect(abs(p.yaw - yaw * deg) < 1e-12 && abs(p.pitch - pitch * deg) < 1e-12 && abs(p.roll - roll * deg) < 1e-12, "\(look)")
    }

    /// docs/mascot.md §5：睁眼的造型（眨眼、看鼠标、探头）
    @Test func openEyes() {
        #expect(Set(Look.allCases.filter(\.opensEyes))
            == [.idle, .thinking, .working, .longTurn, .question, .approval, .offline, .mismatch, .stale, .shielded])
    }
}

@Suite struct DecorationTests {
    /// 装饰只在右上 x 18.5–28、y 0.5–8.5（第三个 Z 例外），不压身体圆
    @Test func staysInCorner() {
        let corner = CGRect(x: 18.5, y: 0.5, width: 9.5, height: 8)
        let thirdZ = CGRect(x: 28.5, y: -3.6, width: 5, height: 4.2)
        for l in Look.allCases {
            for (i, part) in l.decoration.enumerated() {
                let b = part.spec.path.boundingBoxOfPath
                let area = (l == .sleeping && i == 2) ? thirdZ : corner
                #expect(area.insetBy(dx: -0.01, dy: -0.01).contains(b), "\(l) #\(i) \(b)")
            }
        }
    }

    /// 三个 Z；气泡里带 ?（气泡、问号、点）
    @Test func details() {
        #expect(Look.sleeping.decoration.count == 3)
        #expect(Look.question.decoration.count == 3)
    }

    @Test func undecoratedLooks() {
        for l in [Look.idle, .working, .interrupted, .dizzy] { #expect(l.decoration.isEmpty, "\(l)") }
    }

    /// docs/mascot.md §4 的锚点列
    @Test(arguments: [
        (Look.approval, 0, CGPoint(x: 24, y: 8)), (.offline, 0, CGPoint(x: 24.5, y: 5)), (.shielded, 1, CGPoint(x: 24.5, y: 5)),
        (.danger, 0, CGPoint(x: 22.25, y: 4.5)), (.danger, 1, CGPoint(x: 25.75, y: 4.5)), (.sleeping, 2, CGPoint(x: 31, y: -1.5)),
        (.finished, 1, CGPoint(x: 21, y: 6.5)), (.longTurn, 0, CGPoint(x: 23.25, y: 4.5)), (.question, 0, CGPoint(x: 23.8, y: 3.6)),
    ])
    func anchors(_ look: Look, _ i: Int, _ anchor: CGPoint) {
        #expect(look.decoration[i].anchor == anchor)
    }

    /// danger 的两个 ! 是两个部件（轮流跳）；offline 是点、两段弧、斜杠；shielded 是锁梁、锁身、锁孔
    @Test func partCounts() {
        #expect(Look.danger.decoration.count == 2)
        #expect(Look.offline.decoration.count == 4)
        #expect(Look.shielded.decoration.count == 3)
    }

    /// 修过的数字：Wi-Fi 的点圆心 (24.5, 7.2) r .65
    @Test func wifiDot() {
        let b = Look.offline.decoration[0].spec.path.boundingBoxOfPath
        #expect(abs(b.midX - 24.5) < 1e-9 && abs(b.midY - 7.2) < 1e-9 && abs(b.width - 1.3) < 1e-9)
    }
}

@Suite struct EarIndicatorTests {
    /// docs/mascot.md §2「右耳指示」：sign 盖过灰环，灰环盖过点
    @Test(arguments: [
        (Look.idle, false, EarIndicator.none), (.idle, true, .ring),
        (.thinking, false, .dots), (.working, false, .dots), (.longTurn, false, .dots), (.working, true, .ring),
        (.question, false, .dot(RGB(0x3CC8DC))), (.approval, false, .dot(RGB(0xB5E04A))), (.approval, true, .ring),
        (.danger, false, .decoration(.danger)), (.danger, true, .decoration(.danger)), (.offline, false, .decoration(.offline)),
        (.error, false, .decoration(.error)), (.finished, false, .none), (.sleeping, false, .none),
    ])
    func indicator(_ look: Look, _ probeFailed: Bool, _ expected: EarIndicator) {
        #expect(EarIndicator.for(look, probeFailed: probeFailed) == expected)
    }
}
