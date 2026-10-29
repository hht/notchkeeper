import Foundation
import Testing
@testable import AgentCore

@Suite struct RecordDecoding {
    private func decode(_ s: String) -> ClaudeRecord? { ClaudeRecord(jsonLine: Data(s.utf8)) }

    @Test func promptAndToolResultAreInput() {
        #expect(decode(L.prompt(0))?.signal == .input)
        #expect(decode(L.toolResult(0))?.signal == .input)
    }

    @Test func metaUserAndSystemAndTitleAreIgnored() {
        #expect(decode(L.meta(0))?.signal == .ignored)
        #expect(decode(L.system(0, subtype: "turn_duration"))?.signal == .ignored)
        #expect(decode(L.title())?.signal == .ignored)
    }

    @Test(arguments: [("tool_use", ClaudeRecord.Signal.assistantContinues),
                      ("pause_turn", .assistantContinues),
                      ("end_turn", .assistantEnded),
                      ("max_tokens", .assistantEnded),
                      ("stop_sequence", .assistantEnded),
                      ("refusal", .assistantEnded),
                      ("some_future_reason", .assistantContinues)])
    func stopReasons(_ stop: String, _ want: ClaudeRecord.Signal) {
        #expect(decode(L.assistant(0, stop: stop))?.signal == want)
    }

    /// stop_reason 为 null 是流式中途的半条记录，回合还没完
    @Test func nullStopReasonContinues() { #expect(decode(L.assistant(0, stop: nil))?.signal == .assistantContinues) }

    @Test func apiErrorKinds() {
        #expect(decode(L.apiError(0, error: "rate_limit", status: nil))?.signal == .apiError(.rateLimit))
        #expect(decode(L.apiError(0, error: nil, status: 429))?.signal == .apiError(.rateLimit))
        #expect(decode(L.apiError(0, error: "server_error", status: 529))?.signal == .apiError(.api))
        // 正文里写着 429 / rate limit 也不算：只看结构化字段
        #expect(decode(L.apiError(0, error: nil, status: nil))?.signal == .apiError(.api))
    }

    @Test func interruptMarkerExactMatchOnly() {
        #expect(decode(L.interrupt(0))?.signal == .interrupted)
        #expect(decode(L.interrupt(0, forToolUse: true))?.signal == .interrupted)
        #expect(decode(L.interrupt(0, asString: true))?.signal == .interrupted)
        let near = L.interrupt(0).replacingOccurrences(of: "[Request interrupted by user]", with: "[Request interrupted by user] ")
        #expect(decode(near)?.signal == .input)
        // 字符串形式的正文同样要求整串相等：用户自己打出以标记开头的话不算中断
        let nearString = L.interrupt(0, asString: true).replacingOccurrences(of: "[Request interrupted by user]", with: "[Request interrupted by user] and more")
        #expect(decode(nearString)?.signal == .input)
    }

    @Test func metadata() {
        let r = decode(L.prompt(5))
        #expect(r?.timestamp == t0 + 5)
        #expect(r?.project == "notchkeeper")
        #expect(r?.isSidechain == false)
        #expect(decode(L.prompt(5, sidechain: true))?.isSidechain == true)
    }

    @Test(arguments: ["", "{", "not json", "[]", "{\"type\":\"user\"", "\u{0}"])
    func malformedLinesAreSkipped(_ s: String) { #expect(decode(s) == nil) }

    /// 缺字段、字段类型变了都不能让整行作废，只是降级
    @Test func toleratesMissingAndMistypedFields() {
        #expect(decode(#"{"type":"user","timestamp":"2027-01-15T08:00:00.000Z","message":{"content":"x"}}"#)?.signal == .input)
        #expect(decode(#"{"type":"assistant","timestamp":"2027-01-15T08:00:00.000Z","isSidechain":"yes","message":{"stop_reason":"end_turn","content":42}}"#)?.signal == .assistantEnded)
        #expect(decode(#"{"type":"assistant","timestamp":"2027-01-15T08:00:00Z","isApiErrorMessage":true,"error":{"nested":1},"apiErrorStatus":"429"}"#)?.signal == .apiError(.api))
        #expect(decode(#"{"type":"user"}"#)?.signal == .ignored)   // 没有时间戳没法排序，不参与判定
    }

    /// 隐私：任何解码结果里都不能出现正文
    @Test(arguments: [L.prompt(0), L.toolResult(0), L.meta(0), L.assistant(0, stop: "end_turn"),
                      L.apiError(0, error: "rate_limit", status: 429), L.system(0, subtype: "x"), L.title()])
    func neverStoresText(_ s: String) throws {
        let r = try #require(decode(s))
        var dumped = ""
        dump(r, to: &dumped)
        #expect(!dumped.contains(secret))
        #expect(!dumped.contains("rate limit"))
    }
}
