import Foundation
import Testing
@testable import AgentCore

private func s(_ state: AgentState, id: String = "a", start: Date? = t0, at: TimeInterval = 0) -> AgentSession {
    AgentSession(id: id, kind: .claudeCode, project: "p", state: state, turnStartedAt: start, updatedAt: t0 + at)
}

@Suite struct SessionEvents {
    @Test func workingToFinishedEmitsWithDuration() {
        #expect(SessionEvent.diff(old: [s(.working, at: 10)], new: [s(.finished, at: 75)])
                == [.finished(sessionID: "a", kind: .claudeCode, project: "p", duration: .seconds(75))])
    }

    @Test func workingToErrorEmitsKind() {
        #expect(SessionEvent.diff(old: [s(.working)], new: [s(.error(.rateLimit), start: nil, at: 3)])
                == [.error(sessionID: "a", kind: .claudeCode, project: "p", errorKind: .rateLimit)])
    }

    /// 长时间跑工具（比如 3 分钟的构建）会先被 90 秒兜底降成 stale，之后真的结束了仍要提醒
    @Test func staleToFinishedEmits() {
        #expect(SessionEvent.diff(old: [s(.stale)], new: [s(.finished, at: 200)])
                == [.finished(sessionID: "a", kind: .claudeCode, project: "p", duration: .seconds(200))])
    }

    /// 尾部窗口丢了回合起点时，用上一轮看到的起点补
    @Test func durationFallsBackToPreviousTurnStart() {
        #expect(SessionEvent.diff(old: [s(.working)], new: [s(.finished, start: nil, at: 40)])
                == [.finished(sessionID: "a", kind: .claudeCode, project: "p", duration: .seconds(40))])
        #expect(SessionEvent.diff(old: [s(.working)], new: [s(.finished, start: t0 + 30, at: 40)])
                == [.finished(sessionID: "a", kind: .claudeCode, project: "p", duration: .seconds(40))])
    }

    @Test(arguments: [AgentState.interrupted, .stale, .working])
    func neverEmitsForInterruptedStaleOrWorking(_ next: AgentState) {
        #expect(SessionEvent.diff(old: [s(.working)], new: [s(next, at: 5)]).isEmpty)
    }

    /// 只有离开 working / stale 才算；启动时第一次看到的已完成会话、已经完成过的会话都不重放
    @Test func onlyTransitionsOutOfWorking() {
        #expect(SessionEvent.diff(old: [], new: [s(.finished)]).isEmpty)
        #expect(SessionEvent.diff(old: [s(.finished)], new: [s(.finished)]).isEmpty)
        #expect(SessionEvent.diff(old: [s(.interrupted)], new: [s(.finished, at: 9)]).isEmpty)
        #expect(SessionEvent.diff(old: [s(.error(.api))], new: [s(.error(.api), at: 1)]).isEmpty)
    }

    @Test func sessionsAreIndependentAndNotCoalesced() {
        let old = [s(.working, id: "a"), s(.working, id: "b"), s(.working, id: "c")]
        let new = [s(.finished, id: "a", at: 1), s(.finished, id: "b", at: 2), s(.working, id: "c")]
        #expect(SessionEvent.diff(old: old, new: new) == [.finished(sessionID: "a", kind: .claudeCode, project: "p", duration: .seconds(1)),
                                                          .finished(sessionID: "b", kind: .claudeCode, project: "p", duration: .seconds(2))])
    }

    /// 子 agent：主会话里的侧链记录从源头就不进状态，所以永远产生不了事件
    @Test func sidechainTurnNeverEmits() {
        let old = session([L.prompt(0), L.assistant(5, stop: "end_turn")])!
        let new = session([L.prompt(0), L.assistant(5, stop: "end_turn"), L.prompt(6, sidechain: true),
                           L.assistant(9, stop: "end_turn", sidechain: true)])!
        #expect(SessionEvent.diff(old: [old], new: [new]).isEmpty)
    }

    @Test(arguments: [("-Users-x-proj/abc.jsonl", false), ("-Users-x-proj/abc/subagents/agent-1.jsonl", true),
                      ("subagents/x.jsonl", true), ("-Users-x-subagents/abc.jsonl", false)])
    func subagentFiles(_ path: String, _ want: Bool) {
        #expect(ClaudeSubagentFilter.isSubagentFile(relativePath: path) == want)
    }
}
