import CoreGraphics

/// 盾盾此刻做什么动作：给一个造型或动作，输出要提交给 Core Animation 的声明式 `[Track]`。
/// 不知道图层怎么搭、动画怎么提交（App），也不知道什么时候该做（`IdleDirector`、App）。
/// 所有 Track 都叠加（additive）在图层的静止值上：values 是相对静止值的偏移，所以朝向、注视、呼吸、动作可以同时生效。
/// 实测（macOS 26，2026-10-29）：同一键路径的两个 additive 动画相加。
/// 数字出自 docs/mascot.md §5。
/// @see https://developer.apple.com/documentation/quartzcore/capropertyanimation/isadditive
public enum Choreography {
    /// 停在某个造型时一直循环的动作：身体呼吸、头的小动作、装饰的节奏
    public static func loop(_ look: Look, size: Size, reduceMotion: Bool) -> [Track] {
        let tracks = breath(look) + head(look) + deco(look, count: look.decoration(size).count)
        return reduceMotion ? tracks.filter(\.isStill) : tracks
    }

    /// 刚换到某个造型时播一次的动作
    public static func entrance(_ look: Look, reduceMotion: Bool) -> [Track] {
        let tracks: [Track]
        switch look {
        case .finished: tracks = Motion.finishJump.tracks
        case .working: tracks = Motion.nod.tracks
        case .danger:
            // 横向抖三下、逐次衰减
            tracks = [.keys(.stage, .translationX, [(0, 0), (0.075, 1.2), (0.15, -1), (0.225, 0.7), (0.3, -0.4), (0.45, 0)])]
        default: tracks = []
        }
        return reduceMotion ? tracks.filter(\.isStill) : tracks
    }

    public static func tracks(for motion: Motion, reduceMotion: Bool) -> [Track] {
        reduceMotion ? motion.tracks.filter(\.isStill) : motion.tracks
    }

    /// 换造型时各部分怎么补间
    public static func change(reduceMotion: Bool) -> LookChange {
        if reduceMotion {
            return LookChange(eyeMorph: 0.15, colorFade: 0.15, pose: nil, decoExit: 0.15, decoExitScale: nil,
                              decoEnterDelay: 0, decoPop: nil, decoFadeIn: 0.15, loopDelay: 0)
        }
        return LookChange(eyeMorph: 0.38, colorFade: 0.4, pose: .spring(response: 0.5, damping: 0.75),
                          decoExit: 0.18, decoExitScale: 0.4, decoEnterDelay: 0.1, decoPop: .spring(response: 0.38, damping: 0.6),
                          decoFadeIn: 0.16, loopDelay: 0.4)
    }

    /// 右耳三蓝点依次亮：静止不透明度 `earDotRest`，亮到 1，周期 1.2s，相邻错开 0.2s
    public static func earDots(reduceMotion: Bool) -> [Track] {
        (0..<3).map { i in
            .keys(.earDot(i), .opacity, [(0, 0), (0.25, 1 - earDotRest), (0.5, 0), (1.2, 0)], phase: 1.2 - 0.2 * Double(i), repeats: true)
        }
    }

    public static let earDotRest = 0.35

    /// 眨眼：眼形补间成一条线再回来（`Eyes.shut`）；连眨时第二下隔 0.25s
    public static let blinkClose = 0.06
    public static let blinkOpen = 0.14
    public static let secondBlinkAfter = 0.25

    /// 静止值从 old 换成 new（注视、探头）：App 先把图层的静止值设成 new，再叠一条从 old − new 回到 0 的动画。
    /// 叠加动画可以层层叠：上一段还没走完就换目标，画面也是连贯的
    /// @see https://developer.apple.com/videos/play/wwdc2014/236/
    public static func retarget(_ part: Part, _ property: Property, from old: Double, to new: Double, _ how: Retarget) -> Track {
        switch how {
        case .spring(let response, let damping): return .spring(part, property, from: old - new, .spring(response: response, damping: damping))
        case .sine(let duration): return .keys(part, property, [(0, old - new), (duration, 0)])
        }
    }

    /// 跟随鼠标的弹簧
    public static let followSpring = Retarget.spring(response: 0.3, damping: 0.85)
    /// 鼠标停下多久后回正，以及回正用多久
    public static let gazeRestAfter = 4.0
    public static let gazeReturn = Retarget.sine(duration: 0.8)
    /// 鼠标到刘海上「探头」：身体放大、眼睛放大，弹簧；眼形 0.25s 补间到放大的样子
    public static let peekScale = 1.06
    public static let peekEyes = 1.1
    public static let peekSpring = Retarget.spring(response: 0.35, damping: 0.6)
    public static let peekEyeMorph = 0.25

    private static let deg = Double.pi / 180

    /// 呼吸：以身体底部为锚点，scaleY +0.03、scaleX −0.01，4.6s；睡着 6s、+0.045
    private static func breath(_ look: Look) -> [Track] {
        let (period, rise) = look == .sleeping ? (6.0, 0.045) : (4.6, 0.03)
        return [.keys(.body, .scaleY, [(0, 0), (period / 2, rise), (period, 0)], repeats: true),
                .keys(.body, .scaleX, [(0, 0), (period / 2, -0.01), (period, 0)], repeats: true)]
    }

    private static func head(_ look: Look) -> [Track] {
        func d(_ keys: [(Double, Double)]) -> [(Double, Double)] { keys.map { ($0.0, $0.1 * deg) } }
        switch look {
        case .sleeping:
            return [.keys(.pitch, .rotationX, d([(0, 0), (3, -4), (6, 0)]), repeats: true)]
        case .thinking:
            // 慢慢左右琢磨
            return [.keys(.yaw, .rotationY, d([(0, 0), (1.8, -8), (3.6, 0)]), repeats: true)]
        case .working:
            // 像在读一行行字：慢慢扫过去，快速回到行首
            return [.keys(.yaw, .rotationY, d([(0, -7), (0.9, 7), (1.15, -7), (1.4, -7)]), phase: 0.45, repeats: true)]
        case .longTurn:
            return [.keys(.yaw, .rotationY, d([(0, -7), (0.6, 7), (0.8, -7), (1.0, -7)]), phase: 0.3, repeats: true)]
        case .dizzy:
            return [.keys(.roll, .rotationZ, d([(0, 0), (0.6, 6), (1.2, 0), (1.8, -6), (2.4, 0)]), repeats: true)]
        case .offline:
            // 头左右找信号
            return [.keys(.yaw, .rotationY, d([(0, 0), (0.5, -25), (1.2, -25), (1.8, 25), (2.5, 25), (3.0, 0), (3.6, 0)]), repeats: true)]
        default:
            return []
        }
    }

    /// 装饰的节奏。不透明度都写成相对静止值（`ShapeSpec.opacity`）的叠加量
    private static func deco(_ look: Look, count n: Int) -> [Track] {
        let parts = (0..<n).map(Part.decoPart)
        switch look {
        case .sleeping:
            // 三个 Z 依次冒出、上浮、放大、淡出，每秒一个，像一串呼噜
            return parts.enumerated().flatMap { i, z in
                let ph = Double((3 - i) % 3)
                return [Track.keys(z, .translationY, [(0, 0), (3, -2)], timing: .easeOut, phase: ph, repeats: true),
                        .keys(z, .translationX, [(0, 0), (1.5, 0.5), (3, 0)], phase: ph, repeats: true),
                        .keys(z, .scale, [(0, -0.4), (0.6, 0), (3, 0.15)], phase: ph, repeats: true),
                        .keys(z, .opacity, [(0, -1), (0.4, 0), (2.2, 0), (3, -1)], phase: ph, repeats: true)]
            }
        case .thinking:
            // 整朵云轻轻浮；三个亮点（静止不透明度 0）依次亮
            return parts.map { .keys($0, .translationY, [(0, 0), (1.2, -0.5), (2.4, 0)], repeats: true) }
                + (0..<3).map { i in .keys(parts[2 + i], .opacity, [(0, 0), (0.2, 1), (0.4, 0), (1.2, 0)], phase: 1.2 - 0.2 * Double(i), repeats: true) }
        case .question:
            // 气泡和 ? 上下浮；? 每 2s 晃一下
            return parts.map { .keys($0, .translationY, [(0, 0), (1, -0.6), (2, 0)], repeats: true) }
                + parts.dropFirst().map { .keys($0, .rotationZ, [(0, 0), (0.12, 0.2), (0.24, -0.2), (0.36, 0.1), (0.48, 0), (2, 0)], repeats: true) }
        case .finished:
            // 大星慢转一闪；小星（静止 0.6）和它错拍
            return [.keys(parts[0], .rotationZ, [(0, 0), (2.4, .pi / 2)], timing: .linear, repeats: true),
                    .keys(parts[0], .scale, [(0, 0), (0.6, 0.18), (1.2, 0), (2.4, 0)], repeats: true),
                    .keys(parts[1], .opacity, [(0, 0), (0.6, 0.4), (1.2, -0.35), (2.4, 0)], phase: 1.2, repeats: true)]
        case .longTurn:
            // 汗珠滑下来、淡出
            return [.keys(parts[0], .translationY, [(0, 0), (1.6, 1.6), (2.0, 1.6)], timing: .easeIn, repeats: true),
                    .keys(parts[0], .opacity, [(0, -1), (0.2, 0), (1.3, 0), (1.6, -1), (2.0, -1)], repeats: true)]
        case .approval:
            // 招手两下，停一会儿
            return [.keys(parts[0], .rotationZ, [(0, 0), (0.2, 0.3), (0.4, -0.15), (0.6, 0.3), (0.8, 0), (2.4, 0)], repeats: true)]
        case .error:
            return [.keys(parts[0], .rotationZ, [(0, 0), (0.08, 0.2), (0.16, -0.2), (0.24, 0.1), (0.32, 0), (2.6, 0)], repeats: true)]
        case .offline:
            // 信号从里到外依次亮起又暗下去，斜杠不动
            return (0..<3).map { i in .keys(parts[i], .opacity, [(0, -0.75), (0.3, 0), (0.9, -0.75), (2.4, -0.75)], phase: 2.4 - 0.3 * Double(i), repeats: true) }
        case .mismatch:
            return parts.map { .keys($0, .scale, [(0, 0), (0.2, 0.12), (0.4, 0), (0.6, 0.12), (0.8, 0), (2.6, 0)], repeats: true) }
        case .stale:
            // 沙漏停一会儿、翻过来，再停、再翻
            return [.keys(parts[0], .rotationZ, [(0, 0), (1.2, 0), (1.7, .pi), (2.9, .pi), (3.4, 2 * .pi)], repeats: true)]
        case .danger:
            // 两个 ! 轮流跳，像警报
            return parts.enumerated().map { i, p in
                .keys(p, .translationY, [(0, 0), (0.12, -0.9), (0.24, 0), (0.9, 0)], phase: 0.9 - 0.24 * Double(i), repeats: true)
            }
        case .shielded:
            // 每 3s 锁「咔哒」一下：锁梁往下扣，锁身微缩
            return [.keys(parts[0], .translationY, [(0, 0), (0.12, 0.5), (0.3, 0), (3, 0)], repeats: true)]
                + parts.dropFirst().map { .keys($0, .scale, [(0, 0), (0.12, -0.06), (0.3, 0), (3, 0)], repeats: true) }
        case .idle, .working, .interrupted, .dizzy:
            return []
        }
    }
}

/// 静止值换了以后怎么过去
public enum Retarget: Equatable, Sendable {
    case spring(response: Double, damping: Double)
    /// 正弦缓动，给定时长
    case sine(duration: Double)
}

/// 换造型时各部分的补间（docs/mascot.md §5「换造型」）。起点都从呈现层取
public struct LookChange: Equatable, Sendable {
    /// 眼形逐点变形的时长，正弦
    public let eyeMorph: Double
    /// 渐变颜色过渡的时长，正弦
    public let colorFade: Double
    /// 头转到新朝向的弹簧；nil = 直接设值
    public let pose: Timing?
    /// 旧装饰淡出的时长（ease-in），以及同时缩到多小；nil = 只淡出
    public let decoExit: Double
    public let decoExitScale: Double?
    /// 新装饰延迟多久出来；从 0.4 弹到 1 的弹簧（nil = 只淡入）；淡入时长
    public let decoEnterDelay: Double
    public let decoPop: Timing?
    public let decoFadeIn: Double
    /// 新造型的循环延迟多久起播
    public let loopDelay: Double
}

/// 叠在造型朝向和跟随鼠标之上的一段动作（docs/mascot.md §5「动作」）
public enum Motion: CaseIterable, Sendable {
    case spinAround, flip, lookAround, nod, tilt, shake, lookUp, lookDown, sideways, curious, finishJump

    /// 关键帧：时刻 s、yaw°、pitch°、roll°、dy（画布单位，负 = 向上）
    var keys: [(Double, Double, Double, Double, Double)] {
        switch self {
        case .spinAround: return [(0, 0, 0, 0, 0), (0.9, 360, 0, 0, 0)]
        case .flip: return [(0, 0, 0, 0, 0), (0.9, 0, 360, 0, 0)]
        case .lookAround: return [(0, 0, 0, 0, 0), (0.4, -35, 0, 0, 0), (0.9, -35, 0, 0, 0), (1.5, 35, 0, 0, 0), (2.0, 35, 0, 0, 0), (2.4, 0, 0, 0, 0)]
        case .nod: return [(0, 0, 0, 0, 0), (0.18, 0, -18, 0, 0), (0.38, 0, 0, 0, 0), (0.55, 0, -10, 0, 0), (0.75, 0, 0, 0, 0)]
        case .tilt: return [(0, 0, 0, 0, 0), (0.35, 0, 0, 14, 0), (1.4, 0, 0, 14, 0), (1.7, 0, 0, 0, 0)]
        case .shake: return [(0, 0, 0, 0, 0), (0.15, -22, 0, 0, 0), (0.35, 22, 0, 0, 0), (0.52, -14, 0, 0, 0), (0.66, 8, 0, 0, 0), (0.78, 0, 0, 0, 0)]
        case .lookUp: return [(0, 0, 0, 0, 0), (0.45, 0, 35, 0, 0), (1.5, 0, 35, 0, 0), (1.9, 0, 0, 0, 0)]
        case .lookDown: return [(0, 0, 0, 0, 0), (0.45, 0, -35, 0, 0), (1.5, 0, -35, 0, 0), (1.9, 0, 0, 0, 0)]
        case .sideways: return [(0, 0, 0, 0, 0), (0.5, 90, 0, 0, 0), (1.3, 90, 0, 0, 0), (1.7, 0, 0, 0, 0)]
        case .curious: return [(0, 0, 0, 0, 0), (0.4, 30, 12, -10, 0), (1.4, 30, 12, -10, 0), (1.8, 0, 0, 0, 0)]
        case .finishJump: return [(0, 0, 0, 0, 0), (0.12, 0, 0, 0, 1), (0.4, 180, 0, 0, -4), (0.67, 360, 0, 0, 0), (0.8, 360, 0, 0, 0)]
        }
    }

    /// 每个有动的分量一条，关键帧之间正弦
    var tracks: [Track] {
        let d = Double.pi / 180
        let channels: [(Part, Property, ((Double, Double, Double, Double, Double)) -> Double)] = [
            (.yaw, .rotationY, { $0.1 * d }), (.pitch, .rotationX, { $0.2 * d }), (.roll, .rotationZ, { $0.3 * d }), (.stage, .translationY, { $0.4 }),
        ]
        return channels.compactMap { part, property, value in
            let values = keys.map(value)
            guard values.contains(where: { $0 != 0 }) else { return nil }
            return .keys(part, property, Array(zip(keys.map(\.0), values)))
        }
    }
}

/// 动画作用在哪一层。图层树由 App 搭（docs/mascot.md §1）：stage ⊃ body ⊃ … ⊃ pose ⊃ yaw ⊃ pitch ⊃ roll ⊃ 两只眼；stage ⊃ 装饰
public enum Part: Hashable, Sendable {
    /// 整只盾盾：抖、跳
    case stage
    /// 身体，锚点在身体底部：呼吸
    case body
    /// 头的三层朝向，叠在造型的静止朝向（pose）之上：跟随鼠标、动作、头的小动作
    case yaw, pitch, roll
    /// 装饰里的第几块（下标见 `Look.decoration`），绕自己的锚点
    case decoPart(Int)
    /// 右耳三蓝点的第几颗
    case earDot(Int)
}

/// 动画的属性。旋转单位弧度，位移单位画布单位；App 换成 Core Animation 的键路径
public enum Property: Sendable {
    case translationX, translationY, scaleX, scaleY, scale, rotationX, rotationY, rotationZ, opacity
}

public enum Timing: Equatable, Sendable {
    /// 三次贝塞尔的两个控制点
    case bezier(Double, Double, Double, Double)
    /// response 是感知时长（秒），damping 是阻尼比。换成 CASpringAnimation：mass 1，
    /// stiffness = (2π / response)²，damping = 4π · damping / response（docs/mascot.md §5「缓动」）
    case spring(response: Double, damping: Double)

    public static let linear = bezier(0, 0, 1, 1)
    /// 同 kCAMediaTimingFunctionEaseIn / EaseOut
    public static let easeIn = bezier(0.42, 0, 1, 1)
    public static let easeOut = bezier(0, 0, 0.58, 1)
    /// 正弦缓动 @see https://easings.net/#easeInOutSine
    public static let sineInOut = bezier(0.37, 0, 0.63, 1)

    /// 时间进度 x（0…1）对应的值进度：解三次贝塞尔 x(s) = x，再取 y(s)。二分 40 次，误差远小于一个像素
    /// @see https://developer.apple.com/documentation/quartzcore/camediatimingfunction
    func progress(_ x: Double) -> Double {
        guard case .bezier(let x1, let y1, let x2, let y2) = self else { preconditionFailure("弹簧没有解析解") }
        func bez(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bez(mid, x1, x2) < x { lo = mid } else { hi = mid }
        }
        return bez((lo + hi) / 2, y1, y2)
    }
}

/// 一条动画：某一层的某个属性在 duration 里依次经过 values（叠加在静止值上）。
/// 弹簧只有一段：values = [起点偏移, 0]，duration 是感知时长（response），真正播多久由 Core Animation 按弹簧参数算
public struct Track: Equatable, Sendable {
    public var part: Part
    public var property: Property
    public var values: [Double]
    /// 0…1，和 values 一一对应
    public var keyTimes: [Double]
    /// 每段一个，比 values 少一个
    public var timings: [Timing]
    public var duration: Double
    /// 循环从一圈里的哪一刻起播（秒，0 ≤ phase < duration）：错开几个部件的节拍
    public var phase: Double = 0
    public var repeats = false

    /// 减弱动态效果时还能留下的：位移、缩放、旋转都算动，只剩不透明度
    var isStill: Bool { property == .opacity }

    /// 起播后 elapsed 秒时叠加了多少（循环按圈折回）。撤循环时 App 用它只把循环自己的那一份补间收尾，
    /// 不碰同一层上还在跑的注视、探头弹簧
    public func value(at elapsed: Double) -> Double {
        guard case .bezier = timings.first else { preconditionFailure("弹簧没有解析解：\(self)") }
        let t = repeats ? (phase + elapsed).truncatingRemainder(dividingBy: duration) : min(elapsed, duration)
        let u = t / duration
        guard let i = keyTimes.indices.dropFirst().first(where: { keyTimes[$0] >= u }) else { return values[values.count - 1] }
        let span = keyTimes[i] - keyTimes[i - 1]
        let k = span > 0 ? (u - keyTimes[i - 1]) / span : 1
        return values[i - 1] + (values[i] - values[i - 1]) * timings[i - 1].progress(k)
    }

    /// keys 是（秒，值），第一个时刻必须是 0，最后一个时刻就是时长
    static func keys(_ part: Part, _ property: Property, _ keys: [(Double, Double)], timing: Timing = .sineInOut,
                     phase: Double = 0, repeats: Bool = false) -> Track {
        guard let end = keys.last?.0, end > 0, keys.first?.0 == 0 else { preconditionFailure("关键帧要从 0 开始、时长为正：\(keys)") }
        return Track(part: part, property: property, values: keys.map(\.1), keyTimes: keys.map { $0.0 / end },
                     timings: Array(repeating: timing, count: keys.count - 1), duration: end,
                     phase: phase.truncatingRemainder(dividingBy: end), repeats: repeats)
    }

    static func spring(_ part: Part, _ property: Property, from: Double, _ timing: Timing) -> Track {
        guard case .spring(let response, _) = timing else { preconditionFailure("不是弹簧：\(timing)") }
        return Track(part: part, property: property, values: [from, 0], keyTimes: [0, 1], timings: [timing], duration: response)
    }
}
