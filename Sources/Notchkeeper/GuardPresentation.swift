import SwiftUI
import GuardCore

/// 回答一个问题：读到的这一份守卫状态，加上用户关掉的是哪一次违规，界面该怎么画、要不要红卡。
/// 纯函数，不读文件、不碰卡片，规则见 docs/egress-guard.md「怎么画」一节。
struct GuardPresentation: Equatable {
    /// 状态点：healthy 绿、mismatch 琥珀实心、unknown 灰色空心环、violated 红
    enum Tone: Equatable { case healthy, mismatch, unknown, violated }

    /// 要红卡时卡上的副标题，以及弹出时要不要响 Basso
    struct Alert: Equatable {
        let detail: String
        let sounds: Bool
    }

    let tone: Tone
    let title: String
    /// nil 表示这一份不要红卡（不代表撤卡：撤卡只看 `clearsAlert`）
    let alert: Alert?
    /// 违规还在（或守卫不响应时最后一次是违规）：用户此刻关掉红卡算关掉这一次
    let holdsViolation: Bool

    /// 读到 healthy 才撤红卡、清掉用户关掉的记录
    var clearsAlert: Bool { tone == .healthy }

    static let violatedTitle = "出口不合规"
    static let violatedDetail = "有流量没走 utun 隧道"
    static let unresponsiveDetail = "守卫没有响应，无法确认出口是否恢复"

    /// - dismissedViolationSince: nil = 没关掉过；.some(x) = 用户关掉了 violatedSince 为 x 的那次
    init(_ d: GuardDisplay, dismissedViolationSince: Date??) {
        let verdict = d.verdict
        let unresponsive = d.reason == .stale || d.reason == .clockSkew
        holdsViolation = verdict == .violated || (unresponsive && d.lastVerdict == .violated)
        if holdsViolation {
            let dismissed = dismissedViolationSince == .some(d.violatedSince)
            if dismissed {
                // 用户知道了：违规仍在画红点，守卫不响应画灰环
                tone = verdict == .violated ? .violated : .unknown
                title = verdict == .violated ? Self.violatedTitle : Self.unresponsiveDetail
                alert = nil
            } else {
                tone = .violated
                title = Self.violatedTitle
                alert = verdict == .violated ? Alert(detail: Self.violatedDetail, sounds: true)
                                             : Alert(detail: Self.unresponsiveDetail, sounds: false)
            }
            return
        }
        alert = nil
        switch verdict {
        case .healthy:
            tone = .healthy; title = "出口正常"
        case .egressMismatch:
            tone = .mismatch; title = "出口 IP 和预期不一致"
        case .unknown, .violated:
            tone = .unknown
            switch d.unknownReason {
            case .offline: title = "网络不通，暂时没法检查出口"
            case .probeFailed: title = "暂时查不到出口"
            // stale / missing / clockSkew / unreadable（docs §4 同样归到这一行）
            case nil: title = "守卫没有响应"
            }
        }
    }

    var mascotState: DundunState {
        switch tone {
        case .healthy: return .idle
        case .mismatch: return .guardMismatch
        case .unknown: return .guardUnknown
        case .violated: return .guardViolated
        }
    }

    var color: Color {
        switch tone {
        case .healthy: return .green
        case .mismatch: return Color(cgColor: DundunConst.amber)
        case .unknown: return Self.unknownGrey
        case .violated: return Color(cgColor: DundunConst.red)
        }
    }

    /// 出口 IP 的字色：只有 mismatch 用琥珀（IP 本身就是问题），其余浅灰
    var ipColor: Color { tone == .mismatch ? color : .white.opacity(0.6) }

    static let unknownGrey = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)
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
