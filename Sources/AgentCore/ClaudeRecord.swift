import Foundation

/// 回答：Claude Code 会话 jsonl 的一行，对「回合到哪一步了」意味着什么。
/// 不知道文件在哪、不知道之前之后的行，也不保存任何正文：只解码判定要用的元数据字段，
/// 正文只在解码时和中断标记逐字比较一次，结果只留一个信号。
///
/// 字段来自 Haitao 本机 Claude Code 2.1.x 会话文件的键名统计（只统计键名和类型，见 docs/agent-integration.md）。
/// @see https://code.claude.com/docs/en/agent-sdk/typescript （SDKAssistantMessageError：rate_limit 等）
/// @see https://platform.claude.com/docs/en/api/messages （stop_reason 取值）
/// @see https://platform.claude.com/docs/en/api/errors （429 = rate_limit_error）
public struct ClaudeRecord: Sendable, Equatable {
    public enum Signal: Sendable, Equatable {
        /// 用户提问或工具结果：回合在进行
        case input
        /// 助手说完一段但还要继续（tool_use、pause_turn、流式中途的 null、没见过的取值）
        case assistantContinues
        /// 助手这一回合说完了
        case assistantEnded
        case apiError(AgentErrorKind)
        /// 用户按了 Esc 之类的中断
        case interrupted
        /// 与回合无关的行：标题、快照、system 摘要、isMeta 注入、压缩摘要、没时间戳的行
        case ignored
    }

    public var signal: Signal
    public var timestamp: Date?
    /// cwd 的最后一段，也就是项目文件夹名；不留完整路径
    public var project: String?
    public var isSidechain: Bool
    /// `session_meta.source.subagent`（或顶层 `source.subagent`）存在且不为 null：这条记录属于子 agent 会话。
    /// Claude Code 2.1.x 的会话文件里没见过这个字段，防御性解码；只留布尔值，不留子 agent 的名字。
    var isSubagentSession: Bool

    /// 解析不了 JSON 对象时返回 nil，由调用方计数后跳过。
    public init?(jsonLine: Data) {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: jsonLine) else { return nil }
        timestamp = raw.timestamp.flatMap(Self.parseDate)
        project = raw.cwd.flatMap { $0.split(separator: "/").last.map(String.init) }
        isSidechain = raw.isSidechain ?? false
        isSubagentSession = raw.sessionMeta?.source?.hasSubagent == true || raw.source?.hasSubagent == true
        signal = timestamp == nil ? .ignored : Self.signal(of: raw)
    }

    private static func signal(of r: Raw) -> Signal {
        switch r.type {
        case "user":
            if r.isMeta == true || r.isCompactSummary == true { return .ignored }
            return r.message?.isInterruptMarker == true ? .interrupted : .input
        case "assistant":
            if r.isApiErrorMessage == true {
                return r.error == "rate_limit" || r.apiErrorStatus == 429 ? .apiError(.rateLimit) : .apiError(.api)
            }
            // stop hook 让 Claude 接着干：这条 end_turn 不是回合结束（子 agent 过滤信号之一，见 ClaudeSubagentFilter）
            if r.stopHookActive == true { return .assistantContinues }
            switch r.message?.stopReason {
            case "end_turn", "stop_sequence", "max_tokens", "refusal": return .assistantEnded
            default: return .assistantContinues   // 没见过的取值当作还在干活，交给 90 秒兜底，宁可不提醒也不误报
            }
        default:
            return .ignored
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        (try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(s, strategy: .iso8601))
    }

    /// Claude Code 在用户中断时写入的 user 记录，正文恰好是这两串之一。
    static let interruptMarkers: Set<String> = ["[Request interrupted by user]", "[Request interrupted by user for tool use]"]
}

/// 外部格式会变：每个字段单独宽松解码，类型不对就当缺失，不让整行作废。
private struct Raw: Decodable {
    var type: String?
    var timestamp: String?
    var cwd: String?
    var isSidechain: Bool?
    var isMeta: Bool?
    var isCompactSummary: Bool?
    var isApiErrorMessage: Bool?
    var error: String?
    var apiErrorStatus: Int?
    var message: Message?
    var stopHookActive: Bool?
    var sessionMeta: SessionMeta?
    var source: Source?

    enum CodingKeys: String, CodingKey {
        case type, timestamp, cwd, isSidechain, isMeta, isCompactSummary, isApiErrorMessage, error, apiErrorStatus, message
        case stopHookActive = "stop_hook_active", sessionMeta = "session_meta", source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func lenient<T: Decodable>(_ k: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: k) }
        type = lenient(.type); timestamp = lenient(.timestamp); cwd = lenient(.cwd)
        isSidechain = lenient(.isSidechain); isMeta = lenient(.isMeta); isCompactSummary = lenient(.isCompactSummary)
        isApiErrorMessage = lenient(.isApiErrorMessage); error = lenient(.error); apiErrorStatus = lenient(.apiErrorStatus)
        message = lenient(.message)
        stopHookActive = lenient(.stopHookActive); sessionMeta = lenient(.sessionMeta); source = lenient(.source)
    }

    struct SessionMeta: Decodable {
        var source: Source?
        enum CodingKeys: CodingKey { case source }
        init(from decoder: Decoder) throws {
            source = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Source.self, forKey: .source)
        }
    }

    /// `subagent` 的值可能是字符串或对象，只看它在不在、是不是 null
    struct Source: Decodable {
        var hasSubagent: Bool
        enum CodingKeys: CodingKey { case subagent }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hasSubagent = c.contains(.subagent) && (try? c.decodeNil(forKey: .subagent)) == false
        }
    }

    struct Message: Decodable {
        var stopReason: String?
        /// 只留比较结果，正文本身不进任何属性
        var isInterruptMarker = false

        enum CodingKeys: String, CodingKey { case stopReason = "stop_reason", content }
        private struct Block: Decodable { var type: String?; var text: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stopReason = try? c.decodeIfPresent(String.self, forKey: .stopReason)
            if let s = try? c.decode(String.self, forKey: .content) {
                isInterruptMarker = ClaudeRecord.interruptMarkers.contains(s)
            } else if let blocks = try? c.decode([Block].self, forKey: .content) {
                isInterruptMarker = blocks.contains { $0.type == "text" && $0.text.map(ClaudeRecord.interruptMarkers.contains) == true }
            }
        }
    }
}
