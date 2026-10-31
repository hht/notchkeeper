import SwiftUI
import MascotCore
import NotchCore

/// 判定在 NotchCore；这里只管文案和颜色（docs/egress-guard.md「怎么画」）
extension GuardPresentation {
    var title: String {
        switch status {
        case .healthy: return String(localized: "出口正常")
        case .mismatch: return String(localized: "出口 IP 和预期不一致")
        case .offline: return String(localized: "网络不通，暂时没法检查出口")
        case .probeFailed: return String(localized: "暂时查不到出口")
        case .unresponsive: return String(localized: "守卫没有响应")
        case .violated: return Self.violatedTitle
        case .violationUnconfirmed: return Alert.unresponsive.detail
        }
    }

    static var violatedTitle: String { String(localized: "出口不合规") }

    var color: Color {
        switch tone {
        case .healthy: return .green
        case .mismatch: return Color(cgColor: RGB.amber.cg)
        case .unknown: return Color(cgColor: RGB.grey.cg)
        case .violated: return Color(cgColor: RGB.red.cg)
        }
    }

    /// 出口 IP 的字色：只有 mismatch 用琥珀（IP 本身就是问题），其余浅灰
    var ipColor: Color { tone == .mismatch ? color : .white.opacity(0.6) }
}

extension GuardPresentation.Alert {
    /// 红卡的副标题
    var detail: String {
        switch self {
        case .violated: return String(localized: "有流量没走 utun 隧道")
        case .unresponsive: return String(localized: "守卫没有响应，无法确认出口是否恢复")
        }
    }
}

/// 状态点：unknown 是灰色空心环，其余是实心点
struct GuardDot: View {
    let presentation: GuardPresentation
    var size: CGFloat = 7
    var glow = false

    var body: some View {
        let c = presentation.color
        Group {
            if presentation.tone == .unknown {
                Circle().strokeBorder(c, lineWidth: max(1.2, size / 5))
            } else {
                Circle().fill(c).shadow(color: glow ? c.opacity(0.8) : .clear, radius: 3)
            }
        }
        .frame(width: size, height: size)
    }
}
