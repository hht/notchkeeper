import CoreGraphics

/// 盾盾此刻是哪个造型、这个造型长什么样（颜色、眼形、静止姿态、右耳）。
/// 不知道造型从哪来（守卫、agent、鼠标），那是 App 的事；也不知道怎么动，见 `Choreography`。
/// 数据全部出自 docs/mascot.md §2。
public enum Look: String, CaseIterable, Sendable {
    case idle, sleeping, thinking, working, question, finished, error, interrupted, dizzy, mismatch, stale, danger

    /// 身体的竖直渐变，上 → 下
    public var gradient: (top: RGB, bottom: RGB) {
        switch self {
        case .idle, .sleeping, .interrupted: return (RGB(0xF2EEE6), RGB(0xCFCAC0))
        case .thinking: return (RGB(0xE9E2FB), RGB(0xBFB2EE))
        case .working: return (RGB(0xDCEBFF), RGB(0x9CC6F5))
        case .question: return (RGB(0xD8F4F7), RGB(0x8FD9E2))
        case .finished: return (RGB(0xE3F6EE), RGB(0xAEDCC7))
        case .error: return (RGB(0xFBE6D6), RGB(0xEDB892))
        case .dizzy: return (RGB(0xFBE3EC), RGB(0xEBB3C7))
        case .mismatch: return (RGB(0xFBEFC9), RGB(0xE8CD84))
        case .stale: return (RGB(0xEFE9DD), RGB(0xCFC2A6))
        case .danger: return (RGB(0xFFB8B0), RGB(0xF2645A))
        }
    }

    public var eyes: EyeShape {
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

    /// 只有睁着的眼会眨（圆眼、大眼、专注的半圆、星星眼）；笑眼、螺旋眼、闭眼这些本身就是表情，眨了反而怪
    public var blinks: Bool { eyes == .round || eyes == .big || eyes == .focus || eyes == .spark }

    /// 停在这个造型时的姿态（docs/mascot.md §5：思考歪头 6°、等你回答 −8°、出错一缩、stale 不透明度 0.85）
    public var pose: Pose {
        switch self {
        case .thinking: return Pose(tilt: 6 * .pi / 180)
        case .question: return Pose(tilt: -8 * .pi / 180)
        case .error: return Pose(scale: 0.94, dy: 1)
        case .stale: return Pose(opacity: 0.85)
        default: return Pose()
        }
    }
}

/// 静止姿态：动画都叠加在它上面。tilt 单位弧度，+ = 顺时针（向右歪）；dy 单位画布单位，+ = 向下
public struct Pose: Equatable, Sendable {
    public var tilt: Double = 0
    public var scale: Double = 1
    public var dy: Double = 0
    public var opacity: Double = 1
}

public struct RGB: Equatable, Sendable {
    public let hex: UInt32
    public init(_ hex: UInt32) { self.hex = hex }
    public var r: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var g: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var b: Double { Double(hex & 0xFF) / 255 }

    /// 眼睛、▲ 里的 !、气泡里的 ?
    public static let ink = RGB(0x16171A)
}

/// 右耳指示（docs/mascot.md §2 表的最后一列）。点直径 7pt；三蓝点直径 3pt、间距 2；空心环 7pt、1pt 描边
public enum EarIndicator: Equatable, Sendable {
    case none, dots, question, error, mismatch, unknown, danger

    public var color: RGB {
        switch self {
        case .none, .dots: return RGB(0x3B9EFF)
        case .question: return RGB(0x3CC8DC)
        case .error: return RGB(0xFF8A3D)
        case .mismatch: return RGB(0xFFB020)
        case .unknown: return RGB(0x8E8E93)
        case .danger: return RGB(0xFF453A)
        }
    }

    /// guardUnknown：守卫 unknown 但没有专门造型的两种原因（断网、探针没结果），盾盾照常画，只有右耳是灰环。
    /// errorUnread：出过错还没看，回到空闲后橙点继续亮（App 计时，最多 30 分钟）
    public static func `for`(_ look: Look, guardUnknown: Bool, errorUnread: Bool) -> EarIndicator {
        switch look {
        case .danger: return .danger
        case .mismatch: return .mismatch
        case .stale: return .unknown
        case _ where guardUnknown: return .unknown
        case .thinking, .working: return .dots
        case .question: return .question
        case .error: return .error
        case .idle: return errorUnread ? .error : .none
        case .sleeping, .finished, .interrupted, .dizzy: return .none
        }
    }
}
