import CoreGraphics
import Foundation

// 渲染器画的那一份「解析后的帧」：颜色、眼睛几何、身体位移 / 倾斜、装饰（带不透明度和缩放）。
// 步进帧和过渡帧都落到这个类型上，过渡中途再切状态时也从它开始（规格 3A.4「以当前插值结果为起点」）。

// MARK: - 颜色和 OKLab（3A.2）

/// sRGB，0…1
public struct RGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }
}

/// OKLab 插值（Björn Ottosson 的矩阵）。p = 0 / 1 时原样返回端点，免得浮点往返让「帧没变」判断失效
public enum OKLab {
    public static func mix(_ a: RGB, _ b: RGB, _ p: Double) -> RGB {
        if p <= 0 { return a }
        if p >= 1 { return b }
        let la = lab(a), lb = lab(b)
        return rgb((la.0 + (lb.0 - la.0) * p, la.1 + (lb.1 - la.1) * p, la.2 + (lb.2 - la.2) * p))
    }

    static func lab(_ c: RGB) -> (Double, Double, Double) {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func rgb(_ lab: (Double, Double, Double)) -> RGB {
        let l = pow(lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2, 3)
        let m = pow(lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2, 3)
        let s = pow(lab.0 - 0.0894841775 * lab.1 - 1.2914855480 * lab.2, 3)
        func enc(_ v: Double) -> Double {
            let c = max(0, min(1, v))
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return RGB(r: enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                   g: enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                   b: enc(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }
}

/// 身体渐变上端、下端（第 2 节表）
public struct BodyColors: Equatable, Sendable {
    public var top: RGB
    public var bottom: RGB

    static func mix(_ a: BodyColors, _ b: BodyColors, _ p: Double) -> BodyColors {
        BodyColors(top: OKLab.mix(a.top, b.top, p), bottom: OKLab.mix(a.bottom, b.bottom, p))
    }
}

extension DundunLook {
    /// 第 2 节表，原样
    public var colors: BodyColors {
        let (t, b): (UInt32, UInt32)
        switch self {
        case .idle, .sleeping, .interrupted: (t, b) = (0xF2EEE6, 0xCFCAC0)
        case .thinking: (t, b) = (0xE9E2FB, 0xBFB2EE)
        case .working: (t, b) = (0xDCEBFF, 0x9CC6F5)
        case .question: (t, b) = (0xD8F4F7, 0x8FD9E2)
        case .finished: (t, b) = (0xE3F6EE, 0xAEDCC7)
        case .error: (t, b) = (0xFBE6D6, 0xEDB892)
        case .dizzy: (t, b) = (0xFBE3EC, 0xEBB3C7)
        case .mismatch: (t, b) = (0xFBEFC9, 0xE8CD84)
        case .stale: (t, b) = (0xEFE9DD, 0xCFC2A6)
        case .danger: (t, b) = (0xFFB8B0, 0xF2645A)
        }
        return BodyColors(top: RGB(hex: t), bottom: RGB(hex: b))
    }
}

// MARK: - 缓动曲线（3A.1）

public enum Curve: Sendable {
    /// cubic-bezier(0.42, 0, 0.58, 1)
    case easeInOut
    /// cubic-bezier(0, 0, 0.58, 1)
    case easeOut
    /// cubic-bezier(0.42, 0, 1, 1)
    case easeIn
    case linear

    public func callAsFunction(_ u: Double) -> Double {
        let x = max(0, min(1, u))
        switch self {
        case .linear: return x
        case .easeInOut: return Self.bezier(0.42, 0, 0.58, 1, x)
        case .easeOut: return Self.bezier(0, 0, 0.58, 1, x)
        case .easeIn: return Self.bezier(0.42, 0, 1, 1, x)
        }
    }

    /// CSS cubic-bezier：先按 x 二分出参数 s，再求 y
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func f(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if f(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return f((lo + hi) / 2, y1, y2)
    }
}

// MARK: - 眼睛几何（2.1，按 3A.3 的相容类建模）

/// 一只眼的几何。相容类里的眼形用参数化几何（可以插值），其它眼形交给 App 里的 SVG 原样路径
public enum EyeGeom: Equatable, Sendable {
    /// A 类 20pt：圆角矩形，rx = min(宽, 高) / 2
    case pill(CGRect)
    /// A 类 40pt：椭圆
    case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat)
    /// C 类：4 顶点实心多边形（blink 的 rect 展开成 4 角）。radius 只在正好是轴对齐矩形时用（40pt 平线眼 rx .45）
    case quad(CGPoint, CGPoint, CGPoint, CGPoint, radius: CGFloat)
    /// B 类 20pt：4 点折线，线宽 1，圆头圆角
    case polyline(CGPoint, CGPoint, CGPoint, CGPoint)
    /// B 类 40pt：Q 曲线，线宽 .9，圆头
    case curve(CGPoint, control: CGPoint, CGPoint)
    /// 不相容眼形（think / focus / spark / err / dizzy）：App 按 2.1 的 SVG 原样画
    case art(EyeKind, right: Bool)
    /// 小动作逐帧眼（第 5 节）
    case flip(FlipEye)

    /// 2.1 的静止眼
    public static func of(_ kind: EyeKind, _ scale: DundunScale, right: Bool) -> EyeGeom {
        let dx: CGFloat = right ? 7 : 0
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y) }
        // 右眼是左眼镜像（绕 x = 14）的眼形：danger
        func m(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: right ? 28 - x : x, y: y) }
        switch (kind, scale) {
        case (.round, .small): return .pill(CGRect(x: 9.5 + dx, y: 15.5, width: 2, height: 3))
        case (.round, .large): return .ellipse(center: p(10.5, 17), rx: 1.05, ry: 1.55)
        case (.big, .small): return .pill(CGRect(x: 9 + dx, y: 15, width: 3, height: 4))
        case (.big, .large): return .ellipse(center: p(10.5, 17), rx: 1.3, ry: 1.85)
        case (.blink, .small):
            // rect x 9 y 16.5 3×1，左上、右上、右下、左下；右眼按镜像顺序排，和 danger 右眼逐点对应
            return .quad(m(9, 16.5), m(12, 16.5), m(12, 17.5), m(9, 17.5), radius: 0)
        case (.blink, .large):
            return .quad(m(8.8, 16.55), m(12.2, 16.55), m(12.2, 17.45), m(8.8, 17.45), radius: 0.45)
        case (.danger, .small):
            return .quad(m(9, 15.5), m(12, 17), m(12, 18), m(9, 16.5), radius: 0)
        case (.danger, .large):
            return .quad(m(8.9, 15.45), m(12.1, 16.95), m(11.95, 17.95), m(8.9, 16.55), radius: 0)
        case (.sleep, .small): return .polyline(p(9, 16.5), p(10, 17.5), p(11, 17.5), p(12, 16.5))
        case (.happy, .small): return .polyline(p(9, 18), p(10, 16.5), p(11, 16.5), p(12, 18))
        case (.sleep, .large): return .curve(p(8.8, 16.5), control: p(10.5, 18.5), p(12.2, 16.5))
        case (.happy, .large): return .curve(p(8.8, 17.9), control: p(10.5, 15.7), p(12.2, 17.9))
        case (.err, _), (.dizzy, _), (.think, _), (.focus, _), (.spark, _): return .art(kind, right: right)
        }
    }

    /// 同一相容类、同一种几何之间插值（3A.3「插」）。20pt 量化到 0.5pt 网格（3A.2）。几何种类不同返回 nil
    static func lerp(_ a: EyeGeom, _ b: EyeGeom, _ p: Double, _ scale: DundunScale) -> EyeGeom? {
        if p <= 0 { return a }
        if p >= 1 { return b }
        let q: (CGFloat) -> CGFloat = { v in scale == .small ? (v * 2).rounded() / 2 : v }
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { q(x + (y - x) * CGFloat(p)) }
        func lp(_ x: CGPoint, _ y: CGPoint) -> CGPoint { CGPoint(x: l(x.x, y.x), y: l(x.y, y.y)) }
        switch (a, b) {
        case let (.pill(r0), .pill(r1)):
            return .pill(CGRect(x: l(r0.minX, r1.minX), y: l(r0.minY, r1.minY), width: l(r0.width, r1.width), height: l(r0.height, r1.height)))
        case let (.ellipse(c0, x0, y0), .ellipse(c1, x1, y1)):
            return .ellipse(center: lp(c0, c1), rx: l(x0, x1), ry: l(y0, y1))
        case let (.quad(a0, b0, c0, d0, r0), .quad(a1, b1, c1, d1, r1)):
            return .quad(lp(a0, a1), lp(b0, b1), lp(c0, c1), lp(d0, d1), radius: r0 + (r1 - r0) * CGFloat(p))
        case let (.polyline(a0, b0, c0, d0), .polyline(a1, b1, c1, d1)):
            return .polyline(lp(a0, a1), lp(b0, b1), lp(c0, c1), lp(d0, d1))
        case let (.curve(a0, k0, b0), .curve(a1, k1, b1)):
            return .curve(lp(a0, a1), control: lp(k0, k1), lp(b0, b1))
        default:
            return a == b ? a : nil
        }
    }
}

/// 画出来的一只眼：几何 + 整组平移（注视 / 探头）+ 压扁程度（过渡眨眼：0 = 原样，1 = 压成 1pt 横线）
public struct EyeDraw: Equatable, Sendable {
    public var geom: EyeGeom
    public var offset: CGPoint
    public var close: Double

    public init(geom: EyeGeom, offset: CGPoint = .zero, close: Double = 0) {
        self.geom = geom
        self.offset = offset
        self.close = close
    }
}

/// 一个装饰和它在过渡里的不透明度 / 缩放（3A.2：缩放绕装饰自己的中心）
public struct DecoDraw: Equatable, Sendable {
    public var deco: DundunDeco
    public var opacity: Double
    public var scale: Double

    public init(deco: DundunDeco, opacity: Double = 1, scale: Double = 1) {
        self.deco = deco
        self.opacity = opacity
        self.scale = scale
    }
}

extension DundunDeco {
    /// 3A.2「同一个装饰（同一 id）就不动」：按装饰种类比，参数（哪颗点亮、不透明度）不算
    public var id: String {
        switch self {
        case .none: return "none"
        case .sleeping: return "sleeping"
        case .thinking: return "thinking"
        case .question: return "question"
        case .finished: return "finished"
        case .error: return "error"
        case .mismatch: return "mismatch"
        case .stale: return "stale"
        case .danger: return "danger"
        }
    }
}

/// 渲染器要的一整帧
public struct DundunRender: Equatable, Sendable {
    public var look: DundunLook
    public var colors: BodyColors
    public var dx: CGFloat
    public var dy: CGFloat
    /// 只转渐变和眼睛（度），圆不转
    public var rotation: Double
    /// 眼形的语义标签，给 3A.3 选过渡类型用
    public var eyeKind: EyeKind
    public var left: EyeDraw?
    public var right: EyeDraw?
    public var decos: [DecoDraw]
    /// 正处在过渡眨眼的闭眼阶段（3A.4：这时被打断就直接从横线展开）
    public var closing: Bool

    /// 步进帧 → 渲染帧
    public init(_ f: DundunFrame, scale: DundunScale) {
        look = f.look
        colors = f.look.colors
        dx = f.dx
        dy = f.dy
        rotation = f.rotation
        closing = false
        decos = f.deco == .none ? [] : [DecoDraw(deco: f.deco)]
        switch f.eyes {
        case let .shape(kind, lx, ly):
            eyeKind = kind
            let o = CGPoint(x: lx, y: ly)
            left = EyeDraw(geom: .of(kind, scale, right: false), offset: o)
            right = EyeDraw(geom: .of(kind, scale, right: true), offset: o)
        case let .flip(l, r):
            eyeKind = f.look.eyes
            left = l.map { EyeDraw(geom: .flip($0)) }
            right = r.map { EyeDraw(geom: .flip($0)) }
        }
    }
}
