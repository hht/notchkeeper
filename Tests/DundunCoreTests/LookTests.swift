import CoreGraphics
import Testing
@testable import DundunCore

@Suite struct LookTests {
    /// docs/dundun.md §1：眼睛都在身体圆里
    @Test func eyesInsideBody() {
        for e in EyeShape.allCases {
            for part in [e.left, e.right] {
                let b = part.path.boundingBoxOfPath
                for p in [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                          CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.maxX, y: b.maxY)] {
                    #expect(hypot(p.x - Anatomy.bodyCenter.x, p.y - Anatomy.bodyCenter.y) < Anatomy.bodyRadius, "\(e)")
                }
            }
        }
    }

    /// 左右眼分居眼睛中心两侧
    @Test func eyesAroundCenters() {
        for e in EyeShape.allCases {
            #expect(abs(e.left.path.boundingBoxOfPath.midX - 10.5) < 0.6, "\(e)")
            #expect(abs(e.right.path.boundingBoxOfPath.midX - 17.5) < 0.6, "\(e)")
        }
    }

    /// docs/dundun.md §1：装饰只在右上 x 18.5–28、y 0.5–8.5（40pt 第三个 Z 例外），不压身体圆
    @Test func decorationStaysInCorner() {
        let corner = CGRect(x: 18.5, y: 0.5, width: 9.5, height: 8)
        let thirdZ = CGRect(x: 28.5, y: -3.6, width: 5, height: 4.2)
        for l in Look.allCases {
            for s in Size.allCases {
                for (i, part) in l.decoration(s).enumerated() {
                    let b = part.path.boundingBoxOfPath
                    let area = (l == .sleeping && i == 2) ? thirdZ : corner
                    #expect(area.insetBy(dx: -0.01, dy: -0.01).contains(b), "\(l) \(s) #\(i) \(b)")
                }
            }
        }
    }

    /// 第三个 Z 和气泡里的 ? 只有 40pt 版有
    @Test func largeOnlyDetails() {
        #expect(Look.sleeping.decoration(.small).count == 2 && Look.sleeping.decoration(.large).count == 3)
        #expect(Look.question.decoration(.large).count > Look.question.decoration(.small).count)
    }

    @Test func undecoratedLooks() {
        for l in [Look.idle, .working, .interrupted, .dizzy] { #expect(l.decoration(.large).isEmpty, "\(l)") }
    }

    /// 右耳：docs/dundun.md §2 表的最后一列；守卫 unknown 的另两种原因也是灰色空心环
    @Test(arguments: [
        (Look.idle, false, false, EarIndicator.none), (.idle, false, true, .error), (.idle, true, false, .unknown),
        (.thinking, false, false, .dots), (.working, false, false, .dots), (.question, false, false, .question),
        (.error, false, false, .error), (.mismatch, false, false, .mismatch), (.stale, false, false, .unknown),
        (.danger, false, false, .danger), (.finished, false, false, .none), (.sleeping, false, false, .none),
    ])
    func ear(_ look: Look, _ guardUnknown: Bool, _ errorUnread: Bool, _ expected: EarIndicator) {
        #expect(EarIndicator.for(look, guardUnknown: guardUnknown, errorUnread: errorUnread) == expected)
    }
}
