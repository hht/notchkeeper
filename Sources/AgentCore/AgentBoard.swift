import Foundation

/// 该提醒的事（docs/agent-integration.md「提醒」）
public enum AgentEvent: Equatable, Sendable {
    /// 回合中变成已停止：完成卡 + Glass
    case turnEnded(pid: Int32)
    /// 进入需要你介入：介入卡 + Ping。在里面从一类换成另一类不再发
    case needsYou(AgentState.Need, pid: Int32)
}

/// 所有会话合起来，此刻 agent 这一档该画什么。按优先级从低到高排（docs/mascot.md §2「优先级」）
public enum AgentActivity: Comparable, Sendable {
    case finished, working, longTurn, question, approval
}

/// 回答：看着哪些会话、各自的回合走到哪了、刚刚发生了哪件该提醒的事。
/// 纯状态机：喂进解析好的 `Session` 和当前时间；不读文件、不查进程、不起定时器，也不知道盾盾和卡片。
public struct AgentBoard: Sendable {
    /// pid → 最近一次看到的会话，和它这一回合的开始时刻（不在回合里时为 nil）
    private var tracked: [Int32: (session: Session, turnStart: Date?)] = [:]
    /// 最近一次回合结束后，完成画到这个时刻为止
    private var finishedUntil: Date?

    /// 工作中离回合开始满这么久算干了很久（docs/agent-integration.md）。取等号：到点即变，`nextChange` 给的时刻就准
    static let longTurnAfter: TimeInterval = 600
    /// 完成持续多久（docs/mascot.md §2）
    static let finishedFor: TimeInterval = 5.2

    public init() {}

    public mutating func update(_ session: Session, at now: Date) -> AgentEvent? {
        guard let old = tracked[session.pid], old.session.processStart == session.processStart else {
            // 第一次看到这个进程（含 pid 被复用）就是中途接手：已经在回合里就以进入这个状态的时刻作回合开始，不补发事件（用户 10-29）
            tracked[session.pid] = (session, session.state == .stopped ? nil : session.stateSince)
            return nil
        }
        var turnStart = old.turnStart
        var event: AgentEvent?
        switch session.state {
        case .working:
            if turnStart == nil { turnStart = session.stateSince }
        case .stopped:
            if turnStart != nil {
                event = .turnEnded(pid: session.pid)
                finishedUntil = now.addingTimeInterval(Self.finishedFor)
            }
            turnStart = nil
        case .needsYou(let need):
            if case .needsYou = old.session.state {} else { event = .needsYou(need, pid: session.pid) }
        }
        tracked[session.pid] = (session, turnStart)
        return event
    }

    public func activity(at now: Date) -> AgentActivity? {
        let sessions = tracked.values.compactMap { entry -> AgentActivity? in
            switch entry.session.state {
            case .stopped: return nil
            case .needsYou(.question): return .question
            case .needsYou(.approval): return .approval
            case .working:
                guard let start = entry.turnStart else { preconditionFailure("工作中一定在回合里") }
                return now >= start.addingTimeInterval(Self.longTurnAfter) ? .longTurn : .working
            }
        }
        let finished = finishedUntil.map { now < $0 ? [AgentActivity.finished] : [] } ?? []
        return (sessions + finished).max()
    }

    /// 看着的会话：按进程启动先后排（同一秒按 pid），状态变了行不挪位置
    public var sessions: [Session] {
        tracked.values.map(\.session).sorted { ($0.processStart, $0.pid) < ($1.processStart, $1.pid) }
    }

    /// 不来新文件时 `activity` 下一次因为时间而变的时刻（严格晚于 `now`）：变干了很久、完成到期。没有就 nil
    public func nextChange(after now: Date) -> Date? {
        let longTurns = tracked.values.compactMap { entry in
            entry.session.state == .working ? entry.turnStart?.addingTimeInterval(Self.longTurnAfter) : nil
        }
        return (longTurns + [finishedUntil].compactMap { $0 }).filter { $0 > now }.min()
    }

    /// 进程没了（退出、pid 被复用、判不出来）：去掉，不算已停止，不提醒
    public mutating func remove(pid: Int32) {
        tracked[pid] = nil
    }
}
