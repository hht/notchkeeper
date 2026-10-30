import Foundation

/// mod 报的一个会话最近一次结束的主回合（docs/agent-integration.md「回合文件」）
public struct TurnReport: Equatable, Sendable {
    /// 已校验是 UUID：会拼进文件路径
    public var sessionId: String
    /// nil：还没结束过回合
    public var ended: EndedTurn?

    public init(sessionId: String, ended: EndedTurn?) {
        self.sessionId = sessionId
        self.ended = ended
    }
}

public struct EndedTurn: Equatable, Sendable {
    public var turnId: String
    public var outcome: TurnOutcome
    /// 结束那一刻还在跑的后台 agent
    public var backgroundAgents: Int
    /// 结束的时刻：早于 App 开始看的是中途接手，不补提醒
    public var at: Date

    public init(turnId: String, outcome: TurnOutcome, backgroundAgents: Int, at: Date) {
        self.turnId = turnId
        self.outcome = outcome
        self.backgroundAgents = backgroundAgents
        self.at = at
    }
}

/// 回合怎么结束的（docs/agent-integration.md「回合怎么结束的」）
public enum TurnOutcome: Sendable {
    case done
    case failed
    /// 你按 Esc、或在批准框里拒绝
    case canceled
}

/// 回合文件解不开的原因：App 计数、跳过，不覆盖原文件（CLAUDE.md 准则 5）
public enum TurnFileError: Error, Equatable {
    case unknownReason(String)
    case badSessionId(String)
}

/// 回答：Notchkeeper mod 写的一份 `turns/<sessionId>.json` 说最近一次结束的是哪个回合、怎么结束的。
/// 不读文件；不知道会话、进程和卡片。
public enum TurnFile {
    public static func parse(_ data: Data) throws -> TurnReport {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard UUID(uuidString: raw.sessionId) != nil else { throw TurnFileError.badSessionId(raw.sessionId) }
        return TurnReport(sessionId: raw.sessionId, ended: try raw.ended.map { e in
            EndedTurn(turnId: e.turnId, outcome: try outcome(e.reason, lastStop: e.lastStop), backgroundAgents: e.backgroundAgents,
                      at: Date(timeIntervalSince1970: e.at / 1000))
        })
    }

    private struct Raw: Decodable {
        var sessionId: String
        var ended: Ended?

        struct Ended: Decodable {
            var turnId: String
            var reason: String
            var lastStop: String?
            var backgroundAgents: Int
            /// epoch 毫秒（mod 的 `$.clock.now()`）
            var at: Double
        }
    }

    /// `reason` 的取值出自 Claude Code 2.1.296 的 `TurnCompleteReason`。在批准框里拒绝时 reason 照样是 answer，
    /// 但最后一步停在 tool_use：工具结果之后没再请求模型（10-30 实测）
    private static func outcome(_ reason: String, lastStop: String?) throws -> TurnOutcome {
        switch reason {
        case "answer": return lastStop == "tool_use" ? .canceled : .done
        case "aborted": return .canceled
        case "error", "refusal": return .failed
        default: throw TurnFileError.unknownReason(reason)
        }
    }
}
