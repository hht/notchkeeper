import Foundation
import GuardCore
import MascotCore

/// 回答：读到的这一份守卫状态，加上用户关掉的是哪一次违规，界面该画成什么、要不要红卡。
/// 纯函数，不知道文案和颜色（App 按 `status`、`tone` 去取），规则见 docs/egress-guard.md「怎么画」。
public struct GuardPresentation: Equatable, Sendable {
    /// 界面上说的那句话（docs/egress-guard.md「怎么画」）
    public enum Status: Equatable, Sendable {
        case healthy
        case mismatch
        case offline
        /// 探针没结果：不改造型，收起时右耳显示灰环
        case probeFailed
        /// 守卫没有响应：文件不存在、读不了、过期、时钟跳变，且上次不是 violated
        case unresponsive
        /// 违规；或守卫不响应但上次是 violated、用户还没关掉这一次
        case violated
        /// 用户关掉了这一次违规，之后守卫不响应：确认不了恢复没有
        case violationUnconfirmed
    }

    /// 状态点：healthy 绿、mismatch 琥珀实心、unknown 灰色空心环、violated 红
    public enum Tone: Equatable, Sendable { case healthy, mismatch, unknown, violated }

    /// 红卡的副标题
    public enum Alert: Equatable, Sendable {
        case violated
        /// 守卫不响应时保留的红卡
        case unresponsive

        /// 只有真读到违规才响 Basso
        public var sounds: Bool { self == .violated }
    }

    public let status: Status
    /// nil：这一份不要红卡（不代表撤卡：撤卡只看 healthy）
    public let alert: Alert?

    /// - dismissedViolationSince: nil = 没关掉过；.some(x) = 用户关掉了 violatedSince 为 x 的那次
    public init(_ d: GuardDisplay, dismissedViolationSince: Date??) {
        let unresponsive = d.reason == .stale || d.reason == .clockSkew
        if d.verdict == .violated || (unresponsive && d.lastVerdict == .violated) {
            let dismissed = dismissedViolationSince == .some(d.violatedSince)
            if dismissed {
                status = d.verdict == .violated ? .violated : .violationUnconfirmed
                alert = nil
            } else {
                status = .violated
                alert = d.verdict == .violated ? .violated : .unresponsive
            }
            return
        }
        alert = nil
        switch d.verdict {
        case .healthy: status = .healthy
        case .egressMismatch: status = .mismatch
        case .unknown, .violated:
            switch d.unknownReason {
            case .offline: status = .offline
            case .probeFailed: status = .probeFailed
            // stale / missing / clockSkew / unreadable（docs §4 同样归到这一行）
            case nil: status = .unresponsive
            }
        }
    }

    public var tone: Tone {
        switch status {
        case .healthy: return .healthy
        case .mismatch: return .mismatch
        case .offline, .probeFailed, .unresponsive, .violationUnconfirmed: return .unknown
        case .violated: return .violated
        }
    }

    /// Pip 画成哪个守卫造型；没有守卫的事时是 idle（docs/mascot.md §2）
    public var look: Look {
        switch status {
        case .healthy, .probeFailed: return .idle
        case .mismatch: return .mismatch
        case .offline: return .offline
        case .unresponsive: return .stale
        case .violated, .violationUnconfirmed: return .danger
        }
    }

    /// 违规还在（或守卫不响应时最后一次是违规）：用户此刻关掉红卡算关掉这一次
    public var holdsViolation: Bool { status == .violated || status == .violationUnconfirmed }
}
