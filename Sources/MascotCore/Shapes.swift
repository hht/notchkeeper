import CoreGraphics

// 盾盾各部件的形状：画布坐标里的 CGPath 和画法。不知道这些形状怎么动。
// 坐标、路径全部照 docs/mascot.md §1、§3、§4，单位是画布单位，原点左上、+y 向下。

/// 身体各部位在画布上的位置
public enum Anatomy {
    public static let bodyCenter = CGPoint(x: 14, y: 16.5)
    public static let bodyRadius: CGFloat = 10
    /// 眼睛中心所在的横线，眨眼以它为轴
    public static let eyeLine: CGFloat = 17
    public static let leftEye = CGPoint(x: 10.5, y: 17)
    public static let rightEye = CGPoint(x: 17.5, y: 17)
    /// 右上装饰区的中心，装饰弹出时以它为锚点
    public static let decoCenter = CGPoint(x: 23.25, y: 4.5)
}

/// 两种画法：20pt（左耳）和 40pt（面板、卡片、设置页）。几何相同，40pt 画布更大、装饰多几笔
public enum Size: CaseIterable, Sendable {
    case small, large

    /// 画布范围：20pt 是 28 × 28；40pt 是 viewBox -4 -6 40 34
    public var canvas: CGRect {
        switch self {
        case .small: return CGRect(x: 0, y: 0, width: 28, height: 28)
        case .large: return CGRect(x: -4, y: -6, width: 40, height: 34)
        }
    }
}

public enum Paint: Equatable, Sendable {
    case fill
    /// 描边都是圆头圆角
    case stroke(CGFloat)
    case fillAndStroke(CGFloat)
}

public struct ShapeSpec: Equatable, @unchecked Sendable {
    public let path: CGPath
    public let paint: Paint
    public let color: RGB
    public let opacity: Double

    init(_ path: CGPath, _ paint: Paint = .fill, _ color: RGB = .ink, opacity: Double = 1) {
        self.path = path
        self.paint = paint
        self.color = color
        self.opacity = opacity
    }
}

public enum EyeShape: CaseIterable, Sendable {
    case round, big, blink, sleep, happy, think, focus, spark, err, dizzy, danger

    public var left: ShapeSpec { eye(Anatomy.leftEye.x, mirrored: false) }
    public var right: ShapeSpec { eye(Anatomy.rightEye.x, mirrored: true) }

    /// cx：这只眼的中心 x。左右眼大多是平移关系；出错、危险两种是镜像，思考是两只不同的眼
    private func eye(_ cx: CGFloat, mirrored: Bool) -> ShapeSpec {
        let p = CGMutablePath()
        switch self {
        case .round:
            p.addEllipse(in: CGRect(x: cx - 1.05, y: 17 - 1.55, width: 2.1, height: 3.1))
        case .big:
            p.addEllipse(in: CGRect(x: cx - 1.3, y: 17 - 1.85, width: 2.6, height: 3.7))
        case .blink:
            p.addRoundedRect(in: CGRect(x: cx - 1.7, y: 16.55, width: 3.4, height: 0.9), cornerWidth: 0.45, cornerHeight: 0.45)
        case .sleep:
            p.move(to: CGPoint(x: cx - 1.7, y: 16.5))
            p.addQuadCurve(to: CGPoint(x: cx + 1.7, y: 16.5), control: CGPoint(x: cx, y: 18.5))
            return ShapeSpec(p, .stroke(0.9))
        case .happy:
            p.move(to: CGPoint(x: cx - 1.7, y: 17.9))
            p.addQuadCurve(to: CGPoint(x: cx + 1.7, y: 17.9), control: CGPoint(x: cx, y: 15.7))
            return ShapeSpec(p, .stroke(0.9))
        case .think:
            if !mirrored {
                p.addEllipse(in: CGRect(x: 11.05 - 1.05, y: 15.95 - 1.05, width: 2.1, height: 2.1))
            } else {
                p.move(to: CGPoint(x: 15.9, y: 17.55))
                p.addLine(to: CGPoint(x: 19.1, y: 16.45))
                return ShapeSpec(p, .stroke(0.9))
            }
        case .focus:
            // M8.4 15.55 H12.6 V16.45 A2.1 2.05 0 0 1 8.4 16.45 Z：上平下圆的半椭圆
            p.move(to: CGPoint(x: cx - 2.1, y: 15.55))
            p.addLine(to: CGPoint(x: cx + 2.1, y: 15.55))
            p.addLine(to: CGPoint(x: cx + 2.1, y: 16.45))
            p.addArc(center: .zero, radius: 2.1, startAngle: 0, endAngle: .pi, clockwise: false,
                     transform: CGAffineTransform(translationX: cx, y: 16.45).scaledBy(x: 1, y: 2.05 / 2.1))
            p.closeSubpath()
        case .spark:
            p.move(to: CGPoint(x: cx, y: 15))
            p.addQuadCurve(to: CGPoint(x: cx + 2, y: 17), control: CGPoint(x: cx + 0.35, y: 16.65))
            p.addQuadCurve(to: CGPoint(x: cx, y: 19), control: CGPoint(x: cx + 0.35, y: 17.35))
            p.addQuadCurve(to: CGPoint(x: cx - 2, y: 17), control: CGPoint(x: cx - 0.35, y: 17.35))
            p.addQuadCurve(to: CGPoint(x: cx, y: 15), control: CGPoint(x: cx - 0.35, y: 16.65))
            p.closeSubpath()
        case .err:
            // 「>」「<」：尖朝鼻梁
            let s: CGFloat = mirrored ? -1 : 1
            p.move(to: CGPoint(x: cx - 1.05 * s, y: 15.55))
            p.addLine(to: CGPoint(x: cx + 1.05 * s, y: 17))
            p.addLine(to: CGPoint(x: cx - 1.05 * s, y: 18.45))
            return ShapeSpec(p, .stroke(0.85))
        case .dizzy:
            // 半圆接半圆的螺旋，半径 .35 → 1.4；SVG 的 sweep 0 是角度递减，即 CGPath 的 clockwise: true
            p.move(to: CGPoint(x: cx + 0.35, y: 17))
            for (i, r) in [0.35, 0.7, 1.05, 1.4].enumerated() {
                let c = CGPoint(x: cx + (i % 2 == 0 ? 0 : 0.35), y: 17)
                p.addArc(center: c, radius: r, startAngle: i % 2 == 0 ? 0 : .pi, endAngle: i % 2 == 0 ? .pi : 0, clockwise: true)
            }
            return ShapeSpec(p, .stroke(0.55))
        case .danger:
            // 怒眉形的斜块，内端低
            let s: CGFloat = mirrored ? -1 : 1
            p.move(to: CGPoint(x: cx - 1.6 * s, y: 15.45))
            p.addLine(to: CGPoint(x: cx + 1.6 * s, y: 16.95))
            p.addLine(to: CGPoint(x: cx + 1.45 * s, y: 17.95))
            p.addLine(to: CGPoint(x: cx - 1.6 * s, y: 16.55))
            p.closeSubpath()
        }
        return ShapeSpec(p)
    }
}

extension Look {
    /// 右上装饰，按画的先后排。下标是固定的：`Choreography` 按下标点名会动的部件
    public func decoration(_ size: Size) -> [ShapeSpec] {
        let large = size == .large
        switch self {
        case .sleeping:
            let zs = [(20.0, 4.9, 3.0, 2.2), (23.5, 1.4, 4.0, 3.2)] + (large ? [(28.5, -3.6, 5.0, 4.2)] : [])
            return zs.map { x, y, w, h in
                let p = CGMutablePath()
                p.addLines(between: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x, y: y + h), CGPoint(x: x + w, y: y + h)])
                return ShapeSpec(p, .stroke(0.8), RGB(0xB9C3F0))
            }
        case .thinking:
            let cloud = [CGRect(x: 20.5, y: 3, width: 3, height: 3), CGRect(x: 22.5, y: 1.5, width: 4, height: 4),
                         CGRect(x: 25, y: 3, width: 3, height: 3), CGRect(x: 18.5, y: 5.5, width: 2, height: 2)]
                .map { CGPath(ellipseIn: $0, transform: nil) } + [CGPath(rect: CGRect(x: 22, y: 4, width: 4.5, height: 2), transform: nil)]
            let dot = { (x: CGFloat) in CGPath(ellipseIn: CGRect(x: x - 0.55, y: 4.05, width: 1.1, height: 1.1), transform: nil) }
            // 暗点常亮，亮点叠在上面，静止时不透明度 0，由循环依次点亮
            return [ShapeSpec(union(cloud), .fill, RGB(0xE9E2FB), opacity: 0.95),
                    ShapeSpec(union([22.5, 24.5, 26.5].map(dot)), .fill, RGB(0xBFB2EE))]
                + [22.5, 24.5, 26.5].map { ShapeSpec(dot($0), .fill, RGB(0x7C5CE0), opacity: 0) }
        case .question:
            let tail = CGMutablePath()
            tail.addLines(between: [CGPoint(x: 21, y: 5.5), CGPoint(x: 23, y: 5.5), CGPoint(x: 20.5, y: 8)])
            tail.closeSubpath()
            let bubble = ShapeSpec(union([CGPath(roundedRect: CGRect(x: 20, y: 1, width: 7.5, height: 5), cornerWidth: 2, cornerHeight: 2, transform: nil), tail]),
                                   .fill, RGB(0xCFF3F7))
            guard large else { return [bubble] }
            let q = CGMutablePath()
            q.move(to: CGPoint(x: 22.75, y: 2.75))
            q.addQuadCurve(to: CGPoint(x: 23.85, y: 1.85), control: CGPoint(x: 22.9, y: 1.85))
            q.addQuadCurve(to: CGPoint(x: 24.85, y: 2.75), control: CGPoint(x: 24.85, y: 1.85))
            q.addQuadCurve(to: CGPoint(x: 24.1, y: 3.7), control: CGPoint(x: 24.85, y: 3.35))
            q.addQuadCurve(to: CGPoint(x: 23.75, y: 4.35), control: CGPoint(x: 23.75, y: 3.9))
            return [bubble, ShapeSpec(q, .stroke(0.55)),
                    ShapeSpec(CGPath(ellipseIn: CGRect(x: 23.75 - 0.32, y: 5.15 - 0.32, width: 0.64, height: 0.64), transform: nil))]
        case .finished:
            return [ShapeSpec(star(center: CGPoint(x: 24.5, y: 3.5), outer: 2.5, inner: 0.75), .fill, RGB(0xFFD66B)),
                    ShapeSpec(star(center: CGPoint(x: 21, y: 6.5), outer: 1.25, inner: 0.375), .fill, RGB(0xFFD66B), opacity: 0.6)]
        case .error:
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: 22.5, y: 2), CGPoint(x: 26.5, y: 6)])
            p.addLines(between: [CGPoint(x: 26.5, y: 2), CGPoint(x: 22.5, y: 6)])
            return [ShapeSpec(p, .stroke(1.1), RGB(0xFF8A3D))]
        case .mismatch:
            let tri = CGMutablePath()
            tri.addLines(between: [CGPoint(x: 24.5, y: 1.5), CGPoint(x: 28, y: 7.5), CGPoint(x: 21, y: 7.5)])
            tri.closeSubpath()
            let bang = CGMutablePath()
            bang.addRects([CGRect(x: 24, y: 3.5, width: 1, height: 2), CGRect(x: 24, y: 6, width: 1, height: 1)])
            return [ShapeSpec(tri, .fillAndStroke(0.5), RGB(0xFFB020)), ShapeSpec(bang)]
        case .stale:
            let p = CGMutablePath()
            p.addRects([CGRect(x: 22, y: 1.5, width: 5, height: 1), CGRect(x: 22, y: 6.5, width: 5, height: 1)])
            p.addLines(between: [CGPoint(x: 22.5, y: 2.5), CGPoint(x: 26.5, y: 2.5), CGPoint(x: 24.5, y: 4.5)])
            p.closeSubpath()
            p.addLines(between: [CGPoint(x: 24.5, y: 4.5), CGPoint(x: 26.5, y: 6.5), CGPoint(x: 22.5, y: 6.5)])
            p.closeSubpath()
            return [ShapeSpec(p, .fill, RGB(0xB7A27A))]
        case .danger:
            let p = CGMutablePath()
            p.addRects([21.5, 25].flatMap { x in [CGRect(x: x, y: 1.5, width: 1.5, height: 3.5), CGRect(x: x, y: 6, width: 1.5, height: 1.5)] })
            return [ShapeSpec(p, .fill, RGB(0xFF453A))]
        case .idle, .working, .interrupted, .dizzy:
            return []
        }
    }
}

/// 几块同色的形状合成一块：重叠处不会因为半透明叠深，也不会因为绕向相反抠出洞
/// @see https://developer.apple.com/documentation/coregraphics/cgpath/union(_:using:)
private func union(_ paths: [CGPath]) -> CGPath {
    paths.dropFirst().reduce(paths[0]) { $0.union($1) }
}

/// 四角星：外顶点上下左右，内顶点在 45° 方向、两轴各偏 inner（docs/mascot.md §4 的两颗星都是这个形状）
private func star(center c: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: (0..<8).map { i in
        let a = Double(i) * .pi / 4 - .pi / 2
        let r = i % 2 == 0 ? outer : inner * 2.squareRoot()
        return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    })
    p.closeSubpath()
    return p
}
