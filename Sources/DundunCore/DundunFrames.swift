import CoreGraphics

// 盾盾的帧数据：12 个状态、眼形、右上装饰参数、关键帧表、小动作逐帧表、注视格。
// 全部照搬 prototype/dundun-final-spec.md v2.9（sha256 5fdcb32d…96db）第 2–5 节，不插值、不补间。
// 坐标是 28 画布单位：20pt 版 1 单位 = 1pt，40pt 版 1 单位 = 2pt（viewBox -4 -6 40 34）。时间单位是秒。

/// 盾盾的 12 个样子（规格第 2 节的表）
public enum DundunLook: String, CaseIterable, Sendable {
    case idle, sleeping, thinking, working, question, finished, error, interrupted, dizzy, mismatch, stale, danger

    /// 静止时的眼形（2.1）
    public var eyes: EyeKind {
        switch self {
        case .idle: return .round
        case .sleeping: return .sleep
        case .thinking: return .think
        case .working: return .focus
        case .question: return .spark
        case .finished: return .happy
        case .error: return .err
        case .interrupted: return .blink
        case .dizzy: return .dizzy
        case .mismatch, .stale: return .big
        case .danger: return .danger
        }
    }

    /// 第 6 节：只有这 4 个会眨眼（等你回答、mismatch 只在播完后的停留帧上眨）
    public var blinks: Bool { self == .idle || self == .working || self == .question || self == .mismatch }
}

/// 两种画法：20pt（收起态左耳）和 40pt（展开态 / 设置预览，20pt 的放大版）
public enum DundunScale: Sendable { case small, large }

/// 2.1 的 11 种眼形
public enum EyeKind: String, CaseIterable, Sendable {
    case round, big, blink, sleep, happy, err, dizzy, danger, think, focus, spark
}

/// 转身 / 上下翻 / 左右翻的一只眼（第 5 节）：20pt 是 0.5pt 网格上的圆角矩形，40pt 是乘过压缩矩阵的椭圆
public enum FlipEye: Equatable, Sendable {
    /// rx = min(宽, 高) / 2
    case rect(CGRect)
    /// 椭圆 rx 1.05 / ry 1.55 以 (0,0) 为心，乘 matrix(a b c d)，再平移到 center
    case ellipse(center: CGPoint, a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat)
}

public enum DundunEyes: Equatable, Sendable {
    /// 2.1 的眼形，整组平移 (lx, ly)（注视、探头）
    case shape(EyeKind, lx: CGFloat, ly: CGFloat)
    /// 小动作的逐帧眼睛；nil = 这一帧不画这只
    case flip(left: FlipEye?, right: FlipEye?)
}

/// 右上装饰和它在第 3 节里的参数。不跟身体位移、不跟旋转
public enum DundunDeco: Equatable, Sendable {
    case none
    /// 小 z / 中 Z / 40pt 大 Z 的不透明度，nil = 不画
    case sleeping(a: Double?, b: Double?, c: Double?)
    /// 云里第几个点亮，nil = 全暗
    case thinking(lit: Int?)
    /// 气泡缩放，锚点画布 (21, 6.5)
    case question(scale: Double)
    /// 大星 / 小星不透明度（nil 不画）和大星外半径（默认 2.5）
    case finished(big: Double?, small: Double?, bigRadius: Double)
    case error(opacity: Double)
    case mismatch(on: Bool)
    case stale
    case danger(opacity: Double)
}

/// 一整帧：身体、眼睛、装饰在同一个 tick 里一起换（7.7）
public struct DundunFrame: Equatable, Sendable {
    public var look: DundunLook
    /// 身体位移（圆和眼睛一起平移），+y 向下
    public var dx: CGFloat
    public var dy: CGFloat
    /// 只转渐变和眼睛，绕身体圆心；圆本身永远不转（1.1）。单位：度
    public var rotation: Double
    public var eyes: DundunEyes
    public var deco: DundunDeco

    public init(look: DundunLook, dx: CGFloat = 0, dy: CGFloat = 0, rotation: Double = 0, eyes: DundunEyes, deco: DundunDeco) {
        self.look = look
        self.dx = dx
        self.dy = dy
        self.rotation = rotation
        self.eyes = eyes
        self.deco = deco
    }
}

/// 身体圆（1.1）：圆心 (14, 16.5)，r 10，每个状态都一样
public enum DundunGeometry {
    public static let bodyCenter = CGPoint(x: 14, y: 16.5)
    public static let bodyRadius: CGFloat = 10
    /// 20pt 画布 28×28
    public static let smallCanvas = CGSize(width: 28, height: 28)
    /// 40pt 画布 80×68 = viewBox (-4, -6, 40, 34) × 2
    public static let largeViewBox = CGRect(x: -4, y: -6, width: 40, height: 34)
}

// MARK: - 第 3 节：关键帧

struct Key {
    let t: Double
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var rot: Double = 0
    var deco: DundunDeco = .none
}

/// 一个状态的关键帧：period 不为 nil 就循环，否则播一次停在最后一帧
struct Track {
    let keys: [Key]
    let period: Double?

    /// 一次性状态播完、停在最后一帧的时刻；循环状态没有停留帧
    var hold: Double { period == nil ? (keys.last?.t ?? 0) : 0 }

    /// 时间比较的容差：显式时间累加会有 1e-15 量级的误差，落在步进边界上时要算到下一步
    static let eps = 1e-6

    /// 循环状态里 elapsed 所在那一圈的起点（容差内算到下一圈）
    private func cycle(_ elapsed: Double) -> Double {
        guard let period else { return 0 }
        return ((elapsed + Self.eps) / period).rounded(.down) * period
    }

    /// 进入状态 elapsed 秒时的那一步
    func key(at elapsed: Double) -> Key {
        let e = elapsed - cycle(elapsed)
        return keys.last { $0.t <= e + Self.eps } ?? keys[0]
    }

    /// elapsed 之后下一次换步的时刻（相对进入状态）；一次性状态播完后为 nil（7.6：0 重画）
    func nextStep(after elapsed: Double) -> Double? {
        if let period {
            let c = cycle(elapsed)
            if let k = keys.first(where: { $0.t > elapsed - c + Self.eps }) { return c + k.t }
            return c + period
        }
        return keys.first { $0.t > elapsed + Self.eps }?.t
    }
}

enum Tracks {
    static func track(_ look: DundunLook, _ scale: DundunScale) -> Track {
        let large = scale == .large
        switch look {
        case .idle, .stale:
            return Track(keys: [Key(t: 0, deco: look == .stale ? .stale : .none)], period: nil)
        case .sleeping:
            // c 是 40pt 才有的大 Z
            let c: (Double?) -> Double? = { large ? $0 : nil }
            return Track(keys: [
                Key(t: 0, dy: 1, deco: .sleeping(a: 0.5, b: nil, c: nil)),
                Key(t: 0.5, dy: 1, deco: .sleeping(a: 1, b: nil, c: nil)),
                Key(t: 1.0, dy: 1, deco: .sleeping(a: 1, b: 0.6, c: nil)),
                Key(t: 1.5, dy: 1, deco: .sleeping(a: 0.5, b: 1, c: c(0.5))),
                Key(t: 2.0, dy: 1, deco: .sleeping(a: nil, b: 0.5, c: c(1))),
            ], period: 2.5)
        case .thinking:
            let r: Double = large ? 6 : 0   // 40pt 歪头 6°，20pt 不歪
            return Track(keys: [
                Key(t: 0, rot: r, deco: .thinking(lit: 0)),
                Key(t: 0.35, rot: r, deco: .thinking(lit: 1)),
                Key(t: 0.7, rot: r, deco: .thinking(lit: 2)),
                Key(t: 1.05, rot: r, deco: .thinking(lit: nil)),
            ], period: 1.4)
        case .working:
            return Track(keys: [Key(t: 0), Key(t: 0.225, dy: -0.5), Key(t: 0.45, dy: -1), Key(t: 0.675, dy: -0.5)], period: 0.9)
        case .question:
            let r: Double = large ? -8 : 0
            return Track(keys: [Key(t: 0, rot: r, deco: .question(scale: 0.6)), Key(t: 0.1, rot: r, deco: .question(scale: 1))], period: nil)
        case .finished:
            // 打滚：20pt 12 帧 × 50ms、每步 30°；40pt 18 帧 × 33.3ms、每步 20°。然后星星三步
            let (n, step): (Int, Double) = large ? (18, 20) : (12, 30)
            let roll = (0..<n).map { Key(t: 0.6 * Double($0) / Double(n), rot: Double($0) * step) }
            return Track(keys: roll + [
                Key(t: 0.6, deco: .finished(big: 1, small: nil, bigRadius: 1.5)),
                Key(t: 0.85, deco: .finished(big: 1, small: 1, bigRadius: 2.5)),
                Key(t: 1.1, deco: .finished(big: 1, small: 0.6, bigRadius: 2.5)),
            ], period: nil)
        case .error:
            return Track(keys: [Key(t: 0, dy: 1, deco: .error(opacity: 1)), Key(t: 0.2, dy: 0.5, deco: .error(opacity: 1))], period: nil)
        case .interrupted:
            // 顿一下：0.3s 内回原位，平线眼一直停着（眼形就是 blink）
            return Track(keys: [Key(t: 0, dy: 0.5), Key(t: 0.15, dy: 0.2), Key(t: 0.3)], period: nil)
        case .dizzy:
            return Track(keys: [Key(t: 0), Key(t: 0.2, rot: 6), Key(t: 0.4), Key(t: 0.6, rot: -6)], period: 0.8)
        case .mismatch:
            return Track(keys: [0, 0.25, 0.5, 0.75, 1.0].enumerated().map { i, t in Key(t: t, deco: .mismatch(on: i % 2 == 0)) }, period: nil)
        case .danger:
            return Track(keys: [
                Key(t: 0, dx: -1, deco: .danger(opacity: 0.6)),
                Key(t: 0.08, dx: 1, deco: .danger(opacity: 1)),
                Key(t: 0.16, dx: -1, deco: .danger(opacity: 1)),
                Key(t: 0.24, deco: .danger(opacity: 1)),
            ], period: nil)
        }
    }

    /// 减弱动态效果时的静止帧：2.2 的 REST 装饰 + 2.1 的静止眼睛（7.5）。一次性状态用停留帧的位移，40pt 保留静态歪头
    static func rest(_ look: DundunLook, _ scale: DundunScale) -> Key {
        let large = scale == .large
        switch look {
        case .sleeping: return Key(t: 0, dy: 1, deco: .sleeping(a: 1, b: 1, c: large ? 0.6 : nil))
        case .thinking: return Key(t: 0, rot: large ? 6 : 0, deco: .thinking(lit: 1))
        case .question: return Key(t: 0, rot: large ? -8 : 0, deco: .question(scale: 1))
        case .finished: return Key(t: 0, deco: .finished(big: 1, small: 0.6, bigRadius: 2.5))
        case .error: return Key(t: 0, dy: 0.5, deco: .error(opacity: 1))
        case .mismatch: return Key(t: 0, deco: .mismatch(on: true))
        case .stale: return Key(t: 0, deco: .stale)
        case .danger: return Key(t: 0, deco: .danger(opacity: 1))
        case .idle, .working, .interrupted, .dizzy: return Key(t: 0)
        }
    }
}

// MARK: - 第 4.3 / 5 节：小动作

public enum DundunMicro: String, CaseIterable, Sendable {
    case turn, pitch, roll, peek
}

struct MicroStep {
    let t: Double
    let left: FlipEye?
    let right: FlipEye?
}

enum Micros {
    /// 播完（回正）的时刻
    static func end(_ m: DundunMicro) -> Double {
        switch m {
        case .turn: return 0.88
        case .pitch: return 0.5
        case .roll: return 0.4
        case .peek: return 1.2
        }
    }

    private static func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> FlipEye { .rect(CGRect(x: x, y: y, width: w, height: h)) }
    private static func e(_ cx: CGFloat, _ cy: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> FlipEye {
        .ellipse(center: CGPoint(x: cx, y: cy), a: a, b: b, c: c, d: d)
    }

    /// 一次小动作要画几次（含回正那一帧）：转身 / 上下翻 / 左右翻 6，探头 2
    static func stepCount(_ m: DundunMicro, _ scale: DundunScale) -> Int {
        m == .peek ? 2 : steps(m, scale).count + 1
    }

    /// 第 5 节逐帧表（不含回正那一步；回正 = 回到当前注视帧）。peek 不在这里，它是身体位移 + 注视偏移
    static func steps(_ m: DundunMicro, _ scale: DundunScale) -> [MicroStep] {
        switch (m, scale) {
        case (.turn, .small):
            return [MicroStep(t: 0, left: r(16, 15.5, 2, 3), right: r(21.5, 15.5, 1, 3)),
                    MicroStep(t: 0.11, left: r(21, 15.5, 1, 3), right: nil),
                    MicroStep(t: 0.22, left: nil, right: nil),
                    MicroStep(t: 0.66, left: nil, right: r(6, 15.5, 1, 3)),
                    MicroStep(t: 0.77, left: r(5.5, 15.5, 1, 3), right: r(10, 15.5, 2, 3))]
        case (.pitch, .small):
            return [MicroStep(t: 0, left: r(9.5, 19.5, 2, 3), right: r(16.5, 19.5, 2, 3)),
                    MicroStep(t: 0.1, left: r(9.5, 22.5, 2, 2), right: r(16.5, 22.5, 2, 2)),
                    MicroStep(t: 0.2, left: nil, right: nil),
                    MicroStep(t: 0.3, left: r(9.5, 9, 2, 2), right: r(16.5, 9, 2, 2)),
                    MicroStep(t: 0.4, left: r(9.5, 11.5, 2, 3), right: r(16.5, 11.5, 2, 3))]
        case (.roll, .small):
            // 规格（sha256 5fdcb32d…96db）新加的 20pt 真翻滚表（Haitao 10-28：20pt 也真翻滚）
            return [MicroStep(t: 0, left: r(7, 13.5, 2, 2), right: r(13.5, 12.5, 2, 3)),
                    MicroStep(t: 0.08, left: nil, right: r(9.5, 9, 2, 2)),
                    MicroStep(t: 0.16, left: nil, right: nil),
                    MicroStep(t: 0.24, left: r(16, 22.5, 2, 2), right: nil),
                    MicroStep(t: 0.32, left: r(12.5, 18.5, 2, 3), right: r(19, 18.5, 2, 2))]
        case (.turn, .large):
            return [MicroStep(t: 0, left: e(17, 17, 0.9514, -0.0081, -0.0081, 0.9986), right: e(22, 17, 0.3526, -0.0408, -0.0408, 0.9974)),
                    MicroStep(t: 0.11, left: e(21.75, 17, 0.4025, -0.0386, -0.0386, 0.9975), right: nil),
                    MicroStep(t: 0.22, left: nil, right: nil),
                    MicroStep(t: 0.66, left: nil, right: e(6.25, 17, 0.4025, 0.0386, 0.0386, 0.9975)),
                    MicroStep(t: 0.77, left: e(6, 17, 0.3526, 0.0408, 0.0408, 0.9974), right: e(11, 17, 0.9514, 0.0081, 0.0081, 0.9986))]
        case (.pitch, .large):
            return [MicroStep(t: 0, left: e(10.5, 20.75, 0.9003, 0.1224, 0.1224, 0.8497), right: e(17.5, 20.75, 0.9003, -0.1224, -0.1224, 0.8497)),
                    MicroStep(t: 0.1, left: e(10.5, 23.5, 0.8785, 0.2412, 0.2412, 0.5215), right: e(17.5, 23.5, 0.8785, -0.2412, -0.2412, 0.5215)),
                    MicroStep(t: 0.2, left: nil, right: nil),
                    MicroStep(t: 0.3, left: e(10.5, 10, 0.8861, -0.2097, -0.2097, 0.6139), right: e(17.5, 10, 0.8861, 0.2097, 0.2097, 0.6139)),
                    MicroStep(t: 0.4, left: e(10.5, 13, 0.8980, -0.1000, -0.1000, 0.9020), right: e(17.5, 13, 0.8980, 0.1000, 0.1000, 0.9020))]
        case (.roll, .large):
            return [MicroStep(t: 0, left: e(8, 14.5, 0.6857, -0.1059, -0.1059, 0.9643), right: e(14.5, 14, 0.9981, 0.0096, 0.0096, 0.9519)),
                    MicroStep(t: 0.08, left: nil, right: e(10.75, 10.25, 0.9040, -0.1844, -0.1844, 0.6460)),
                    MicroStep(t: 0.16, left: nil, right: nil),
                    MicroStep(t: 0.24, left: e(17, 23.5, 0.9252, -0.1784, -0.1784, 0.5748), right: nil),
                    MicroStep(t: 0.32, left: e(13.5, 20, 0.9974, 0.0161, 0.0161, 0.9026), right: e(20, 19.5, 0.6792, -0.1594, -0.1594, 0.9208))]
        case (.peek, _):
            return []
        }
    }
}

// MARK: - 4.1 / 4.2：注视

public enum GazeCell: String, CaseIterable, Sendable {
    case c, l, r, ld, rd

    /// 20pt 偏移，也是 40pt 东张西望用的对应格（4.2）
    var offset: CGPoint {
        switch self {
        case .c: return .zero
        case .l: return CGPoint(x: -1, y: 0)
        case .r: return CGPoint(x: 1, y: 0)
        case .ld: return CGPoint(x: -1, y: 0.5)
        case .rd: return CGPoint(x: 1, y: 0.5)
        }
    }

    var weight: Double { self == .c ? 4 : 1.5 }
}

public enum Gaze {
    /// 鼠标相对身体圆心的屏幕位移（pt，+x 向右，+y 向下）量化成眼睛偏移（画布单位）
    public static func quantize(_ v: CGPoint, scale: DundunScale) -> CGPoint {
        let r = (v.x * v.x + v.y * v.y).squareRoot()
        switch scale {
        case .small:
            guard r >= 12 else { return .zero }
            let ux = v.x / r, uy = v.y / r
            guard abs(ux) > 0.38 else { return .zero }
            return CGPoint(x: ux < 0 ? -1 : 1, y: uy > 0.45 ? 0.5 : 0)
        case .large:
            guard r >= 36 else { return .zero }
            let ux = v.x / r, uy = v.y / r
            return CGPoint(x: max(-1, min(1, (ux * 2).rounded() / 2)), y: uy > 0.4 ? 0.5 : 0)
        }
    }
}
