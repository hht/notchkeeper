import Foundation
import Testing
@testable import AgentCore

/// 给合成行加几个顶层字段
private func adding(_ extra: String, to line: String) -> String {
    var o = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    o.merge(try! JSONSerialization.jsonObject(with: Data(extra.utf8)) as! [String: Any]) { _, new in new }
    return String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!
}
private func decode(_ s: String) -> ClaudeRecord? { ClaudeRecord(jsonLine: Data(s.utf8)) }
private let ended = L.assistant(10, stop: "end_turn")

@Suite struct SubagentSessionMarker {
    @Test(arguments: [#"{"session_meta":{"source":{"subagent":"review"}}}"#,
                      #"{"session_meta":{"source":{"subagent":{"thread_spawn":{"depth":1}}}}}"#,
                      #"{"source":{"subagent":"review"}}"#])
    func markedRecordIsSubagent(_ extra: String) throws {
        let r = try #require(decode(adding(extra, to: ended)))
        #expect(ClaudeSubagentFilter.isSubagent(r))
    }

    /// 没有、为 null、类型不对都不算子 agent，整行照常解码
    @Test(arguments: ["{}", #"{"session_meta":{"source":{"subagent":null}}}"#, #"{"session_meta":{"source":"cli"}}"#,
                      #"{"session_meta":"x"}"#, #"{"source":"cli"}"#, #"{"source":{"other":1}}"#])
    func unmarkedOrMistypedIsNotSubagent(_ extra: String) throws {
        let r = try #require(decode(adding(extra, to: ended)))
        #expect(!ClaudeSubagentFilter.isSubagent(r))
        #expect(r.signal == .assistantEnded)
    }
}

@Suite struct StopHookActive {
    /// stop hook 让 Claude 继续时，这条 end_turn 不是回合结束
    @Test func endTurnWithStopHookActiveContinues() {
        #expect(decode(adding(#"{"stop_hook_active":true}"#, to: ended))?.signal == .assistantContinues)
    }

    @Test(arguments: ["false", #""true""#, "1", "null"])
    func falseOrMistypedIsIgnored(_ value: String) {
        #expect(decode(adding(#"{"stop_hook_active":"# + value + "}", to: ended))?.signal == .assistantEnded)
    }

    @Test func apiErrorStaysAnError() {
        #expect(decode(adding(#"{"stop_hook_active":true}"#, to: L.apiError(10, error: "rate_limit", status: nil)))?.signal == .apiError(.rateLimit))
    }
}

/// AGENTS.md「子 agent 完成绝不提醒」的五个信号，固定在一处。每个场景都是：上一次扫描主会话在 working，
/// 这次读到对应的行，`SessionEvent.diff` 不能产生任何事件。
@Suite struct NoNotificationSignals {
    private func events(_ lines: [String]) -> [SessionEvent] {
        let before = session([L.prompt(0)])!
        return SessionEvent.diff(old: [before], new: [session([L.prompt(0)] + lines)].compactMap { $0 })
    }

    /// 对照组：普通的回合结束确实会提醒，下面的断言不是空转
    @Test func controlPlainEndTurnNotifies() { #expect(events([ended]).count == 1) }

    @Test func signal1_subagentsDirectory() {
        #expect(ClaudeSubagentFilter.isSubagentFile(relativePath: "-Users-x-proj/abc/subagents/agent-1.jsonl"))
    }

    @Test func signal2_isSidechain() { #expect(events([L.assistant(10, stop: "end_turn", sidechain: true)]).isEmpty) }

    @Test func signal3_sessionMetaSourceSubagent() {
        #expect(events([adding(#"{"session_meta":{"source":{"subagent":"review"}}}"#, to: ended)]).isEmpty)
        #expect(events([adding(#"{"source":{"subagent":"review"}}"#, to: ended)]).isEmpty)
    }

    @Test func signal4_stopHookActive() { #expect(events([adding(#"{"stop_hook_active":true}"#, to: ended)]).isEmpty) }

    @Test func signal5_interrupt() { #expect(events([L.assistant(5, stop: "tool_use"), L.interrupt(10)]).isEmpty) }
}

/// 子 agent 标记是会话级的：真实格式可能只在文件开头一行带 `session_meta`，后面的记录不带。
/// 窗口里任何一条记录带标记，整个会话都不算主会话（不显示、不提醒）。
@Suite struct SubagentSessionIsWholeFile {
    private let marked = adding(#"{"session_meta":{"source":{"subagent":"review"}}}"#, to: L.prompt(0))

    @Test func markerOnFirstLineDropsWholeSession() {
        #expect(session([marked, L.prompt(1), L.assistant(10, stop: "end_turn")]) == nil)
    }

    /// 尾部窗口不一定从文件第一行开始：标记出现在窗口中间的任何一条也算
    @Test func markerOnLaterLineDropsWholeSession() {
        let laterMarked = adding(#"{"session_meta":{"source":{"subagent":"review"}}}"#, to: L.assistant(5, stop: "tool_use"))
        #expect(session([L.prompt(0), laterMarked, L.assistant(10, stop: "end_turn")]) == nil)
    }

    @Test func topLevelSourceMarkerAlsoDropsWholeSession() {
        #expect(session([adding(#"{"source":{"subagent":"review"}}"#, to: L.prompt(0)), L.assistant(10, stop: "end_turn")]) == nil)
    }

    @Test func markedSessionNeverNotifies() {
        let before = session([L.prompt(0)])!
        let after = session([marked, L.prompt(0), L.assistant(10, stop: "end_turn")])
        #expect(SessionEvent.diff(old: [before], new: [after].compactMap { $0 }).allSatisfy {
            if case .finished = $0 { false } else { true }
        })
    }

    /// 对照：null 标记、侧链记录不影响主会话本身
    @Test func nullMarkerOrSidechainKeepsMainSession() {
        let nullMarked = adding(#"{"session_meta":{"source":{"subagent":null}}}"#, to: L.prompt(0))
        #expect(session([nullMarked, L.assistant(10, stop: "end_turn")])?.state == .finished)
        #expect(session([L.prompt(0), L.assistant(5, stop: "end_turn", sidechain: true), L.assistant(10, stop: "end_turn")])?.state == .finished)
    }
}
