import CoreGraphics

/// 鼠标在哪，盾盾就往哪看、往哪歪。输入鼠标相对身体圆心的位移，输出眼睛偏移和身体倾角。
/// 不知道鼠标从哪来、什么时候回正（App），也不知道怎么动过去（`Choreography.followSpring`）。
/// 数字出自 docs/dundun.md §5「跟随鼠标」：400pt 以内跟，眼睛最多偏 1.5 单位，身体最多倾斜 4°。
public struct Gaze: Equatable, Sendable {
    /// 眼睛偏移，画布单位，+y 向下
    public var eyes: CGVector
    /// 身体倾角，弧度，+ = 顺时针（向右歪）
    public var tilt: Double

    public static let rest = Gaze(eyes: .zero, tilt: 0)

    static let reach: CGFloat = 400
    /// 300–400pt 之间渐弱，不在边界上一下跳回正
    static let fadeFrom: CGFloat = 300
    /// 鼠标就在盾盾身上时不斜眼
    static let deadZone: CGFloat = 8
    static let maxEyes: CGFloat = 1.5
    /// 离得多近眼睛就偏到最大
    static let fullEyesAt: CGFloat = 80
    static let maxTilt = 4 * Double.pi / 180
    /// 鼠标横向偏多远身体就歪到最大
    static let fullTiltAt: CGFloat = 240
    /// 结果取整的格：鼠标挪一两个点结果不变，App 就不用重新提交动画。
    /// 每换一次目标都是一次 Core Animation 事务提交；0.1 单位的格子鼠标绕圈时几乎每个事件都要提交，弹簧本来就会把台阶抹平
    static let eyeStep: CGFloat = 0.25
    static let tiltStep = 0.5 * Double.pi / 180

    /// offset：鼠标相对身体圆心，单位 pt，+y 向下
    public init(toward offset: CGVector) {
        let d = hypot(offset.dx, offset.dy)
        guard d > Self.deadZone, d < Self.reach else {
            self = .rest
            return
        }
        let fade = min(1, (Self.reach - d) / (Self.reach - Self.fadeFrom))
        let shift = Self.maxEyes * min(1, d / Self.fullEyesAt) * fade
        let lean = max(-1, min(1, offset.dx / Self.fullTiltAt)) * fade
        eyes = CGVector(dx: Self.snap(offset.dx / d * shift, Self.eyeStep), dy: Self.snap(offset.dy / d * shift, Self.eyeStep))
        tilt = Self.snap(Self.maxTilt * lean, Self.tiltStep)
    }

    private init(eyes: CGVector, tilt: Double) {
        self.eyes = eyes
        self.tilt = tilt
    }

    /// 向零取整：斜着看时两个分量各自进位会超过上限。加一点余量，免得 1.5 / 0.1 = 14.999… 被舍成 14
    private static func snap(_ v: Double, _ step: Double) -> Double {
        let n = v / step
        return (n + (n < 0 ? -1e-9 : 1e-9)).rounded(.towardZero) * step
    }
}
