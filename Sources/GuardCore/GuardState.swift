import Foundation

/// 回答：guardd 最近一轮判定的结果是什么，以什么格式交给 App。
/// 这是 `guard-state.json` 的唯一格式定义；不知道文件放在哪、怎么写、谁来读。
/// 存判定和每一路信号的布尔摘要；IP 只出现在 `egressIP` 这一个字段（面板显示用，文件 0600，不是日志），不存网卡名。
/// 日志和 `--once` 输出照旧不带 IP（AGENTS.md「日志不记 IP」）。
public struct GuardState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// guardd 每次 verdict 变化时发出的分布式通知；不带 userInfo，App 收到后重读文件（文件是唯一事实来源）。
    public static let changedNotification = "com.notchkeeper.guard-state-changed"
    public static let fileName = "guard-state.json"

    public var schemaVersion = currentSchemaVersion
    public var verdict: Verdict
    public var checkedAt: Date
    /// 以下三个 `nil` 都是「这一轮没拿到」，不是「正常」。
    public var clashRunning: Bool?
    public var routeOnTunnel: Bool?
    public var egressMatches: Bool?
    /// 出口探针失败按类型计数（`timeout`、`transport`、`badStatus`、`unparseable`），排查 unknown 用。
    public var egressFailures: [String: Int]
    /// 只有 verdict 是 unknown 时才有（见 `UnknownReason`）。可选字段，不升格式版本：旧文件没有它照样能读，
    /// 旧 App 读新文件会忽略它。没有这个键的新鲜 unknown（旧 guardd 写的）由 `GuardStateReader` 当作 probeFailed。
    public var unknownReason: UnknownReason?
    /// 只有 verdict 是 violated 时才有：这次违规开始的那一轮（见 `EgressGuard.violatedSince`）。可选字段，不升格式版本。
    public var violatedSince: Date?
    /// 这一轮观测到的出口 IP（完整点分地址，打不打码是 App 显示层的事），见 `Observation.shownEgressIP`。
    /// 跟这一轮绑定：没拿到出口（断网、探针失败或超时）就是 `nil`，不沿用上一轮；粘住的 violated 期间也照写这一轮的。
    /// 重启接续不碰它。可选字段，不升格式版本。
    public var egressIP: String?

    /// `networkPath` 是这一轮的网络快照，`nil` 表示没拿到；只用来决定 `unknownReason`，本身不落盘。
    /// `violatedSince` 传 `EgressGuard.violatedSince`；verdict 不是 violated 时忽略。
    public init(verdict: Verdict, observation o: Observation, allowlist: Set<IPv4>,
                egressFailures: [String: Int], networkPath: NetworkPath?, violatedSince: Date? = nil, checkedAt: Date) {
        self.verdict = verdict
        unknownReason = UnknownReason.decide(verdict: verdict, path: networkPath)
        self.violatedSince = verdict == .violated ? violatedSince : nil
        self.checkedAt = checkedAt
        clashRunning = o.clashRunning
        routeOnTunnel = o.routeOnTunnel
        egressMatches = o.egressMatches(allowlist)
        egressIP = o.shownEgressIP(allowlist: allowlist)?.description
        self.egressFailures = egressFailures
    }

    public func encoded() throws -> Data { try Self.encoder.encode(self) }
    public static func decode(_ data: Data) throws -> GuardState { try decoder.decode(GuardState.self, from: data) }

    /// guardd 重启时可以接续的上一份状态：解得开、格式版本和现在一样才算，不看新旧。交给 `EgressGuard(resuming:)`，
    /// 它只取 verdict 和 `violatedSince`；`egressIP` 等观测值不接续，下一轮按自己的观测重写。
    public static func resumable(from data: Data?) -> GuardState? {
        guard let data, let s = try? decode(data), s.schemaVersion == currentSchemaVersion else { return nil }
        return s
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// 回答：下一轮检测什么时候开始。
/// 上一轮没结束绝不开下一轮（路由子进程同步、HTTP 最长 6 秒，而间隔是 5 秒，见 docs/egress-guard.md 第 3 节）；
/// 慢了也不补跑，紧接着开一轮即可。
public enum PollSchedule {
    public static let interval: Duration = .seconds(5)
    /// 一轮的总截止时间。比出口探针的 6 秒 HTTP 超时多留 2 秒；那个超时是连接空闲时长，不封顶一次请求的总时长。
    /// 赶不上截止的探针算「没有结果」，见 guardd 的 `Deadline`。
    public static let roundDeadline: Duration = .seconds(8)

    public static func nextRoundStart<I: InstantProtocol>(lastStart: I, lastEnd: I, interval: I.Duration) -> I {
        max(lastStart.advanced(by: interval), lastEnd)
    }
}
