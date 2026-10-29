import CoreGraphics

// 盾盾的身体和装饰：画布坐标里的 CGPath 和画法。不知道这些形状怎么动。
// 坐标、路径全部照 docs/mascot.md §1、§4，单位是画布单位，原点左上、+y 向下。

/// 身体各部位在画布上的位置
public enum Anatomy {
    public static let bodyCenter = CGPoint(x: 14, y: 16.5)
    public static let bodyRadius: CGFloat = 10
    public static let leftEye = CGPoint(x: 10.5, y: 17)
    public static let rightEye = CGPoint(x: 17.5, y: 17)
    /// 右上装饰区的中心，整组装饰弹出时以它为锚点
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
    /// 静止时的不透明度；循环的不透明度动画叠加在它上面
    public let opacity: Double

    public init(_ path: CGPath, _ paint: Paint = .fill, _ color: RGB = .ink, opacity: Double = 1) {
        self.path = path
        self.paint = paint
        self.color = color
        self.opacity = opacity
    }
}

/// 装饰里能单独动的一块，带自己的锚点（缩放、旋转的中心）
public struct DecoPart: Equatable, Sendable {
    public let spec: ShapeSpec
    public let anchor: CGPoint

    public init(spec: ShapeSpec, anchor: CGPoint) {
        self.spec = spec
        self.anchor = anchor
    }
}

extension Look {
    /// 右上装饰，按画的先后排。下标是固定的：`Choreography` 按下标点名会动的部件
    public func decoration(_ size: Size) -> [DecoPart] {
        func at(_ anchor: CGPoint, _ specs: [ShapeSpec]) -> [DecoPart] { specs.map { DecoPart(spec: $0, anchor: anchor) } }
        switch self {
        case .sleeping:
            let zs = [(20.0, 4.9, 3.0, 2.2, CGPoint(x: 21.5, y: 6)), (23.5, 1.4, 4.0, 3.2, CGPoint(x: 25.5, y: 3))]
                + (size == .large ? [(28.5, -3.6, 5.0, 4.2, CGPoint(x: 31, y: -1.5))] : [])
            return zs.map { x, y, w, h, anchor in
                let p = CGMutablePath()
                p.addLines(between: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x, y: y + h), CGPoint(x: x + w, y: y + h)])
                return DecoPart(spec: ShapeSpec(p, .stroke(0.8), RGB(0xB9C3F0)), anchor: anchor)
            }
        case .thinking:
            let cloud = [CGRect(x: 20.5, y: 3, width: 3, height: 3), CGRect(x: 22.5, y: 1.5, width: 4, height: 4),
                         CGRect(x: 25, y: 3, width: 3, height: 3), CGRect(x: 18.5, y: 5.5, width: 2, height: 2)]
                .map { CGPath(ellipseIn: $0, transform: nil) } + [CGPath(rect: CGRect(x: 22, y: 4, width: 4.5, height: 2), transform: nil)]
            let dot = { (x: CGFloat) in CGPath(ellipseIn: CGRect(x: x - 0.55, y: 4.05, width: 1.1, height: 1.1), transform: nil) }
            // 暗点常亮，亮点叠在上面，静止时不透明度 0，由循环依次点亮
            return at(Anatomy.decoCenter, [ShapeSpec(union(cloud), .fill, RGB(0xE9E2FB), opacity: 0.95),
                                           ShapeSpec(union([22.5, 24.5, 26.5].map(dot)), .fill, RGB(0xBFB2EE))]
                + [22.5, 24.5, 26.5].map { ShapeSpec(dot($0), .fill, RGB(0x7C5CE0), opacity: 0) })
        case .question:
            let tail = CGMutablePath()
            tail.addLines(between: [CGPoint(x: 21, y: 5.5), CGPoint(x: 23, y: 5.5), CGPoint(x: 20.5, y: 8)])
            tail.closeSubpath()
            let bubble = ShapeSpec(union([CGPath(roundedRect: CGRect(x: 20, y: 1, width: 7.5, height: 5), cornerWidth: 2, cornerHeight: 2, transform: nil), tail]),
                                   .fill, RGB(0xCFF3F7))
            let anchor = CGPoint(x: 23.8, y: 3.6)
            guard size == .large else { return at(anchor, [bubble]) }
            let q = CGMutablePath()
            q.move(to: CGPoint(x: 22.75, y: 2.75))
            q.addQuadCurve(to: CGPoint(x: 23.85, y: 1.85), control: CGPoint(x: 22.9, y: 1.85))
            q.addQuadCurve(to: CGPoint(x: 24.85, y: 2.75), control: CGPoint(x: 24.85, y: 1.85))
            q.addQuadCurve(to: CGPoint(x: 24.1, y: 3.7), control: CGPoint(x: 24.85, y: 3.35))
            q.addQuadCurve(to: CGPoint(x: 23.75, y: 4.35), control: CGPoint(x: 23.75, y: 3.9))
            return at(anchor, [bubble, ShapeSpec(q, .stroke(0.55)),
                               ShapeSpec(CGPath(ellipseIn: CGRect(x: 23.75 - 0.32, y: 5.15 - 0.32, width: 0.64, height: 0.64), transform: nil))])
        case .finished:
            return [DecoPart(spec: ShapeSpec(star(center: CGPoint(x: 24.5, y: 3.5), outer: 2.5, inner: 0.75), .fill, RGB(0xFFD66B)),
                             anchor: CGPoint(x: 24.5, y: 3.5)),
                    DecoPart(spec: ShapeSpec(star(center: CGPoint(x: 21, y: 6.5), outer: 1.25, inner: 0.375), .fill, RGB(0xFFD66B), opacity: 0.6),
                             anchor: CGPoint(x: 21, y: 6.5))]
        case .longTurn:
            // 汗珠
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 23.2, y: 2.8))
            p.addQuadCurve(to: CGPoint(x: 24.3, y: 5.4), control: CGPoint(x: 24.2, y: 4.2))
            p.addArc(center: CGPoint(x: 23.2, y: 5.6), radius: 1.1, startAngle: -0.18, endAngle: .pi + 0.18, clockwise: false)
            p.addQuadCurve(to: CGPoint(x: 23.2, y: 2.8), control: CGPoint(x: 22.2, y: 4.2))
            return at(Anatomy.decoCenter, [ShapeSpec(p, .fill, RGB(0x7CC4F5))])
        case .approval:
            // 举起的手：手掌 + 四指 + 拇指
            var parts = [CGPath(roundedRect: CGRect(x: 21.8, y: 4.2, width: 4.6, height: 3.8), cornerWidth: 1.3, cornerHeight: 1.3, transform: nil)]
            for (x, top) in [(21.9, 1.9), (23.05, 1.1), (24.2, 1.3), (25.35, 2.1)] {
                parts.append(CGPath(roundedRect: CGRect(x: x, y: top, width: 0.95, height: 5 - top), cornerWidth: 0.47, cornerHeight: 0.47, transform: nil))
            }
            var t = CGAffineTransform(translationX: 21.9, y: 6.6).rotated(by: -0.6).translatedBy(x: -21.9, y: -6.6)
            parts.append(CGPath(roundedRect: CGRect(x: 20.6, y: 4.6, width: 0.95, height: 2.6), cornerWidth: 0.47, cornerHeight: 0.47, transform: &t))
            return at(CGPoint(x: 24, y: 8), [ShapeSpec(union(parts), .fill, RGB(0xD9EE8C))])
        case .error:
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: 22.5, y: 2), CGPoint(x: 26.5, y: 6)])
            p.addLines(between: [CGPoint(x: 26.5, y: 2), CGPoint(x: 22.5, y: 6)])
            return at(CGPoint(x: 24.5, y: 4), [ShapeSpec(p, .stroke(1.1), RGB(0xFF8A3D))])
        case .offline:
            // Wi-Fi 扇形 + 斜杠
            let c = CGPoint(x: 24.5, y: 7.6)
            func arc(_ r: CGFloat) -> CGPath {
                let p = CGMutablePath()
                p.addArc(center: c, radius: r, startAngle: -3 * .pi / 4, endAngle: -.pi / 4, clockwise: false)
                return p
            }
            let slash = CGMutablePath()
            slash.addLines(between: [CGPoint(x: 21, y: 1.4), CGPoint(x: 28, y: 8.2)])
            return at(CGPoint(x: 24.5, y: 5), [ShapeSpec(CGPath(ellipseIn: CGRect(x: c.x - 0.65, y: c.y - 1.05, width: 1.3, height: 1.3), transform: nil), .fill, .grey),
                                               ShapeSpec(arc(2.4), .stroke(0.85), .grey), ShapeSpec(arc(4.2), .stroke(0.85), .grey),
                                               ShapeSpec(slash, .stroke(0.85), RGB(0xC7C7CC))])
        case .mismatch:
            let tri = CGMutablePath()
            tri.addLines(between: [CGPoint(x: 24.5, y: 1.5), CGPoint(x: 28, y: 7.5), CGPoint(x: 21, y: 7.5)])
            tri.closeSubpath()
            let bang = CGMutablePath()
            bang.addRects([CGRect(x: 24, y: 3.5, width: 1, height: 2), CGRect(x: 24, y: 6, width: 1, height: 1)])
            return at(CGPoint(x: 24.5, y: 4.5), [ShapeSpec(tri, .fillAndStroke(0.5), .amber), ShapeSpec(bang)])
        case .stale:
            let p = CGMutablePath()
            p.addRects([CGRect(x: 22, y: 1.5, width: 5, height: 1), CGRect(x: 22, y: 6.5, width: 5, height: 1)])
            p.addLines(between: [CGPoint(x: 22.5, y: 2.5), CGPoint(x: 26.5, y: 2.5), CGPoint(x: 24.5, y: 4.5)])
            p.closeSubpath()
            p.addLines(between: [CGPoint(x: 24.5, y: 4.5), CGPoint(x: 26.5, y: 6.5), CGPoint(x: 22.5, y: 6.5)])
            p.closeSubpath()
            return at(CGPoint(x: 24.5, y: 4.5), [ShapeSpec(p, .fill, RGB(0xB7A27A))])
        case .danger:
            // 两个 ! 是两个部件，轮流跳
            return [21.5, 25].map { x in
                let p = CGMutablePath()
                p.addRects([CGRect(x: x, y: 1.5, width: 1.5, height: 3.5), CGRect(x: x, y: 6, width: 1.5, height: 1.5)])
                return DecoPart(spec: ShapeSpec(p, .fill, .red), anchor: CGPoint(x: x + 0.75, y: 4.5))
            }
        case .shielded:
            // 锁：锁梁、锁身、锁孔
            let shackle = CGMutablePath()
            shackle.move(to: CGPoint(x: 22.8, y: 4.4))
            shackle.addLine(to: CGPoint(x: 22.8, y: 3.0))
            shackle.addArc(center: CGPoint(x: 24.5, y: 3.0), radius: 1.7, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            shackle.addLine(to: CGPoint(x: 26.2, y: 4.4))
            let hole = CGMutablePath()
            hole.addEllipse(in: CGRect(x: 24.5 - 0.55, y: 5.5, width: 1.1, height: 1.1))
            hole.addRect(CGRect(x: 24.2, y: 6.0, width: 0.6, height: 1.3))
            return at(CGPoint(x: 24.5, y: 5), [ShapeSpec(shackle, .stroke(0.9), RGB(0xFF8A80)),
                                               ShapeSpec(CGPath(roundedRect: CGRect(x: 21.5, y: 4.2, width: 6, height: 4.3), cornerWidth: 1, cornerHeight: 1, transform: nil), .fill, .red),
                                               ShapeSpec(hole)])
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
