import CoreGraphics

/// 鼠标在哪，Pip 就往哪看：输入鼠标相对身体圆心的位移，输出头的 yaw / pitch（弧度）。
/// 不知道鼠标从哪来、什么时候回正（App），也不知道怎么转过去（`Choreography.followSpring`）。
/// 数字出自 docs/mascot.md §5「跟随鼠标」：两轴各自线性，400pt 处到最大角度，再远停在最大角度。
public struct Gaze: Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double

    public static let rest = Gaze(yaw: 0, pitch: 0)

    static let reach: CGFloat = 400
    static let maxYaw = 25 * Double.pi / 180
    static let maxPitch = 20 * Double.pi / 180
    /// 结果取整的格：鼠标挪一两个点结果不变，App 就不用重新提交动画（每换一次目标都是一次 Core Animation 事务提交）
    static let step = 0.5 * Double.pi / 180

    /// offset：鼠标相对身体圆心，单位 pt，+y 向下
    public init(toward offset: CGVector) {
        func axis(_ v: CGFloat, _ max: Double) -> Double {
            let a = max * Double(Swift.max(-1, Swift.min(1, v / Self.reach)))
            return (a / Self.step).rounded() * Self.step
        }
        yaw = axis(offset.dx, Self.maxYaw)
        // 鼠标在上方（dy < 0）时抬头
        pitch = axis(-offset.dy, Self.maxPitch)
    }

    private init(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
    }
}
