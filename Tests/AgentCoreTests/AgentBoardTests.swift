import Foundation
import Testing
@testable import AgentCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// pid 1 的会话在 `t0 + at` 秒进入 `state`
private func session(_ state: AgentState, at: TimeInterval = 0, pid: Int32 = 1, started: TimeInterval = -3600) -> Session {
    Session(pid: pid, processStart: t0.addingTimeInterval(started), cwd: "/p\(pid)", state: state, stateSince: t0.addingTimeInterval(at))
}

/// 依次喂进去（每份在它的 stateSince 读到），返回每一步的事件
private func feed(_ board: inout AgentBoard, _ sessions: Session...) -> [AgentEvent?] {
    sessions.map { board.update($0, at: $0.stateSince) }
}

@Suite struct Turns {
    @Test func workingThenStoppedEndsTurn() {
        var board = AgentBoard()
        #expect(feed(&board, session(.stopped), session(.working, at: 1), session(.stopped, at: 9))
                == [nil, nil, .turnEnded(pid: 1)])
    }

    /// 经过需要你介入再回到工作中，还是同一个回合；回到工作中时介入结束（介入卡要撤）
    @Test func needsYouInsideTurnPingsOnce() {
        var board = AgentBoard()
        #expect(feed(&board, session(.stopped), session(.working, at: 1), session(.needsYou(.approval), at: 2),
                     session(.needsYou(.approval), at: 2), session(.working, at: 5), session(.stopped, at: 9))
                == [nil, nil, .needsYou(.approval, pid: 1), nil, .needsYouEnded(pid: 1), .turnEnded(pid: 1)])
    }

    /// 在批准框按 Esc：从需要你介入直接变成已停止，也是回合结束（「实测」3）
    @Test func stoppingWhileNeedingYouEndsTurn() {
        var board = AgentBoard()
        #expect(feed(&board, session(.stopped), session(.working, at: 1), session(.needsYou(.question), at: 2), session(.stopped, at: 3))
                == [nil, nil, .needsYou(.question, pid: 1), .turnEnded(pid: 1)])
    }

    /// 回合从进入工作中算起：空闲时弹出的对话框要提醒，关掉它不是回合结束，是介入结束（介入卡要撤）
    @Test func dialogWhileStoppedIsNotATurn() {
        var board = AgentBoard()
        #expect(feed(&board, session(.stopped), session(.needsYou(.question), at: 1), session(.stopped, at: 2))
                == [nil, .needsYou(.question, pid: 1), .needsYouEnded(pid: 1)])
    }

    /// 从等你批准换成等你回答，还在需要你介入里，不再响
    @Test func switchingNeedDoesNotPingAgain() {
        var board = AgentBoard()
        #expect(feed(&board, session(.stopped), session(.needsYou(.approval), at: 1), session(.needsYou(.question), at: 2))
                == [nil, .needsYou(.approval, pid: 1), nil])
    }
}

/// App 启动时、或第一次看到某个文件时，它已经在回合里（docs/agent-integration.md「中途接手」）
@Suite struct PickingUpMidTurn {
    @Test func workingAtFirstSightIsATurn() {
        var board = AgentBoard()
        #expect(feed(&board, session(.working), session(.stopped, at: 5)) == [nil, .turnEnded(pid: 1)])
    }

    /// 已经在等你：照常算回合，但不补响 Ping（用户 10-29）
    @Test func needingYouAtFirstSightDoesNotPing() {
        var board = AgentBoard()
        #expect(feed(&board, session(.needsYou(.approval)), session(.working, at: 3), session(.stopped, at: 5))
                == [nil, .needsYouEnded(pid: 1), .turnEnded(pid: 1)])
        var direct = AgentBoard()
        #expect(feed(&direct, session(.needsYou(.question)), session(.stopped, at: 5)) == [nil, .turnEnded(pid: 1)])
    }

    /// 回合开始取文件里的 `statusUpdatedAt`，不是 App 读到的时刻
    @Test func pickedUpTurnStartsWhenFileSays() {
        var board = AgentBoard()
        _ = board.update(session(.working), at: t0.addingTimeInterval(590))
        #expect(board.activity(at: t0.addingTimeInterval(600)) == .longTurn)
    }

    @Test func stoppedAtFirstSightIsQuiet() {
        var board = AgentBoard()
        #expect(feed(&board, session(.stopped)) == [nil])
    }
}

/// 进程没了：从列表里去掉，不算已停止，不提醒（docs/agent-integration.md「进程没了」）
@Suite struct SessionsGoing {
    @Test func removedSessionIsForgotten() {
        var board = AgentBoard()
        _ = feed(&board, session(.working))
        board.remove(pid: 1)
        // 同一个 pid 再出现是第一次看到：已停止就不算回合结束
        #expect(feed(&board, session(.stopped, at: 5)) == [nil])
    }

    /// pid 被复用：启动时刻不同就是另一个进程，旧的回合不会被它结束
    @Test func reusedPidIsANewSession() {
        var board = AgentBoard()
        #expect(feed(&board, session(.working), session(.stopped, at: 5, started: 4)) == [nil, nil])
    }
}

/// docs/mascot.md §2「优先级」的 agent 一档；干了很久 10 分钟出自 docs/agent-integration.md，完成 5.2s 出自 docs/mascot.md §2
@Suite struct Activity {
    @Test func nothingTrackedIsNil() {
        #expect(AgentBoard().activity(at: t0) == nil)
    }

    @Test func stoppedSessionAddsNothing() {
        var board = AgentBoard()
        _ = feed(&board, session(.stopped))
        #expect(board.activity(at: t0.addingTimeInterval(1)) == nil)
    }

    /// 满 10 分钟就算（到点即变，`nextChange` 才能给准确时刻），等你的时间也算进回合里
    @Test func longTurnAfterTenMinutesSinceTurnStart() {
        var board = AgentBoard()
        _ = feed(&board, session(.stopped, at: -1), session(.working), session(.needsYou(.approval), at: 100), session(.working, at: 500))
        #expect(board.activity(at: t0.addingTimeInterval(599.9)) == .working)
        #expect(board.activity(at: t0.addingTimeInterval(600)) == .longTurn)
    }

    @Test func needsYouShowsItsKind() {
        var board = AgentBoard()
        _ = feed(&board, session(.needsYou(.question)))
        #expect(board.activity(at: t0.addingTimeInterval(1)) == .question)
    }

    /// 回合结束后 5.2s 内是完成，之后什么都不加
    @Test func finishedLastsFivePointTwoSeconds() {
        var board = AgentBoard()
        _ = feed(&board, session(.working), session(.stopped, at: 10))
        #expect(board.activity(at: t0.addingTimeInterval(15.1)) == .finished)
        #expect(board.activity(at: t0.addingTimeInterval(15.2)) == nil)
    }

    /// 多个会话取最高的
    @Test func highestSessionWins() {
        var board = AgentBoard()
        _ = feed(&board, session(.working, pid: 1), session(.needsYou(.question), pid: 2), session(.needsYou(.approval), pid: 3),
                 session(.working, at: 1, pid: 4), session(.stopped, at: 2, pid: 4))
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
        var board = AgentBoard()
        _ = feed(&board, session(.stopped), session(.needsYou(.question), pid: 2))
        #expect(board.nextChange(after: t0) == nil)
    }

    @Test func workingBecomesLongTurn() {
        var board = AgentBoard()
        _ = feed(&board, session(.working, at: 10))
        #expect(board.nextChange(after: t0.addingTimeInterval(10)) == t0.addingTimeInterval(610))
        #expect(board.nextChange(after: t0.addingTimeInterval(610)) == nil)
    }

    @Test func earliestOfFinishedAndLongTurn() {
        var board = AgentBoard()
        _ = feed(&board, session(.working, at: -598, pid: 1), session(.working, pid: 2), session(.stopped, at: 1, pid: 2))
        #expect(board.nextChange(after: t0.addingTimeInterval(1)) == t0.addingTimeInterval(2))
        #expect(board.nextChange(after: t0.addingTimeInterval(2)) == t0.addingTimeInterval(6.2))
        #expect(board.nextChange(after: t0.addingTimeInterval(6.2)) == nil)
    }
}

/// 面板的会话列表：只有活着的、要看的会话；按进程启动先后排，状态变了行不挪位置
@Suite struct SessionList {
    @Test func listsTrackedSessionsByProcessStart() {
        var board = AgentBoard()
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
        var board = AgentBoard()
        _ = feed(&board, session(.working, pid: 9, started: -5), session(.working, pid: 2, started: -5))
        #expect(board.sessions.map(\.pid) == [2, 9])
    }
}

/// 介入结束：需要你介入的会话回到工作中或进程没了（docs/ubiquitous-language.md）；变成已停止算回合结束
@Suite struct NeedsYouEnds {
    @Test func processGoneWhileNeedingYouEndsNeed() {
        var board = AgentBoard()
        _ = feed(&board, session(.working), session(.needsYou(.question), at: 1))
        #expect(board.remove(pid: 1) == .needsYouEnded(pid: 1))
    }

    @Test func processGoneOtherwiseSaysNothing() {
        var board = AgentBoard()
        _ = feed(&board, session(.working))
        #expect(board.remove(pid: 1) == nil)
        #expect(board.remove(pid: 1) == nil)
    }

    /// pid 被复用：旧进程正在需要你介入，就是介入结束
    @Test func reusedPidEndsOldNeed() {
        var board = AgentBoard()
        _ = feed(&board, session(.working), session(.needsYou(.approval), at: 1))
        #expect(board.update(session(.working, at: 5, started: 4), at: t0.addingTimeInterval(5)) == .needsYouEnded(pid: 1))
    }
}

