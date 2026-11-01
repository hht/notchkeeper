import Foundation
import Testing
@testable import AgentCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// pid 1 的会话在 `t0 + at` 秒进入 `state`；sessionId 是 "s<pid>"
private func session(_ state: AgentState, at: TimeInterval = 0, pid: Int32 = 1, started: TimeInterval = -3600, id: String? = nil) -> Session {
    Session(pid: pid, processStart: t0.addingTimeInterval(started), sessionId: id ?? "s\(pid)", cwd: "/p\(pid)",
            state: state, stateSince: t0.addingTimeInterval(at))
}

/// mod 写的回合文件：pid 对应的会话最近一次结束的主回合，在 `t0 + at` 秒结束
private func report(_ turnId: String, _ outcome: TurnOutcome, at: TimeInterval = 1, pid: Int32 = 1, background: Int = 0) -> TurnReport {
    TurnReport(sessionId: "s\(pid)", ended: EndedTurn(turnId: turnId, outcome: outcome, backgroundAgents: background, at: t0.addingTimeInterval(at)))
}

/// 依次喂进去（每份在它的 stateSince 读到），返回每一步的事件
private func feed(_ board: inout AgentBoard, _ sessions: Session...) -> [AgentEvent?] {
    sessions.map { board.update($0, at: $0.stateSince) }
}

/// 依次喂回合文件，都在 `t0 + at` 读到
private func feed(_ board: inout AgentBoard, at: TimeInterval = 2, _ reports: TurnReport...) -> [AgentEvent?] {
    reports.map { board.update($0, at: t0.addingTimeInterval(at)) }
}

/// App 在 t0 开始看
private func makeBoard() -> AgentBoard { AgentBoard(since: t0) }

/// 回合结束只看 mod 的回合文件（docs/agent-integration.md「回合怎么结束的」）
@Suite struct TurnEnds {
    @Test func doneTurnIsReported() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done)) == [.turnDone(pid: 1)])
    }

    @Test func failedTurnIsReported() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .failed)) == [.turnFailed(pid: 1)])
    }

    @Test func canceledTurnIsQuiet() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .canceled)) == [nil])
    }

    /// 结束时还有后台 agent 在跑：不提醒；它们完成后送进来的通知回合结束才提醒
    @Test func doneWithBackgroundAgentsWaitsForTheNextTurn() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done, background: 1), report("t2", .done, at: 5)) == [nil, .turnDone(pid: 1)])
    }

    /// 出错不管后台 agent
    @Test func failedWithBackgroundAgentsStillFails() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .failed, background: 2)) == [.turnFailed(pid: 1)])
    }

    /// 同一份结束的回合读到两次，只提醒一次
    @Test func sameEndedTurnOnce() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done), report("t1", .done)) == [.turnDone(pid: 1), nil])
    }

    /// 排队的消息：上一回合结束、下一回合紧接着开始，上一回合照常提醒
    @Test func eachEndedTurnIsReported() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done), report("t2", .done, at: 3)) == [.turnDone(pid: 1), .turnDone(pid: 1)])
    }

    /// 中途接手：App 开始看之前就结束的回合不补提醒
    @Test func turnEndedBeforeWatchingIsQuiet() {
        var board = makeBoard()
        _ = feed(&board, session(.stopped))
        #expect(feed(&board, report("t1", .done, at: -5)) == [nil])
    }

    /// 第一次看到的回合文件、但回合是开始看之后结束的（新会话、`/clear` 之后的第一个回合）：照常提醒
    @Test func firstReportAfterWatchingIsReported() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done, at: 1)) == [.turnDone(pid: 1)])
    }

    /// 回合文件比 sessions 文件先到（`/clear` 后 sessionId 还没换过来）：先不记，会话对上后再读到照常提醒
    @Test func reportBeforeSessionIsNotLost() {
        var board = makeBoard()
        #expect(feed(&board, report("t1", .done)) == [nil])
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done)) == [.turnDone(pid: 1)])
    }

    /// 对不上任何看着的会话（VS Code 里的会话）：不提醒
    @Test func reportWithoutSessionIsQuiet() {
        var board = makeBoard()
        #expect(feed(&board, report("t1", .done, pid: 9)) == [nil])
    }

    /// `/clear` 换了 id、进程退出，同一次运行里又用 `claude --resume <旧 id>` 回来：旧回合文件读过了，不补弹
    @Test func resumedSessionDoesNotReplayOldTurn() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(feed(&board, report("t1", .done)) == [.turnDone(pid: 1)])
        _ = feed(&board, session(.stopped, at: 3, id: "s9"))
        board.remove(pid: 1)
        _ = feed(&board, session(.stopped, at: 5, pid: 2, id: "s1"))
        #expect(feed(&board, at: 6, report("t1", .done)) == [nil])
    }

    /// 回合文件里还没有结束的回合
    @Test func noEndedTurnIsQuiet() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(board.update(TurnReport(sessionId: "s1", ended: nil), at: t0) == nil)
    }

    /// sessions 文件变成已停止不是回合结束（实测出错、取消、后台 agent 完成时都会闪一下 idle）
    @Test func stoppingIsNotATurnEnd() {
        var board = makeBoard()
        #expect(feed(&board, session(.stopped), session(.working, at: 1), session(.stopped, at: 9)) == [nil, nil, nil])
    }
}

/// 需要你介入（sessions 文件）
@Suite struct NeedingYou {
    /// 回到工作中时介入结束（介入卡要撤）
    @Test func needsYouThenWorking() {
        var board = makeBoard()
        #expect(feed(&board, session(.stopped), session(.working, at: 1), session(.needsYou(.approval), at: 2),
                     session(.needsYou(.approval), at: 2), session(.working, at: 5))
                == [nil, nil, .needsYou(.approval, pid: 1), nil, .needsYouEnded(pid: 1)])
    }

    /// 在批准框按 Esc、空闲时弹的对话框关掉：变成已停止也是介入结束
    @Test func stoppingWhileNeedingYouEndsNeed() {
        var board = makeBoard()
        #expect(feed(&board, session(.working), session(.needsYou(.question), at: 2), session(.stopped, at: 3))
                == [nil, .needsYou(.question, pid: 1), .needsYouEnded(pid: 1)])
        var idle = makeBoard()
        #expect(feed(&idle, session(.stopped), session(.needsYou(.question), at: 1), session(.stopped, at: 2))
                == [nil, .needsYou(.question, pid: 1), .needsYouEnded(pid: 1)])
    }

    /// 从等你批准换成等你回答，还在需要你介入里，不再响
    @Test func switchingNeedDoesNotPingAgain() {
        var board = makeBoard()
        #expect(feed(&board, session(.stopped), session(.needsYou(.approval), at: 1), session(.needsYou(.question), at: 2))
                == [nil, .needsYou(.approval, pid: 1), nil])
    }
}

/// App 启动时、或第一次看到某个文件时，它已经在回合里（docs/agent-integration.md「中途接手」）
@Suite struct PickingUpMidTurn {
    /// 已经在等你：不补响 Ping，之后照常结束介入
    @Test func needingYouAtFirstSightDoesNotPing() {
        var board = makeBoard()
        #expect(feed(&board, session(.needsYou(.approval)), session(.working, at: 3)) == [nil, .needsYouEnded(pid: 1)])
    }

    /// 工作开始取文件里的 `statusUpdatedAt`，不是 App 读到的时刻
    @Test func pickedUpTurnStartsWhenFileSays() {
        var board = makeBoard()
        _ = board.update(session(.working), at: t0.addingTimeInterval(590))
        #expect(board.activity(at: t0.addingTimeInterval(600)) == .longTurn)
    }

    @Test func stoppedAtFirstSightIsQuiet() {
        var board = makeBoard()
        #expect(feed(&board, session(.stopped)) == [nil])
    }
}

/// 进程没了：从列表里去掉，不算已停止，不提醒（docs/agent-integration.md「进程没了」）
@Suite struct SessionsGoing {
    @Test func removedSessionIsForgotten() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        board.remove(pid: 1)
        #expect(board.sessions.isEmpty)
        #expect(feed(&board, report("t1", .done)) == [nil])
    }

    /// pid 被复用：启动时刻不同就是另一个进程，从头算工作开始
    @Test func reusedPidIsANewSession() {
        var board = makeBoard()
        _ = feed(&board, session(.working, at: -590), session(.working, at: 5, started: 4))
        #expect(board.activity(at: t0.addingTimeInterval(10)) == .working)
    }
}

/// docs/mascot.md §2「优先级」的 agent 一档；干了很久 10 分钟出自 docs/agent-integration.md，完成 5.2s 出自 docs/mascot.md §2
@Suite struct Activity {
    @Test func nothingTrackedIsNil() {
        #expect(makeBoard().activity(at: t0) == nil)
    }

    @Test func stoppedSessionAddsNothing() {
        var board = makeBoard()
        _ = feed(&board, session(.stopped))
        #expect(board.activity(at: t0.addingTimeInterval(1)) == nil)
    }

    /// 满 10 分钟就算（到点即变，`nextChange` 才能给准确时刻），等你的时间也算进去
    @Test func longTurnAfterTenMinutesSinceWorkStart() {
        var board = makeBoard()
        _ = feed(&board, session(.stopped, at: -1), session(.working), session(.needsYou(.approval), at: 100), session(.working, at: 500))
        #expect(board.activity(at: t0.addingTimeInterval(599.9)) == .working)
        #expect(board.activity(at: t0.addingTimeInterval(600)) == .longTurn)
    }

    @Test func needsYouShowsItsKind() {
        var board = makeBoard()
        _ = feed(&board, session(.needsYou(.question)))
        #expect(board.activity(at: t0.addingTimeInterval(1)) == .question)
    }

    /// 回合做完后 5.2s 内是完成，之后什么都不加
    @Test func finishedLastsFivePointTwoSeconds() {
        var board = makeBoard()
        _ = feed(&board, session(.working), session(.stopped, at: 10))
        _ = feed(&board, at: 10, report("t1", .done, at: 10))
        #expect(board.activity(at: t0.addingTimeInterval(15.1)) == .finished)
        #expect(board.activity(at: t0.addingTimeInterval(15.2)) == nil)
    }

    /// 出错不画完成
    @Test func failedIsNotFinished() {
        var board = makeBoard()
        _ = feed(&board, session(.working), session(.stopped, at: 10))
        _ = feed(&board, at: 10, report("t1", .failed, at: 10))
        #expect(board.activity(at: t0.addingTimeInterval(11)) == nil)
    }

    /// 多个会话取最高的
    @Test func highestSessionWins() {
        var board = makeBoard()
        _ = feed(&board, session(.working, pid: 1), session(.needsYou(.question), pid: 2), session(.needsYou(.approval), pid: 3),
                 session(.working, at: 1, pid: 4), session(.stopped, at: 2, pid: 4))
        _ = feed(&board, at: 2, report("t1", .done, at: 2, pid: 4))
        #expect(board.activity(at: t0.addingTimeInterval(3)) == .approval)
        board.remove(pid: 3)
        #expect(board.activity(at: t0.addingTimeInterval(3)) == .question)
        board.remove(pid: 2)
        #expect(board.activity(at: t0.addingTimeInterval(3)) == .working)
        board.remove(pid: 1)
        #expect(board.activity(at: t0.addingTimeInterval(3)) == .finished)
    }
}

/// 不来新文件时，activity 会因为时间走到哪一刻而变：App 只挂这一个定时器
@Suite struct NextChange {
    @Test func nothingPendingIsNil() {
        var board = makeBoard()
        _ = feed(&board, session(.stopped), session(.needsYou(.question), pid: 2))
        #expect(board.nextChange(after: t0) == nil)
    }

    @Test func workingBecomesLongTurn() {
        var board = makeBoard()
        _ = feed(&board, session(.working, at: 10))
        #expect(board.nextChange(after: t0.addingTimeInterval(10)) == t0.addingTimeInterval(610))
        #expect(board.nextChange(after: t0.addingTimeInterval(610)) == nil)
    }

    @Test func earliestOfFinishedAndLongTurn() {
        var board = makeBoard()
        _ = feed(&board, session(.working, at: -598, pid: 1), session(.working, pid: 2), session(.stopped, at: 1, pid: 2))
        _ = feed(&board, at: 1, report("t1", .done, at: 1, pid: 2))
        #expect(board.nextChange(after: t0.addingTimeInterval(1)) == t0.addingTimeInterval(2))
        #expect(board.nextChange(after: t0.addingTimeInterval(2)) == t0.addingTimeInterval(6.2))
        #expect(board.nextChange(after: t0.addingTimeInterval(6.2)) == nil)
    }
}

/// 面板的会话列表：只有活着的、要看的会话；按进程启动先后排，状态变了行不挪位置
@Suite struct SessionList {
    @Test func listsTrackedSessionsByProcessStart() {
        var board = makeBoard()
        _ = feed(&board, session(.working, pid: 7, started: -10), session(.stopped, pid: 3, started: -5),
                 session(.needsYou(.approval), pid: 5, started: -20))
        #expect(board.sessions.map(\.pid) == [5, 7, 3])
        _ = board.update(session(.stopped, at: 9, pid: 5, started: -20), at: t0.addingTimeInterval(9))
        #expect(board.sessions.map(\.pid) == [5, 7, 3])
        #expect(board.sessions.first?.state == .stopped)
        board.remove(pid: 7)
        #expect(board.sessions.map(\.pid) == [5, 3])
    }

    /// procStart 只精确到秒：同一秒起的按 pid，顺序才稳定
    @Test func sameSecondOrdersByPid() {
        var board = makeBoard()
        _ = feed(&board, session(.working, pid: 9, started: -5), session(.working, pid: 2, started: -5))
        #expect(board.sessions.map(\.pid) == [2, 9])
    }
}

/// 介入结束：需要你介入的会话回到工作中、变成已停止或进程没了（docs/ubiquitous-language.md）
@Suite struct NeedsYouEnds {
    @Test func processGoneWhileNeedingYouEndsNeed() {
        var board = makeBoard()
        _ = feed(&board, session(.working), session(.needsYou(.question), at: 1))
        #expect(board.remove(pid: 1) == .needsYouEnded(pid: 1))
    }

    @Test func processGoneOtherwiseSaysNothing() {
        var board = makeBoard()
        _ = feed(&board, session(.working))
        #expect(board.remove(pid: 1) == nil)
        #expect(board.remove(pid: 1) == nil)
    }

    /// pid 被复用：旧进程正在需要你介入，就是介入结束
    @Test func reusedPidEndsOldNeed() {
        var board = makeBoard()
        _ = feed(&board, session(.working), session(.needsYou(.approval), at: 1))
        #expect(board.update(session(.working, at: 5, started: 4), at: t0.addingTimeInterval(5)) == .needsYouEnded(pid: 1))
    }
}

