import Foundation
import Testing
@testable import AgentCore

private func st(_ s: AgentSession?) -> (AgentState, Date?, Date)? { s.map { ($0.state, $0.turnStartedAt, $0.updatedAt) } }

@Suite struct SessionReducer {
    @Test func endTurnWithNothingNewerIsFinished() throws {
        let s = try #require(session([L.prompt(0), L.assistant(10, stop: "tool_use"), L.toolResult(20), L.assistant(30, stop: "end_turn"),
                                      L.system(31, subtype: "turn_duration"), L.title()]))
        #expect(s == AgentSession(id: "s1", kind: .claudeCode, project: "notchkeeper", state: .finished,
                                  turnStartedAt: t0, updatedAt: t0 + 30))
    }

    @Test func toolUseIsWorking() {
        #expect(st(session([L.prompt(0), L.assistant(10, stop: "tool_use")]))! == (.working, t0, t0 + 10))
    }

    @Test func userRecordNewerThanAssistantIsWorking() {
        #expect(st(session([L.prompt(0), L.assistant(10, stop: "tool_use"), L.toolResult(20)]))! == (.working, t0, t0 + 20))
        // 上一回合结束后的新提问开启新回合，起点从新提问算
        #expect(st(session([L.prompt(0), L.assistant(10, stop: "end_turn"), L.prompt(50)]))! == (.working, t0 + 50, t0 + 50))
    }

    @Test func apiErrorIsError() {
        #expect(session([L.prompt(0), L.apiError(5, error: "rate_limit", status: 429)])?.state == .error(.rateLimit))
        #expect(session([L.prompt(0), L.apiError(5, error: "server_error", status: nil)])?.state == .error(.api))
    }

    @Test func interruptMarkerIsInterrupted() {
        #expect(session([L.prompt(0), L.assistant(10, stop: "tool_use"), L.interrupt(12)])?.state == .interrupted)
        #expect(session([L.prompt(0), L.assistant(10, stop: nil), L.interrupt(12, forToolUse: true)])?.state == .interrupted)
    }

    /// 尾部窗口从回合中间开始：起点只能取窗口里第一条 working 记录；一条都没有就是 nil
    @Test func turnStartFallsBackToFirstWorkingRecordInWindow() {
        #expect(st(session([L.toolResult(40), L.assistant(60, stop: "end_turn")]))! == (.finished, t0 + 40, t0 + 60))
        #expect(st(session([L.assistant(60, stop: "end_turn")]))! == (.finished, nil, t0 + 60))
        #expect(st(session([L.prompt(0), L.assistant(5, stop: "end_turn"), L.interrupt(9)]))! == (.interrupted, nil, t0 + 9))
    }

    @Test func sidechainRecordsNeverCount() {
        let s = session([L.prompt(0), L.assistant(10, stop: "end_turn"), L.prompt(20, sidechain: true),
                         L.assistant(30, stop: "tool_use", sidechain: true)])
        #expect(st(s)! == (.finished, t0, t0 + 10))
        #expect(session([L.prompt(0, sidechain: true), L.assistant(5, stop: "end_turn", sidechain: true)]) == nil)
    }

    @Test func noMeaningfulRecordIsNil() {
        #expect(session([]) == nil)
        #expect(session([L.title(), L.meta(0), L.system(1, subtype: "local_command")]) == nil)
    }

    @Test func missingCwdIsEmptyProject() {
        let line = #"{"type":"user","timestamp":"2027-01-15T08:00:00.000Z","message":{"content":"x"}}"#
        #expect(session([line])?.project == "")
    }
}

@Suite struct StaleFallback {
    private let working = AgentSession(id: "s1", kind: .claudeCode, project: "p", state: .working, turnStartedAt: t0, updatedAt: t0 + 10)

    @Test func workingTurnsStaleAfter90sOfSilence() {
        #expect(working.resolved(now: t0 + 100, lastWrite: t0 + 10).state == .working)
        let stale = working.resolved(now: t0 + 100.5, lastWrite: t0 + 10)
        #expect(stale.state == .stale)
        #expect(stale.turnStartedAt == t0)
    }

    /// 文件还在写（mtime 新）就不算静默，哪怕最后一条完整记录较旧
    @Test func recentWriteKeepsWorking() {
        #expect(working.resolved(now: t0 + 150, lastWrite: t0 + 140).state == .working)
    }

    @Test(arguments: [AgentState.finished, .error(.api), .interrupted])
    func onlyWorkingGoesStale(_ state: AgentState) {
        var done = working
        done.state = state
        #expect(done.resolved(now: t0 + 9999, lastWrite: t0) == done)
    }
}
