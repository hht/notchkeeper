import CoreGraphics

/// 盾盾此刻做什么动作：给一个造型或提示，输出要提交给 Core Animation 的声明式 `[Track]`。
/// 不知道图层怎么搭、动画怎么提交（App 的 DundunLayerView），也不知道什么时候该做（`IdleDirector`、App）。
/// 所有 Track 都叠加（additive）在图层的静止值上：values 是相对静止值的偏移，所以姿态、注视、呼吸、小动作可以同时生效。
/// 实测（macOS 26，2026-10-29）：additive 的 transform.scale.x 偏移 0.5 叠在静止值 2 上得 2.5；同一键路径的两个 additive 动画相加。
/// 数字出自 docs/dundun.md §5。
/// @see https://developer.apple.com/documentation/quartzcore/capropertyanimation/isadditive
public enum Choreography {
    /// 停在某个造型时一直循环的动作
    public static func loop(_ look: Look, size: Size, reduceMotion: Bool) -> [Track] {
        let tracks: [Track]
        switch look {
        case .idle:
            tracks = breath(halfPeriod: 2.3, rise: 0.03)
        case .sleeping:
            tracks = breath(halfPeriod: 3, rise: 0.045) + (0..<look.decoration(size).count).flatMap { i in
                // 三个 Z 每隔 0.6s 依次出现，1.8s 里上浮 1.5 单位并淡出；3s 一圈。
                // 时刻按 0.1s 的整数倍算：浮点相加（0.8 + 0.4）会超出一圈的长度
                let s = { (tenths: Int) in Double(6 * i + tenths) / 10 }
                return [Track.keys(.decoPart(i), .translationY, [(0, 0), (s(0), 0), (s(18), -1.5), (3, 0)], repeats: true),
                        Track.keys(.decoPart(i), .opacity, [(0, -1), (s(0), -1), (s(4), 0), (s(10), 0), (s(18), -1), (3, -1)], repeats: true)]
            }
        case .working:
            tracks = [.swing(.body, .translationY, to: -1, halfPeriod: 0.55)]
        case .thinking:
            // 云里三个亮点依次亮，1.2s 一圈（亮点静止不透明度 0，见 `Look.decoration`）
            tracks = (0..<3).map { i in
                let a = { (tenths: Int) in Double(4 * i + tenths) / 10 }
                return .keys(.decoPart(2 + i), .opacity, [(0, 0), (a(0), 0), (a(2), 1), (a(4), 0), (1.2, 0)], repeats: true)
            }
        case .question:
            tracks = [.swing(.deco, .translationY, to: -1, halfPeriod: 1)]
        case .dizzy:
            let swing = 6 * Double.pi / 180
            tracks = [.keys(.turn, .rotation, [(0, 0), (0.3, swing), (0.9, -swing), (1.2, 0)], repeats: true)]
                + [Part.leftEye, .rightEye].map { .keys($0, .rotation, [(0, 0), (1.2, 2 * .pi)], timing: .linear, repeats: true) }
        case .finished, .error, .interrupted, .mismatch, .stale, .danger:
            tracks = []
        }
        return reduceMotion ? tracks.filter(\.isStill) : tracks
    }

    /// 刚换到某个造型时播一次的动作。姿态（歪头、一缩）不在这里，App 用 `poseSpring` 过渡过去
    public static func entrance(_ look: Look, reduceMotion: Bool) -> [Track] {
        let tracks: [Track]
        switch look {
        case .finished:
            // 压扁 90ms → 起跳 4 单位，空中转 360°（0.55s，ease-out）→ 落地压扁回弹 → 星星弹出
            tracks = [
                .keys(.body, .scaleY, [(0, 0), (0.09, -0.1), (0.2, 0.05), (0.64, 0), (0.72, -0.08), (0.9, 0)]),
                .keys(.body, .scaleX, [(0, 0), (0.09, 0.05), (0.2, -0.03), (0.64, 0), (0.72, 0.05), (0.9, 0)]),
                .keys(.body, .translationY, [(0, 0), (0.09, 0), (0.36, -4), (0.64, 0)], timings: [.linear, .sineOut, .sineIn]),
                .keys(.turn, .rotation, [(0, 0), (0.09, 0), (0.64, 2 * .pi)], timings: [.linear, .easeOut]),
            ] + pop(delay: 0.7)
        case .working:
            // 进场点一下头
            tracks = [.keys(.body, .translationY, [(0, 0), (0.15, 0.8), (0.4, 0)]),
                      .keys(.gaze, .translationY, [(0, 0), (0.15, 0.4), (0.4, 0)])]
        case .mismatch:
            // ▲ 弹出，柔和闪两下后静止
            tracks = pop(delay: 0) + [.keys(.deco, .opacity, [(0, 0), (0.15, -0.7), (0.3, 0), (0.45, -0.7), (0.6, 0)], delay: 0.45)]
        case .danger:
            // 横向抖三下、逐次衰减，0.45s
            let x: [Double] = [0, 1.2, -1.2, 0.8, -0.8, 0.4, 0]
            tracks = [.keys(.body, .translationX, x.enumerated().map { (Double($0.offset) * 0.075, $0.element) })] + pop(delay: 0)
        case .interrupted:
            tracks = [.keys(.body, .translationY, [(0, 0), (0.12, 1.2), (0.3, 0)], timings: [.sineOut, .sineInOut])]
        case .stale:
            tracks = [.keys(.deco, .opacity, [(0, -1), (0.3, 0)])]
        case .thinking, .question, .error, .sleeping:
            tracks = pop(delay: 0)
        case .idle, .dizzy:
            tracks = []
        }
        return reduceMotion ? tracks.filter(\.isStill) : tracks
    }

    /// 空闲小动作和眨眼
    public static func tracks(for cue: Cue, reduceMotion: Bool) -> [Track] {
        let deg = Double.pi / 180
        let tracks: [Track]
        switch cue {
        case .blink(let twice):
            // scaleY 1 → 0.1 → 1：闭眼 60ms（ease-in），睁眼 90ms（ease-out）；连眨隔 0.1s
            let one = Track.keys(.lids, .scaleY, [(0, 0), (0.06, -0.9), (0.15, 0)], timings: [.easeIn, .easeOut])
            var again = one
            again.delay = 0.25
            tracks = twice ? [one, again] : [one]
        case .idle(.lookAround):
            tracks = [.keys(.gaze, .translationX, [(0, 0), (0.25, -1.2), (0.75, -1.2), (1, 1.2), (1.5, 1.2), (1.8, 0)]),
                      .keys(.turn, .rotation, [(0, 0), (0.25, -2 * deg), (0.75, -2 * deg), (1, 2 * deg), (1.5, 2 * deg), (1.8, 0)])]
        case .idle(.curiousTilt):
            tracks = [.keys(.turn, .rotation, [(0, 0), (0.3, 10 * deg), (1.1, 10 * deg), (1.5, 0)], timings: [.sineOut, .linear, .sineInOut]),
                      .keys(.gaze, .translationY, [(0, 0), (0.3, -0.5), (1.1, -0.5), (1.5, 0)])]
        case .idle(.peekSide):
            tracks = [.keys(.body, .translationX, [(0, 0), (0.35, 1.5), (1.2, 1.5), (1.6, 0)]),
                      .keys(.turn, .rotation, [(0, 0), (0.35, 7 * deg), (1.2, 7 * deg), (1.6, 0)])]
        case .idle(.hop):
            // 先压 0.92 → 跳 2 单位 → 落地再压；身体图层锚点在底部，压扁时脚不离地
            let t = [0, 0.12, 0.32, 0.5, 0.58, 0.7]
            tracks = [.keys(.body, .translationY, Array(zip(t, [0, 0, -2, 0, 0, 0])), timings: [.linear, .sineOut, .sineIn, .linear, .sineInOut]),
                      .keys(.body, .scaleY, Array(zip(t, [0, -0.08, 0.04, 0, -0.06, 0]))),
                      .keys(.body, .scaleX, Array(zip(t, [0, 0.04, -0.02, 0, 0.03, 0])))]
        case .idle(.shake):
            // 挤压拉伸三次，逐次衰减
            let s: [Double] = [0, 0.06, -0.05, 0.04, -0.025, 0.012, 0]
            let t = s.indices.map { Double($0) * 0.1 }
            tracks = [.keys(.body, .scaleX, Array(zip(t, s))), .keys(.body, .scaleY, Array(zip(t, s.map { -$0 })))]
        case .idle(.spin):
            tracks = [.keys(.turn, .rotation, [(0, 0), (0.9, 2 * .pi)])]
        }
        return reduceMotion ? tracks.filter(\.isStill) : tracks
    }

    /// 换造型：渐变颜色交叉淡化；眼形「眨眼换形」（压成线 → 在 swapAt 换形 → 睁开）；旧装饰淡出、新装饰按 `entrance` 出场。
    /// 减弱动态效果时眼睛改成淡出淡入，全部 0.15s
    public static func change(reduceMotion: Bool) -> LookChange {
        if reduceMotion {
            return LookChange(tracks: [.keys(.lids, .opacity, [(0, 0), (0.075, -1), (0.15, 0)])], swapAt: 0.075, colorFade: 0.15, decoFadeOut: 0.15)
        }
        return LookChange(tracks: [.keys(.lids, .scaleY, [(0, 0), (0.09, -0.9), (0.18, 0)], timings: [.sineIn, .sineOut])],
                          swapAt: 0.09, colorFade: 0.3, decoFadeOut: 0.12)
    }

    /// 右耳危险红点外圈：1.6s 一圈，从红点边上柔和地扩到两倍并淡出。减弱动态效果时是静止环（`EarRing.still`）
    public static func earPulse(reduceMotion: Bool) -> [Track] {
        guard !reduceMotion else { return [] }
        return [.keys(.ring, .scale, [(0, 0), (1.4, 1), (1.6, 0)], timings: [.sineOut, .linear], repeats: true),
                .keys(.ring, .opacity, [(0, -EarRing.pulse.opacity), (0.2, 0), (1.4, -EarRing.pulse.opacity), (1.6, -EarRing.pulse.opacity)],
                      timings: [.sineOut, .sineIn, .linear], repeats: true)]
    }

    /// 静止值从 old 换成 new（姿态、注视、探头）：App 先把图层的静止值设成 new，再叠一条从 old − new 回到 0 的动画。
    /// 叠加动画可以层层叠：上一段还没走完就换目标，画面也是连贯的
    /// @see https://developer.apple.com/videos/play/wwdc2014/236/
    public static func retarget(_ part: Part, _ property: Property, from old: Double, to new: Double, _ timing: Timing, duration: Double = 0) -> Track {
        if case .spring = timing { return .spring(part, property, from: old - new, timing) }
        return .keys(part, property, [(0, old - new), (duration, 0)], timing: timing)
    }

    /// 姿态（歪头、一缩、变淡）换过去用的弹簧
    public static let poseSpring = Timing.spring(response: 0.4, damping: 0.7)
    /// 跟随鼠标：眼睛和倾角的弹簧
    public static let followSpring = Timing.spring(response: 0.3, damping: 0.85)
    /// 鼠标停下多久后眼睛回正，以及回正用多久
    public static let gazeRestAfter = 4.0
    public static let gazeReturn = 0.8
    /// 鼠标到刘海上「探头」：身体放大、眼睛放大，弹簧
    public static let peekScale = 1.06
    public static let peekEyes = 1.1
    public static let peekSpring = Timing.spring(response: 0.35, damping: 0.6)

    private static func breath(halfPeriod: Double, rise: Double) -> [Track] {
        [.swing(.body, .scaleY, to: rise, halfPeriod: halfPeriod), .swing(.body, .scaleX, to: -0.01, halfPeriod: halfPeriod)]
    }

    /// 装饰从 0 弹出
    private static func pop(delay: Double) -> [Track] {
        [Track.spring(.deco, .scale, from: -1, Timing.spring(response: 0.35, damping: 0.6), delay: delay),
         .keys(.deco, .opacity, [(0, -1), (0.12, 0)], timing: .sineOut, delay: delay)]
    }
}

public struct LookChange: Equatable, Sendable {
    public let tracks: [Track]
    /// 眼形在这一刻换（眼睛压成线或者淡到看不见的时候）
    public let swapAt: Double
    /// 渐变颜色交叉淡化的时长
    public let colorFade: Double
    /// 旧装饰淡出的时长
    public let decoFadeOut: Double
}

/// 右耳危险脉冲环的静止值：环画在红点边上（半径 3.5pt、1pt 描边）
public enum EarRing {
    public static let pulse = (radius: 3.5, opacity: 0.6)
    /// 减弱动态效果时的静止环（不动画）
    public static let still = (radius: 6.0, opacity: 0.35)
}

/// 动画作用在哪一层。图层树由 App 搭，层级从外到内：body ⊃ turn ⊃ gaze ⊃ lids ⊃ leftEye / rightEye；deco 和 body 平级
public enum Part: Hashable, Sendable {
    /// 整个身体，锚点在身体底部：跳、浮、缩、呼吸
    case body
    /// 渐变和脸，绕身体圆心转：歪头、转圈、摆锤（身体圆本身不转，docs/dundun.md §1）
    case turn
    /// 两只眼睛整体：东张西望、跟随鼠标、探头放大
    case gaze
    /// 眼皮，以眼睛横线为轴：只做眨眼和换眼形
    case lids
    /// 单只眼，绕自己的中心：螺旋眼转
    case leftEye, rightEye
    /// 整个右上装饰，锚点在装饰区中心：弹出、浮动、闪
    case deco
    /// 装饰里的第几块（下标见 `Look.decoration`）
    case decoPart(Int)
    /// 右耳红点外圈
    case ring
}

/// Core Animation 的键路径。旋转单位弧度，位移单位画布单位
public enum Property: String, Sendable {
    case translationX = "transform.translation.x"
    case translationY = "transform.translation.y"
    case scaleX = "transform.scale.x"
    case scaleY = "transform.scale.y"
    case scale = "transform.scale"
    case rotation = "transform.rotation.z"
    case opacity

    /// 位移、缩放、旋转都算动，减弱动态效果时不做
    public var isMovement: Bool { self != .opacity }
}

public enum Timing: Equatable, Sendable {
    /// 三次贝塞尔的两个控制点
    case bezier(Double, Double, Double, Double)
    /// response 是周期（秒），damping 是阻尼比，含义同 SwiftUI 的 spring(response:dampingFraction:)
    case spring(response: Double, damping: Double)

    public static let linear = bezier(0, 0, 1, 1)
    /// 同 kCAMediaTimingFunctionEaseIn / EaseOut
    public static let easeIn = bezier(0.42, 0, 1, 1)
    public static let easeOut = bezier(0, 0, 0.58, 1)
    /// 正弦缓动 @see https://easings.net/#easeInOutSine
    public static let sineInOut = bezier(0.37, 0, 0.63, 1)
    public static let sineIn = bezier(0.12, 0, 0.39, 0)
    public static let sineOut = bezier(0.61, 1, 0.88, 1)
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
    public var delay: Double = 0
    public var repeats = false
    public var autoreverses = false

    /// 减弱动态效果时还能留下的：不动的属性，以及眨眼
    var isStill: Bool { !property.isMovement || part == .lids }

    /// keys 是（秒，值），第一个时刻必须是 0，最后一个时刻就是时长
    static func keys(_ part: Part, _ property: Property, _ keys: [(Double, Double)], timing: Timing = .sineInOut,
                     timings: [Timing]? = nil, delay: Double = 0, repeats: Bool = false) -> Track {
        // 相邻的相同关键帧（比如起点就在 0 的那一段）只留一个
        let keys = keys.enumerated().filter { $0.offset == 0 || keys[$0.offset - 1] != $0.element }.map(\.element)
        guard let end = keys.last?.0, end > 0, keys.first?.0 == 0 else { preconditionFailure("关键帧要从 0 开始、时长为正：\(keys)") }
        let ts = timings ?? Array(repeating: timing, count: keys.count - 1)
        precondition(ts.count == keys.count - 1, "每段一个缓动")
        return Track(part: part, property: property, values: keys.map(\.1), keyTimes: keys.map { $0.0 / end },
                     timings: ts, duration: end, delay: delay, repeats: repeats)
    }

    /// 从 0 到 to 正弦往返，一直循环
    static func swing(_ part: Part, _ property: Property, to: Double, halfPeriod: Double) -> Track {
        Track(part: part, property: property, values: [0, to], keyTimes: [0, 1], timings: [.sineInOut],
              duration: halfPeriod, repeats: true, autoreverses: true)
    }

    static func spring(_ part: Part, _ property: Property, from: Double, _ timing: Timing, delay: Double = 0) -> Track {
        guard case .spring(let response, _) = timing else { preconditionFailure("不是弹簧：\(timing)") }
        return Track(part: part, property: property, values: [from, 0], keyTimes: [0, 1], timings: [timing],
                     duration: response, delay: delay)
    }
}

