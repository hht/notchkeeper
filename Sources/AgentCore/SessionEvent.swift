import Foundation

/// 回答：两次扫描之间，哪些主会话的回合刚刚结束、值得弹卡。
/// 不合并连续完成（那是 UI 的事），不知道守卫状态、宿主 App 是否在前台、用户开没开通知。
///
/// 只在离开「进行中」（working 或 stale）时产生事件：
/// - interrupted、stale、working 本身都不产生事件；
/// - 第一次看到的会话不产生事件，App 启动时不重放历史；
/// - 子 agent 在 `AgentSession` 和找文件那一层就被丢掉了，到不了这里。
/// stale 也算进行中：长时间跑工具（如 3 分钟的构建）期间会被 90 秒兜底降成 stale，回合真正结束时仍要提醒。
public enum SessionEvent: Sendable, Equatable {
    case finished(sessionID: String, kind: AgentKind, project: String, duration: Duration)
    case error(sessionID: String, kind: AgentKind, project: String, errorKind: AgentErrorKind)

    public static func diff(old: [AgentSession], new: [AgentSession]) -> [SessionEvent] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return new.compactMap { s in
            guard let prev = before[s.id], prev.state == .working || prev.state == .stale else { return nil }
            switch s.state {
            case .finished:
                // 尾部窗口可能已经滑过回合起点，取两次看到的起点里更早的那个
                let start = [prev.turnStartedAt, s.turnStartedAt].compactMap { $0 }.min() ?? s.updatedAt
                return .finished(sessionID: s.id, kind: s.kind, project: s.project,
                                 duration: .seconds(s.updatedAt.timeIntervalSince(start)))
            case .error(let kind):
                return .error(sessionID: s.id, kind: s.kind, project: s.project, errorKind: kind)
            case .working, .stale, .interrupted:
                return nil
            }
        }
    }
}
