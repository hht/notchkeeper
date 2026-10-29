import Foundation
@testable import AgentCore

/// 合成的会话行，全部手写，不来自真实文件。正文统一用 `secret`，隐私测试会检查它不出现在任何解码结果里。
let secret = "SECRET-正文-不应出现"
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func iso(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: d)
}

private func line(_ obj: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
}

private func base(_ type: String, _ at: TimeInterval, sidechain: Bool) -> [String: Any] {
    ["type": type, "timestamp": iso(t0 + at), "sessionId": "s1", "cwd": "/Users/x/Documents/Projects/notchkeeper",
     "isSidechain": sidechain, "uuid": UUID().uuidString, "version": "2.1.0"]
}

enum L {
    static func prompt(_ at: TimeInterval, sidechain: Bool = false) -> String {
        var o = base("user", at, sidechain: sidechain)
        o["message"] = ["role": "user", "content": secret]
        return line(o)
    }
    static func toolResult(_ at: TimeInterval) -> String {
        var o = base("user", at, sidechain: false)
        o["message"] = ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t", "content": secret]]]
        o["toolUseResult"] = ["stdout": secret]
        return line(o)
    }
    static func meta(_ at: TimeInterval) -> String {
        var o = base("user", at, sidechain: false)
        o["isMeta"] = true
        o["message"] = ["role": "user", "content": secret]
        return line(o)
    }
    static func assistant(_ at: TimeInterval, stop: String?, sidechain: Bool = false) -> String {
        var o = base("assistant", at, sidechain: sidechain)
        o["message"] = ["role": "assistant", "model": "m", "stop_reason": stop.map { $0 as Any } ?? NSNull(),
                        "content": [["type": "text", "text": secret]]]
        return line(o)
    }
    static func apiError(_ at: TimeInterval, error: String?, status: Int?) -> String {
        var o = base("assistant", at, sidechain: false)
        o["isApiErrorMessage"] = true
        if let error { o["error"] = error }
        if let status { o["apiErrorStatus"] = status }
        o["message"] = ["role": "assistant", "stop_reason": "stop_sequence",
                        "content": [["type": "text", "text": "API Error: 429 rate limit \(secret)"]]]
        return line(o)
    }
    /// Claude Code 写的中断标记：user 记录里的一个 text 块，正文恰好是标记串
    static func interrupt(_ at: TimeInterval, forToolUse: Bool = false, asString: Bool = false) -> String {
        var o = base("user", at, sidechain: false)
        let marker = forToolUse ? "[Request interrupted by user for tool use]" : "[Request interrupted by user]"
        o["message"] = ["role": "user", "content": asString ? marker as Any : [["type": "text", "text": marker]] as Any]
        return line(o)
    }
    static func system(_ at: TimeInterval, subtype: String) -> String {
        var o = base("system", at, sidechain: false)
        o["subtype"] = subtype
        o["content"] = secret
        return line(o)
    }
    static func title() -> String { line(["type": "ai-title", "aiTitle": secret, "sessionId": "s1"]) }
}

func records(_ lines: [String]) -> [ClaudeRecord] { lines.compactMap { ClaudeRecord(jsonLine: Data($0.utf8)) } }
func session(_ lines: [String]) -> AgentSession? { AgentSession(claudeSessionID: "s1", records: records(lines)) }
