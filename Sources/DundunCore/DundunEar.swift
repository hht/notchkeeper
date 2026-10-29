import CoreGraphics

// 右耳指示（规格 2.3）和它的切换过渡（3A.2「右耳指示」「危险右耳脉冲环」）。

public enum EarShape: String, Equatable, Sendable {
    /// 三颗蓝点：直径 3，间距 2，总宽 13，静态（思考、工作）
    case dots
    /// 7pt 圆点
    case dot
}

public enum EarIndicator: Equatable, Sendable {
    case none
    case dots
    case question
    case error
    case mismatch
    case danger

    public var shape: EarShape? {
        switch self {
        case .none: return nil
        case .dots: return .dots
        case .question, .error, .mismatch, .danger: return .dot
        }
    }

    public var color: RGB {
        switch self {
        case .none, .dots: return RGB(hex: 0x3B9EFF)
        case .question: return RGB(hex: 0x3CC8DC)
        case .error: return RGB(hex: 0xFF8A3D)
        case .mismatch: return RGB(hex: 0xFFB020)
        case .danger: return RGB(hex: 0xFF453A)
        }
    }

    /// 2.3：出错的橙点回到空闲后继续亮着（未读，最多 30 分钟，由 App 计时）；其它状态不显示
    public static func `for`(_ look: DundunLook, errorUnread: Bool) -> EarIndicator {
        switch look {
        case .thinking, .working: return .dots
        case .question: return .question
        case .error: return .error
        case .mismatch: return .mismatch
        case .danger: return .danger
        case .idle: return errorUnread ? .error : .none
        case .sleeping, .finished, .interrupted, .dizzy, .stale: return .none
        }
    }
}

/// 危险红点外的脉冲环：半径和不透明度，描边 1
public struct EarRing: Equatable, Sendable {
    public var radius: CGFloat
    public var opacity: Double
}

public struct EarLayer: Equatable, Sendable {
    public var shape: EarShape
    public var color: RGB
    public var opacity: Double
    public var ring: EarRing?
}

public struct EarRender: Equatable, Sendable {
    public var layers: [EarLayer]
    public init(layers: [EarLayer]) { self.layers = layers }
}

/// 2.3 阶梯脉冲：1.2s 一圈，0 / .15 / .3 / .45s 四步
public enum EarPulse {
    public static let period = 1.2
    static let steps: [(t: Double, ring: EarRing?)] = [
        (0, EarRing(radius: 4.5, opacity: 0.5)),
        (0.15, EarRing(radius: 5.5, opacity: 0.32)),
        (0.3, EarRing(radius: 6.5, opacity: 0.16)),
        (0.45, nil),
    ]
    /// 减弱动态效果：静止环 r 6、35%
    public static let still = EarRing(radius: 6, opacity: 0.35)

    /// 和左耳 `Track` 同一个容差：落在步进边界上算下一步，保证 next 严格往后走
    static let eps = 1e-6

    private static func cycle(_ elapsed: Double) -> Double {
        ((max(0, elapsed) + eps) / period).rounded(.down) * period
    }

    public static func ring(at elapsed: Double) -> EarRing? {
        let e = max(0, elapsed) - cycle(elapsed)
        return steps.last { $0.t <= e + eps }?.ring
    }

    public static func next(after elapsed: Double) -> Double {
        let c = cycle(elapsed)
        if let s = steps.first(where: { $0.t > max(0, elapsed) - c + eps }) { return c + s.t }
        return c + period
    }
}

/// 右耳调度器：显式时间驱动，和左耳的 `DundunPlayer` 同一套思路
public struct DundunEarPlayer: Sendable {
    public private(set) var indicator: EarIndicator = .none
    /// 进入当前指示（过渡结束）的时刻，脉冲从这里起算
    private var since: Double = 0
    private var from: EarRender?
    private var transitionStart: Double = 0
    private var duration: Double = 0.2
    private var colorOnly = false
    public private(set) var reduceMotion = false
    public private(set) var visible = true

    public init() {}

    public var inTransition: Bool { from != nil }
    /// 正在过渡时，过渡结束的时刻
    public var transitionEnd: Double? { from == nil ? nil : transitionStart + duration }

    public mutating func set(_ new: EarIndicator, at t: Double) {
        guard new != indicator else { return }
        let snapshot = render(at: t)
        indicator = new
        if visible {
            from = snapshot
            transitionStart = t
            duration = reduceMotion ? 0.15 : 0.2
            colorOnly = reduceMotion
            since = t + duration
        } else {
            from = nil
            since = t
        }
    }

    public mutating func setReduceMotion(_ on: Bool, at t: Double) {
        reduceMotion = on
    }

    public mutating func setVisible(_ on: Bool, at t: Double) {
        visible = on
        if !on { from = nil }
    }

    private func steady(at t: Double) -> EarRender {
        guard let shape = indicator.shape else { return EarRender(layers: []) }
        var ring: EarRing?
        if indicator == .danger { ring = reduceMotion ? EarPulse.still : EarPulse.ring(at: t - since) }
        return EarRender(layers: [EarLayer(shape: shape, color: indicator.color, opacity: 1, ring: ring)])
    }

    public func render(at t: Double) -> EarRender {
        let target = steady(at: max(t, since))
        guard let from, t < transitionStart + duration else { return target }
        let u = (t - transitionStart) / duration
        let p = Curve.easeInOut(u)
        let want = target.layers.first
        var out: [EarLayer] = []
        for l in from.layers where l.shape != want?.shape {
            // 出去：1 → 0；离开危险时脉冲环停在当前帧跟着淡出
            if colorOnly { continue }
            out.append(EarLayer(shape: l.shape, color: l.color, opacity: l.opacity * (1 - p), ring: l.ring))
        }
        if var want {
            if let same = from.layers.first(where: { $0.shape == want.shape }) {
                want.color = OKLab.mix(same.color, want.color, p)
                want.opacity = colorOnly ? 1 : same.opacity + (1 - same.opacity) * p
                // 进入危险时等过渡结束再开始脉冲
                if want.ring != nil && !reduceMotion { want.ring = same.ring }
            } else {
                want.opacity = colorOnly ? 1 : p
                if !reduceMotion { want.ring = nil }
            }
            out.append(want)
        }
        return EarRender(layers: out)
    }

    /// 下一次需要重画的时刻；nil = 静态，不调度
    public func nextRedraw(after t: Double) -> Double? {
        guard visible else { return nil }
        if from != nil, let n = Frames60.next(after: t, start: transitionStart, end: transitionStart + duration) { return n }
        if indicator == .danger && !reduceMotion {
            if t < since { return since }
            return since + EarPulse.next(after: t - since)
        }
        return nil
    }

    /// 时间推进：过渡结束后丢掉快照
    public mutating func advance(to t: Double) {
        if from != nil, t >= transitionStart + duration { from = nil }
    }
}
