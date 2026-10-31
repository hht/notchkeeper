import Foundation

/// 该提醒的事（docs/agent-integration.md「提醒」）
public enum AgentEvent: Equatable, Sendable {
    /// 主回合做完，后台 agent 也都完成了：完成卡 + Glass
    case turnDone(pid: Int32)
    /// 主回合出错：出错卡 + Funk
    case turnFailed(pid: Int32)
    /// 进入需要你介入：介入卡 + Ping。在里面从一类换成另一类不再发
    case needsYou(AgentState.Need, pid: Int32)
    /// 不再需要你介入：回到工作中、变成已停止、进程没了（含 pid 被复用）。这个会话的介入卡要撤
    case needsYouEnded(pid: Int32)
}

/// 所有会话合起来，此刻 agent 这一档该画什么。按优先级从低到高排（docs/mascot.md §2「优先级」）
public enum AgentActivity: Comparable, Sendable {
    case finished, working, longTurn, question, approval
}

/// 回答：看着哪些会话、各自此刻什么状态、刚刚发生了哪件该提醒的事。
/// 两路输入：sessions 文件管此刻的状态，mod 的回合文件管回合怎么结束的（docs/agent-integration.md「两个来源」），按 sessionId 对上。
/// 纯状态机：喂进解析好的 `Session`、`TurnReport` 和当前时间；不读文件、不查进程、不起定时器，也不知道 Pip 和卡片。
public struct AgentBoard: Sendable {
    /// pid → 最近一次看到的会话，和它这一段工作的开始时刻（已停止时为 nil）
    private var tracked: [Int32: (session: Session, workStart: Date?)] = [:]
    /// sessionId → mod 最近一次报的、对得上会话的回合文件。`/clear` 换掉的旧 id 故意不清：同一次运行里
    /// `claude --resume <旧 id>` 回来时，旧回合文件还在，靠这条记录认出是读过的，不补弹过时的卡
    private var reports: [String: TurnReport] = [:]
    /// App 开始看的时刻：这之前结束的回合是中途接手，不补提醒
    private let since: Date
    /// 最近一次回合做完后，完成画到这个时刻为止
    private var finishedUntil: Date?

    /// 工作中离工作开始满这么久算干了很久（docs/agent-integration.md）。取等号：到点即变，`nextChange` 给的时刻就准
    static let longTurnAfter: TimeInterval = 600
    /// 完成持续多久（docs/mascot.md §2）
    static let finishedFor: TimeInterval = 5.2

    public init(since: Date) {
        self.since = since
    }

    public mutating func update(_ session: Session, at now: Date) -> AgentEvent? {
        guard let old = tracked[session.pid], old.session.processStart == session.processStart else {
            // 第一次看到这个进程（含 pid 被复用）就是中途接手：已经在工作就以进入这个状态的时刻作工作开始，不补发事件（用户 10-29）。
            // pid 被复用时旧进程正在需要你介入，就是旧进程的介入结束
            let replaced = tracked[session.pid]
            tracked[session.pid] = (session, session.state == .stopped ? nil : session.stateSince)
            if case .needsYou? = replaced?.session.state { return .needsYouEnded(pid: session.pid) }
            return nil
        }
        var workStart = old.workStart
        var event: AgentEvent?
        switch session.state {
        case .working, .needsYou:
            if workStart == nil { workStart = session.stateSince }
        case .stopped:
            workStart = nil
        }
        switch (old.session.state, session.state) {
        case (.needsYou, .needsYou): break
        case (_, .needsYou(let need)): event = .needsYou(need, pid: session.pid)
        case (.needsYou, _): event = .needsYouEnded(pid: session.pid)
        default: break
        }
        tracked[session.pid] = (session, workStart)
        return event
    }

    /// 回合文件变了：结束的回合换了一个就提醒。第一次看到某个会话的回合文件时，App 开始看之前结束的是中途接手，不补提醒。
    /// 对不上会话的先不记（`/clear` 后 sessions 文件可能还没换过来），等会话对上后重读时再算
    public mutating func update(_ report: TurnReport, at now: Date) -> AgentEvent? {
        guard let pid = tracked.first(where: { $0.value.session.sessionId == report.sessionId })?.key else { return nil }
        let old = reports.updateValue(report, forKey: report.sessionId)
        guard let ended = report.ended, old.map({ $0.ended?.turnId != ended.turnId }) ?? (ended.at > since) else { return nil }
        switch ended.outcome {
        case .done:
            // 还有后台 agent 在跑：等它们完成后送进来的那个回合结束再提醒
            guard ended.backgroundAgents == 0 else { return nil }
            finishedUntil = now.addingTimeInterval(Self.finishedFor)
            return .turnDone(pid: pid)
        case .failed: return .turnFailed(pid: pid)
        case .canceled: return nil
        }
    }

    public func activity(at now: Date) -> AgentActivity? {
        let sessions = tracked.values.compactMap { entry -> AgentActivity? in
            switch entry.session.state {
            case .stopped: return nil
            case .needsYou(.question): return .question
            case .needsYou(.approval): return .approval
            case .working:
                guard let start = entry.workStart else { preconditionFailure("工作中一定有工作开始") }
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
            entry.session.state == .working ? entry.workStart?.addingTimeInterval(Self.longTurnAfter) : nil
        }
        return (longTurns + [finishedUntil].compactMap { $0 }).filter { $0 > now }.min()
    }

    /// 进程没了（退出、pid 被复用、判不出来）：连同它的回合文件一起忘掉，不提醒回合结束；正在需要你介入就是介入结束
    @discardableResult
    public mutating func remove(pid: Int32) -> AgentEvent? {
        guard let old = tracked.removeValue(forKey: pid) else { return nil }
        reports[old.session.sessionId] = nil
        if case .needsYou = old.session.state { return .needsYouEnded(pid: pid) }
        return nil
    }
}
