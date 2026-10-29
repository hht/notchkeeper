import Foundation

/// App 该显示什么，以及为什么。`checkedAt` 只在读出了时间时才有（排查 / 显示「上次检查于」用）。
public struct GuardDisplay: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// 文件新鲜，`verdict` 就是 guardd 的判定
        case fresh
        /// `checkedAt` 超过 3 个间隔：guardd 多半没在跑
        case stale
        /// 文件不存在：guardd 从没跑过，或被卸载
        case missing
        /// 读出来了但解不开，或格式版本和 App 不同
        case unreadable
        /// `checkedAt` 在未来超过 1 个间隔：系统时间被改过
        case clockSkew
    }

    public var verdict: Verdict
    public var checkedAt: Date?
    public var reason: Reason
    /// guardd 给的 unknown 原因：只在 `reason == .fresh` 且 `verdict == .unknown` 时有，否则 `nil`。
    /// App 侧原因（stale、missing、clockSkew 等）看 `reason`，不看这里。
    public var unknownReason: UnknownReason? = nil
    /// 文件里最后写的 verdict：解得开就有（新鲜时等于 `verdict`，过期 / 时钟跳变时是 guardd 停下前的判定），
    /// 文件不存在、解不开时 `nil`。App 用它在 guardd 不响应时保留红卡（`reason` 是 `.stale` 或 `.clockSkew` 且它是 violated）。
    public var lastVerdict: Verdict? = nil
    /// 文件里这次违规的开始时间：只在 `lastVerdict == .violated` 时有（新鲜、过期、时钟跳变都带）。App 用它记用户关掉的是哪一次违规。
    public var violatedSince: Date? = nil
    /// guardd 这一轮观测到的出口 IP：只在 `reason == .fresh` 时有（且必须是合法 IPv4），否则 `nil`，界面显示「—」。
    /// 和 `lastVerdict` 不同，过期 / 时钟跳变时不带：红卡可以保留，但旧 IP 不能当成现在的出口显示。
    public var egressIP: String? = nil
}

/// 回答：App 读到的 `guard-state.json` 应该显示成什么。
/// 纯函数，不读文件；App 用 `try? Data(contentsOf: GuardPaths.stateFile)` 读出来传进来。
/// 除了「文件新鲜」，一律显示 unknown。粘性归 guardd，App 只显示：过期的 violated 也是 unknown。
public enum GuardStateReader {
    /// 晚于这么多个间隔算过期（等于不算）
    static let staleAfterIntervals = 3.0
    /// 早于现在超过这么多个间隔算时钟跳变
    static let futureToleranceIntervals = 1.0

    public static func display(data: Data?, now: Date, interval: Duration = PollSchedule.interval) -> GuardDisplay {
        guard let data else { return GuardDisplay(verdict: .unknown, checkedAt: nil, reason: .missing) }
        guard let state = try? GuardState.decode(data) else {
            return GuardDisplay(verdict: .unknown, checkedAt: nil, reason: .unreadable)
        }
        let seconds = interval.timeInterval
        let age = now.timeIntervalSince(state.checkedAt)
        let since = state.verdict == .violated ? state.violatedSince : nil // 别的 verdict 带了也丢掉
        if now > staleDeadline(checkedAt: state.checkedAt, interval: interval) {
            return GuardDisplay(verdict: .unknown, checkedAt: state.checkedAt, reason: .stale,
                                lastVerdict: state.verdict, violatedSince: since)
        }
        if -age > futureToleranceIntervals * seconds {
            return GuardDisplay(verdict: .unknown, checkedAt: state.checkedAt, reason: .clockSkew,
                                lastVerdict: state.verdict, violatedSince: since)
        }
        // 文件是外部数据：unknown 缺原因按 probeFailed，别的 verdict 带了原因也丢掉
        let unknownReason = state.verdict == .unknown ? state.unknownReason ?? .probeFailed : nil
        // 文件是外部数据：不是合法 IPv4 就当没有
        let egressIP = state.egressIP.flatMap(IPv4.init)?.description
        return GuardDisplay(verdict: state.verdict, checkedAt: state.checkedAt, reason: .fresh, unknownReason: unknownReason,
                            lastVerdict: state.verdict, violatedSince: since, egressIP: egressIP)
    }

    /// 过了这个时刻（严格晚于）`display` 就报 stale。`GuardReadSchedule` 按它挂过期重读，两边只有这一处定义。
    static func staleDeadline(checkedAt: Date, interval: Duration) -> Date {
        checkedAt.addingTimeInterval(staleAfterIntervals * interval.timeInterval)
    }
}

/// 回答：guardd 和 App 共用的文件在哪。两边都用这里，路径只定义一次。
/// 只求路径，不碰文件。
public enum GuardPaths {
    public static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Notchkeeper", isDirectory: true)
    /// guardd 写、App 读
    public static let stateFile = directory.appendingPathComponent(GuardState.fileName)
    /// App 写、guardd 只读 `allowlist`
    public static let configFile = directory.appendingPathComponent("config.json")
}

extension Duration {
    /// `Date` 的运算用 `TimeInterval`（秒，Double）
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
