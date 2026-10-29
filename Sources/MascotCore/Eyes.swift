import CoreGraphics

/// 闭合多边形的顶点，画布单位
public typealias EyeOutline = [CGPoint]

/// 盾盾的眼睛长什么样，以及两种眼形之间怎么逐点补间。
/// 不知道眼睛贴在球面上怎么转（`Sphere`、App 的图层树），也不知道什么时候换（App）。
///
/// Core Animation 只在两条路径点数、结构完全相同时才能逐点补间，所以所有眼形（实心的、描边的）都化成
/// `pointCount` 个点、绕向一致的闭合多边形；换形前再旋转起点对齐上一个形状，补间时不打转（docs/mascot.md §3）。
/// @see https://github.com/veltman/flubber
/// @see https://developer.apple.com/documentation/quartzcore/cashapelayer/path
public enum Eyes {
    public static let pointCount = 120
    /// 眼睛整体放大倍数，以各自的静止中心为原点（docs/mascot.md §1）
    public static let scale: CGFloat = 1.35

    /// 旋转起点，让 p 和上一个形状 q 对应点的平方距离之和最小
    public static func aligned(_ p: EyeOutline, to q: EyeOutline) -> EyeOutline {
        precondition(p.count == q.count, "点数不同不能对齐")
        let n = p.count
        func cost(_ k: Int) -> CGFloat {
            (0..<n).reduce(0) { s, i in let d = p[(i + k) % n] - q[i]; return s + d.x * d.x + d.y * d.y }
        }
        guard let k = (0..<n).min(by: { cost($0) < cost($1) }) else { return p }
        return Array(p[k...] + p[..<k])
    }

    /// 眨眼闭上的样子：以自己的竖直中心为轴压到 0.1 倍高
    public static func shut(_ p: EyeOutline) -> EyeOutline {
        let ys = p.map(\.y)
        guard let lo = ys.min(), let hi = ys.max() else { return p }
        let mid = (lo + hi) / 2
        return p.map { CGPoint(x: $0.x, y: mid + ($0.y - mid) * 0.1) }
    }

    /// 任意折线化成标准的闭合多边形：按弧长等距重采样到 pointCount 点，统一绕向
    static func ring(_ raw: EyeOutline) -> EyeOutline {
        var p = resample(raw, closed: true, count: pointCount)
        let area = p.indices.reduce(CGFloat(0)) { s, i in let a = p[i], b = p[(i + 1) % p.count]; return s + a.x * b.y - b.x * a.y }
        if area < 0 { p.reverse() }
        return p
    }

    /// 路径拍平成折线的顶点
    static func points(_ path: CGPath) -> EyeOutline {
        var out: EyeOutline = []
        path.flattened(threshold: 0.004).applyWithBlock { e in
            if e.pointee.type == .moveToPoint || e.pointee.type == .addLineToPoint { out.append(e.pointee.points[0]) }
        }
        return out
    }

    /// 按弧长等距重采样
    static func resample(_ pts: EyeOutline, closed: Bool, count: Int) -> EyeOutline {
        guard let first = pts.first else { preconditionFailure("空折线") }
        let line = closed ? pts + [first] : pts
        var acc: [CGFloat] = [0]
        for i in 1..<line.count { acc.append(acc[i - 1] + hypot(line[i].x - line[i - 1].x, line[i].y - line[i - 1].y)) }
        let total = acc[acc.count - 1]
        var i = 1
        return (0..<count).map { k in
            let s = total * CGFloat(k) / CGFloat(closed ? count : count - 1)
            while i < acc.count - 1 && acc[i] < s { i += 1 }
            let seg = acc[i] - acc[i - 1]
            let u = seg > 0 ? (s - acc[i - 1]) / seg : 0
            return line[i - 1] + (line[i] - line[i - 1]) * u
        }
    }

    /// 圆头描边化成轮廓：中线 64 点，左侧去、半圆头、右侧回、半圆头
    static func outline(_ center: CGPath, width: CGFloat) -> EyeOutline {
        let c = resample(points(center), closed: false, count: 64)
        let h = width / 2
        let normals = c.indices.map { i -> CGPoint in
            let d = c[min(i + 1, c.count - 1)] - c[max(i - 1, 0)]
            let len = hypot(d.x, d.y)
            return CGPoint(x: -d.y / len, y: d.x / len)
        }
        func cap(_ p: CGPoint, from n: CGPoint) -> EyeOutline {
            let a0 = atan2(n.y, n.x)
            return (1..<12).map { k in
                let a = a0 - .pi * CGFloat(k) / 12
                return p + CGPoint(x: cos(a), y: sin(a)) * h
            }
        }
        let left = c.indices.map { c[$0] + normals[$0] * h }
        let right = c.indices.map { c[$0] - normals[$0] * h }
        return left + cap(c[c.count - 1], from: normals[normals.count - 1]) + right.reversed() + cap(c[0], from: normals[0] * -1)
    }
}

extension Look {
    /// 左右眼，各自以静止中心为原点，放大 ×1.35 之前（docs/mascot.md §3）
    public var eyes: (left: EyeOutline, right: EyeOutline) {
        let (l, r) = design
        return (Eyes.ring(l), Eyes.ring(r))
    }

    /// 眼形草图：拍平的折线，还没重采样
    private var design: (EyeOutline, EyeOutline) {
        func ellipse(_ rx: CGFloat, _ ry: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> EyeOutline {
            Eyes.points(CGPath(ellipseIn: CGRect(x: dx - rx, y: dy - ry, width: 2 * rx, height: 2 * ry), transform: nil))
        }
        func stroke(_ w: CGFloat, _ build: (CGMutablePath) -> Void) -> EyeOutline {
            let p = CGMutablePath()
            build(p)
            return Eyes.outline(p, width: w)
        }
        func pair(_ p: EyeOutline) -> (EyeOutline, EyeOutline) { (p, p.map { CGPoint(x: -$0.x, y: $0.y) }) }

        switch self {
        case .idle, .offline: return pair(ellipse(1.05, 1.55))
        case .approval: return pair(ellipse(1.3, 1.75))
        case .question: return pair(ellipse(1.25, 1.9))
        case .mismatch: return pair(ellipse(1.45, 1.45))
        case .thinking:
            let e = ellipse(0.95, 1.3, dx: 0.35, dy: -0.5)
            return (e, e)
        case .working:
            let e = ellipse(1.0, 1.3, dy: 0.3)
            return (e, e)
        case .longTurn: return pair(ellipse(1.0, 1.1, dy: 0.35))
        case .shielded: return pair(ellipse(1.15, 1.5).map { CGPoint(x: $0.x, y: max($0.y, -0.75)) })
        case .stale: return pair(ellipse(1.15, 1.6).map { CGPoint(x: $0.x, y: max($0.y, -0.25)) })
        case .danger:
            // 左眼的 +x 是靠鼻梁的内侧：斜眉往内侧压下来
            return pair(ellipse(1.3, 1.6).map { CGPoint(x: $0.x, y: max($0.y, -0.55 + 0.6 * $0.x)) })
        case .sleeping:
            return pair(stroke(0.9) { $0.move(to: CGPoint(x: -1.7, y: -0.5)); $0.addQuadCurve(to: CGPoint(x: 1.7, y: -0.5), control: CGPoint(x: 0, y: 1.5)) })
        case .finished:
            return pair(stroke(0.9) { $0.move(to: CGPoint(x: -1.7, y: 0.9)); $0.addQuadCurve(to: CGPoint(x: 1.7, y: 0.9), control: CGPoint(x: 0, y: -1.3)) })
        case .interrupted:
            return pair(stroke(0.9) { $0.move(to: CGPoint(x: -1.25, y: 0)); $0.addLine(to: CGPoint(x: 1.25, y: 0)) })
        case .error:
            return pair(stroke(0.85) { $0.addLines(between: [CGPoint(x: -1.05, y: -1.45), CGPoint(x: 1.05, y: 0), CGPoint(x: -1.05, y: 1.45)]) })
        case .dizzy:
            // 半圆接半圆的螺旋，半径 .35 → 1.4；clockwise: true 在 +y 向下的画布里是角度递减
            let s = stroke(0.55) { p in
                p.move(to: CGPoint(x: 0.35, y: 0))
                for (i, r) in [0.35, 0.7, 1.05, 1.4].enumerated() {
                    p.addArc(center: CGPoint(x: i % 2 == 0 ? 0 : 0.35, y: 0), radius: r,
                             startAngle: i % 2 == 0 ? 0 : .pi, endAngle: i % 2 == 0 ? .pi : 0, clockwise: true)
                }
            }
            return (s, s)
        }
    }
}

/// 眼睛贴在球面上的位置。不知道球怎么转（App 用 Core Animation 的 3D 变换）
public enum Sphere {
    /// 把正前方的点转到静止中心要的角度，弧度，约定同 `HeadPose`（pitch + = 往上）：
    /// lat = asin((y − cy) / r)，lon = asin((x − cx) / (r cos lat))（docs/mascot.md §1）。
    /// 眼睛在赤道下方（y 比圆心大），所以 pitch = −lat；先绕 x 轴转 pitch，再绕 y 轴转 yaw
    public static func place(_ rest: CGPoint) -> (pitch: Double, yaw: Double) {
        let c = Anatomy.bodyCenter, r = Double(Anatomy.bodyRadius)
        let lat = asin(Double(rest.y - c.y) / r)
        return (-lat, asin(Double(rest.x - c.x) / (r * cos(lat))))
    }
}

func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
