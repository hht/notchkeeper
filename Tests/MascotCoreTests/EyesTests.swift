import CoreGraphics
import Foundation
import Testing
@testable import MascotCore

private func area(_ p: EyeOutline) -> CGFloat {
    p.indices.reduce(0) { s, i in let a = p[i], b = p[(i + 1) % p.count]; return s + a.x * b.y - b.x * a.y } / 2
}

private func cost(_ p: EyeOutline, _ q: EyeOutline) -> CGFloat {
    zip(p, q).reduce(0) { $0 + pow($1.0.x - $1.1.x, 2) + pow($1.0.y - $1.1.y, 2) }
}

private func rotated(_ p: EyeOutline, by k: Int) -> EyeOutline { Array(p[k...] + p[..<k]) }

private func bounds(_ p: EyeOutline) -> CGRect {
    let xs = p.map(\.x), ys = p.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}

@Suite struct EyesTests {
    /// docs/mascot.md §3：所有眼形都是 120 点闭合多边形、绕向一致，才能逐点补间
    @Test func everyLookHasComparableRings() {
        for l in Look.allCases {
            let e = l.eyes
            for p in [e.left, e.right] {
                #expect(p.count == Eyes.pointCount, "\(l)")
                #expect(area(p) > 0, "\(l) 绕向")
            }
        }
    }

    /// 按弧长等距：相邻两点的距离差不多
    @Test func ringIsEvenlySpaced() {
        let p = Look.mismatch.eyes.left
        let d = p.indices.map { i in hypot(p[i].x - p[(i + 1) % p.count].x, p[i].y - p[(i + 1) % p.count].y) }
        #expect(d.max()! - d.min()! < 1e-3)
    }

    /// 右眼是左眼的镜像；看云、看活、螺旋两只眼同向
    @Test func mirroring() {
        for l in Look.allCases {
            let e = l.eyes
            let same = [Look.thinking, .working, .dizzy].contains(l)
            let b = bounds(e.right), a = bounds(e.left)
            let expectedMidX = same ? a.midX : -a.midX
            #expect(abs(b.midX - expectedMidX) < 1e-6 && abs(b.width - a.width) < 1e-6, "\(l)")
        }
    }

    /// O 眼是正圆 r 1.45；竖长大眼 1.25 × 1.9；看云偏到 (0.35, −0.5)
    @Test func sizes() {
        let o = bounds(Look.mismatch.eyes.left)
        #expect(abs(o.width - 2.9) < 0.01 && abs(o.height - 2.9) < 0.01)
        let q = bounds(Look.question.eyes.left)
        #expect(abs(q.width - 2.5) < 0.01 && abs(q.height - 3.8) < 0.01)
        let t = bounds(Look.thinking.eyes.left)
        #expect(abs(t.midX - 0.35) < 0.01 && abs(t.midY + 0.5) < 0.01)
    }

    /// 切过的眼：耷拉眼上沿在 −0.25，镇定眼上沿在 −0.75
    @Test func clipped() {
        #expect(abs(bounds(Look.stale.eyes.left).minY + 0.25) < 1e-6)
        #expect(abs(bounds(Look.shielded.eyes.left).minY + 0.75) < 1e-6)
    }

    /// 描边眼形化成轮廓：笑眼的宽是中线宽 3.4 加线宽 0.9
    @Test func strokeOutline() {
        let b = bounds(Look.finished.eyes.left)
        #expect(abs(b.width - 4.3) < 0.02)
    }

    /// 放大 ×1.35 以后眼睛还在身体圆里（docs/mascot.md §1）
    @Test func insideBody() {
        for l in Look.allCases {
            let e = l.eyes
            for (poly, rest) in [(e.left, Anatomy.leftEye), (e.right, Anatomy.rightEye)] {
                for p in poly {
                    let x = rest.x + p.x * Eyes.scale, y = rest.y + p.y * Eyes.scale
                    #expect(hypot(x - Anatomy.bodyCenter.x, y - Anatomy.bodyCenter.y) < Anatomy.bodyRadius, "\(l)")
                }
            }
        }
    }

    /// 对齐起点：上一个形状换个起点再对齐回来，得到它自己；结果的平方距离是所有起点里最小的
    @Test func alignment() {
        let q = Look.idle.eyes.left
        #expect(Eyes.aligned(rotated(q, by: 37), to: q) == q)
        let p = Look.danger.eyes.left
        let a = Eyes.aligned(p, to: q)
        for k in 0..<p.count { #expect(cost(a, q) <= cost(rotated(p, by: k), q) + 1e-9) }
    }

    /// 眨眼：以竖直中心为轴压到 0.1 倍高，宽不变
    @Test func shut() {
        let open = Look.idle.eyes.left
        let s = Eyes.shut(open)
        let a = bounds(open), b = bounds(s)
        #expect(abs(b.height - a.height * 0.1) < 1e-9 && abs(b.width - a.width) < 1e-9 && abs(b.midY - a.midY) < 1e-9)
    }
}

/// 照 Core Animation 在翻转视图里的约定自己投影一遍（docs/mascot.md §1 实测：rotation.x 正 = 抬头，rotation.y 正 = 脸朝右）：
/// 球心为原点，+z 朝观众，+y 向下。眼睛从正前方 (0, 0, r) 先绕 x 轴转 pitch、再绕 y 轴转 yaw，最后整颗头再转 headYaw
private func project(_ rest: CGPoint, headYaw: Double = 0) -> (x: Double, y: Double, facing: Bool) {
    let (pitch, yaw) = Sphere.place(rest)
    let r = Double(Anatomy.bodyRadius)
    // 抬头：正前方的点往上（−y）走
    let y = -r * sin(pitch), z1 = r * cos(pitch)
    let x = z1 * sin(yaw), z = z1 * cos(yaw)
    let x2 = x * cos(headYaw) + z * sin(headYaw), z2 = -x * sin(headYaw) + z * cos(headYaw)
    return (x2, y, z2 > 0)
}

@Suite struct SphereTests {
    /// docs/mascot.md §1：左眼偏离正中约 20°；在赤道稍下，所以是低头的角度
    @Test func placement() {
        let (pitch, yaw) = Sphere.place(Anatomy.leftEye)
        #expect(abs(pitch + asin(0.05)) < 1e-12)
        #expect(abs(yaw * 180 / .pi + 20.5) < 0.1)
    }

    /// 放回去还是静止中心：x 和 y 都对得上，不偏到中心上方
    @Test func roundTrip() {
        for rest in [Anatomy.leftEye, Anatomy.rightEye] {
            let p = project(rest)
            #expect(abs(p.x - Double(rest.x - Anatomy.bodyCenter.x)) < 1e-9)
            #expect(abs(p.y - Double(rest.y - Anatomy.bodyCenter.y)) < 1e-9)
        }
    }

    /// 脸朝右转 90°：左眼转到右侧边缘附近（还看得见），右眼转到背面；转 180° 两只都看不见
    @Test func turning() {
        let side = project(Anatomy.leftEye, headYaw: 90 * .pi / 180)
        #expect(side.facing && side.x > 9)
        #expect(!project(Anatomy.rightEye, headYaw: 90 * .pi / 180).facing)
        #expect(!project(Anatomy.leftEye, headYaw: .pi).facing && !project(Anatomy.rightEye, headYaw: .pi).facing)
    }
}
