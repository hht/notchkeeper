import Foundation

/// 回答：一个编码 agent 的主会话现在处在回合的哪一步。这是 UI 消费的接口（S1m0nE 按它写界面）。
/// 不知道记录从哪读来、不知道上一轮扫描的结果，也不决定要不要提醒（那是 `SessionEvent` 的事）。
public enum AgentKind: String, Sendable, Codable, CaseIterable { case claudeCode }

public enum AgentErrorKind: String, Sendable { case api, rateLimit }

public enum AgentState: Sendable, Equatable {
    case working, finished, error(AgentErrorKind), interrupted
    /// working 之后静默超过 `AgentSession.staleAfter`：进程多半没了，或在等权限确认。不算 working，不提醒。
    case stale
}

public struct AgentSession: Sendable, Equatable, Identifiable {
    /// 会话 id，即 Claude Code 会话文件名（不含扩展名）
    public var id: String
    public var kind: AgentKind
    /// cwd 的最后一段；拿不到时是空串，UI 只显示用时
    public var project: String
    public var state: AgentState
    /// 当前（或刚结束的）回合第一条 working 记录的时间；尾部窗口没覆盖到时取窗口里第一条，一条都没有时为 nil
    public var turnStartedAt: Date?
    /// 最后一条参与判定的记录的时间
    public var updatedAt: Date

    /// 90 秒兜底：working 期间文件这么久没写入，就降成 stale
    public static let staleAfter: TimeInterval = 90

    public init(id: String, kind: AgentKind, project: String, state: AgentState, turnStartedAt: Date?, updatedAt: Date) {
        self.id = id; self.kind = kind; self.project = project
        self.state = state; self.turnStartedAt = turnStartedAt; self.updatedAt = updatedAt
    }

    /// 按顺序折叠一个 Claude Code 主会话文件尾部的记录；没有任何参与判定的主会话记录时返回 nil。
    /// 侧链（isSidechain）记录在这里丢掉，子 agent 文件由 `ClaudeSubagentFilter` 在找文件时丢掉。
    /// 任何一条记录带子 agent 会话标记（`session_meta.source.subagent`）时，整个会话都不是主会话，返回 nil。
    public init?(claudeSessionID id: String, records: [ClaudeRecord]) {
        if ClaudeSubagentFilter.isSubagentSession(records) { return nil }
        var state: AgentState?
        var turnStart: Date?
        var last: Date?
        var project = ""
        for r in records where !ClaudeSubagentFilter.isSubagent(r) && r.signal != .ignored {
            guard let t = r.timestamp else { preconditionFailure("ClaudeRecord 保证没时间戳的行是 .ignored") }
            let wasWorking = state == .working
            switch r.signal {
            case .input, .assistantContinues:
                if !wasWorking { state = .working; turnStart = t }
            case .assistantEnded: state = .finished
            case .apiError(let kind): state = .error(kind)
            case .interrupted: state = .interrupted
            case .ignored: preconditionFailure("上面已过滤")
            }
            // 结束类记录前面没有 working（窗口从回合末尾开始），就不知道起点
            if state != .working, !wasWorking { turnStart = nil }
            last = t
            project = r.project ?? project
        }
        guard let state, let last else { return nil }
        self.init(id: id, kind: .claudeCode, project: project, state: state, turnStartedAt: turnStart, updatedAt: last)
    }

    /// 套上 90 秒兜底。`lastWrite` 是文件 mtime：最后一条记录可能还没写完整，mtime 更能说明还活着。
    public func resolved(now: Date, lastWrite: Date) -> AgentSession {
        guard state == .working, now.timeIntervalSince(max(lastWrite, updatedAt)) > Self.staleAfter else { return self }
        var s = self
        s.state = .stale
        return s
    }
}

/// 回答：这条记录 / 这个文件是不是子 agent 的。子 agent 完成绝不提醒（AGENTS.md 硬规则）。
///
/// 不提醒的五个信号，固定测试在 Tests/AgentCoreTests/SubagentFilterTests.swift 的 `NoNotificationSignals`：
/// 1. 路径里有 `subagents/` 目录：`isSubagentFile`，找文件时丢掉
/// 2. `isSidechain: true`：`isSubagent`，整条记录丢掉
/// 3. `session_meta.source.subagent`（或顶层 `source.subagent`）：会话级，`isSubagentSession`，窗口里任一条带标记就整个会话丢掉；
///    `isSubagent` 对带标记的单条记录也返回 true
/// 4. `stop_hook_active: true`：`ClaudeRecord` 把这条 assistant 记录当作还在继续，不算回合结束
/// 5. 中断标记：`ClaudeRecord` 判成 interrupted，`SessionEvent` 不为它产生事件
public enum ClaudeSubagentFilter {
    public static func isSubagent(_ r: ClaudeRecord) -> Bool { r.isSidechain || r.isSubagentSession }

    /// 标记可能只出现在文件开头一行，所以按整个窗口判断。不公开：AgentSession 的 init 已经用它。
    static func isSubagentSession(_ records: [ClaudeRecord]) -> Bool { records.contains { $0.isSubagentSession } }

    /// `relativePath` 相对 `~/.claude/projects`。主会话只能是 `<项目目录>/<会话>.jsonl`；
    /// 任何一层叫 `subagents` 的目录里的文件都是子 agent。
    public static func isSubagentFile(relativePath: String) -> Bool {
        relativePath.split(separator: "/").dropLast().contains("subagents")
    }
}
