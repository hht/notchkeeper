import Foundation

/// 一个 Claude Code 会话此刻的状态，从它的 sessions 文件解析而来。
public struct Session: Equatable, Sendable {
    public var pid: Int32
    /// 进程启动时刻（UTC，精确到秒）：和 `pid` 一起认进程，防 pid 复用
    public var processStart: Date
    /// `cwd` 的最后一段
    public var project: String
    public var state: AgentState
    /// 进入这个状态的时刻
    public var stateSince: Date
}

/// agent 状态（docs/agent-integration.md「状态」）
public enum AgentState: Equatable, Sendable {
    case working
    case stopped
    case needsYou(Need)

    /// 需要你介入的是哪一类：决定盾盾是 question 还是 approval（docs/mascot.md §2）
    public enum Need: Sendable {
        case question
        case approval
    }
}

/// sessions 文件解不开的原因：App 计数、跳过，不覆盖原文件（CLAUDE.md 准则 5）
public enum SessionFileError: Error, Equatable {
    case unknownStatus(String)
}

/// 回答：一份 `~/.claude/sessions/<pid>.json` 是不是要看的会话、此刻什么状态。
/// 只取判定要的字段，不读 `name`（可能从对话推出来）；不读文件、不查进程。
/// @see docs/agent-integration.md「实测」（Claude Code 2.1.296）
public enum SessionFile {
    /// 不是终端里开的交互式 `claude`（`claude -p`、SDK、VS Code、后台会话等，用户 10-29），
    /// 或者会话刚起来还没写状态，返回 `nil`，其余字段不再检查。
    public static func parse(_ data: Data) throws -> Session? {
        let gate = try JSONDecoder().decode(Gate.self, from: data)
        guard gate.kind == "interactive", gate.entrypoint == "cli", gate.status != nil else { return nil }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return Session(pid: raw.pid, processStart: try Date(raw.procStart, strategy: lstart),
                       project: URL(fileURLWithPath: raw.cwd).lastPathComponent,
                       state: try state(raw.status, waitingFor: raw.waitingFor), stateSince: Date(timeIntervalSince1970: raw.statusUpdatedAt / 1000))
    }

    /// `claude -p` 的 `kind` 也是 `interactive`，只有 `entrypoint` 是 `sdk-cli`（「实测」1）；
    /// 会话第一次写的文件没有 `status`、`statusUpdatedAt`，过一会儿原地补上（「实测」5）
    private struct Gate: Decodable {
        var kind: String?
        var entrypoint: String?
        var status: String?
    }

    private struct Raw: Decodable {
        var pid: Int32
        var procStart: String
        var cwd: String
        var status: String
        var waitingFor: String?
        var statusUpdatedAt: Double
    }

    private static func state(_ status: String, waitingFor: String?) throws -> AgentState {
        switch status {
        case "busy", "shell": return .working
        case "idle": return .stopped
        case "waiting": return .needsYou(approvalKinds.contains(waitingFor ?? "") ? .approval : .question)
        default: throw SessionFileError.unknownStatus(status)
        }
    }

    /// Claude Code 自己把这几种 `waitingFor` 归为 permission；`input needed`、`dialog open` 和没见过的都归等你回答（用户 10-29）
    private static let approvalKinds: Set = ["permission prompt", "sandbox request", "worker request", "goal proposal"]

    /// `procStart` 是 `LC_ALL=C TZ=UTC ps -o lstart=` 的输出，例如 `Thu Oct 29 17:54:51 2026`
    private static let lstart = Date.ParseStrategy(
        format: "\(weekday: .abbreviated) \(month: .abbreviated) \(day: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) \(year: .defaultDigits)",
        locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt)
}
