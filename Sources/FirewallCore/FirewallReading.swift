import Foundation

/// 回答：App 该怎么说防火墙此刻的样子——没装、关着、试运行、开着，还是说不清；有没有要人看的问题（docs/firewall.md §2、§4）。
/// App 只信新鲜的状态摘要：说 trial / on 的摘要 30 秒（3 轮）没更新就说不清；off 时守护进程不跑，不看新不新鲜。
/// 只有正式规则、核对全过、没有做失败的动作的 on 才算「已保护」。纯值：不读文件、不取时钟
public enum FirewallReading: Equatable, Sendable {
    case notInstalled
    case off(problem: Problem?)
    /// `endsAt` 是墙上时间，只给倒计时用
    case trial(endsAt: Date?, problem: Problem?)
    case on(problem: Problem?)
    /// 说不清是开是关：关掉或卸载都还能用
    case unknown(Problem)

    public enum Problem: Equatable, Sendable {
        /// 装着，但还没有状态摘要：刚装上第一轮还没写，或恢复脚本删到一半
        case noSummary
        case unreadable
        /// 说开着的摘要太久没更新：守护进程被卸、崩了，或恢复脚本刚跑过
        case stale
        /// 防火墙状态文件读不出来，守护进程按 off 办（清了规则）；要再开先卸载再装
        case stateUnreadable
        /// 装的是测试规则：只拦去测试表的流量
        case testRules
        /// 换规则那一轮没装上：anchor 里不是这一份规则（下一轮重做）
        case rulesNotLoaded
        /// 隧道网卡不在：Clash 没开 TUN 或网卡名填错，这时外网全被拦下（往安全方向出错，docs/firewall.md §5）
        case tunnelMissing
        case checkFailed
        /// 这一轮有 pf 动作没做成（下一轮重做）：关着时规则也可能还在
        case failedSteps
    }

    /// 读状态摘要的结果
    public enum Summary: Sendable {
        case missing, unreadable
        case read(FirewallStatus)
    }

    /// 守护进程 10 秒一轮，3 轮没更新就不信
    public static let freshness: TimeInterval = 30

    /// `installed`：LaunchDaemon 或辅助程序还在。没装却还剩一份摘要（卸到一半）按装着办，让人看得见、能再卸一次
    public init(installed: Bool, summary: Summary, now: Date) {
        let status: FirewallStatus
        switch summary {
        case .missing: self = installed ? .unknown(.noSummary) : .notInstalled; return
        case .unreadable: self = .unknown(.unreadable); return
        case .read(let s): status = s
        }
        let failed: Problem? = status.failedSteps.isEmpty ? nil : .failedSteps
        // 关着时只有清规则没做成才要紧：释放引用失败不影响上网，守护进程也不为它再跑（`Helper.serve`）
        if status.mode == .off { self = .off(problem: status.failedSteps.contains(.flush) ? .failedSteps : nil); return }
        // 守护进程只在按 off 办（清了规则）时这么写
        if status.mode == .stateUnreadable { self = .off(problem: .stateUnreadable); return }
        // 钟被往回调过时摘要的时刻会在未来：差多了也不信
        guard abs(now.timeIntervalSince(status.checkedAt)) <= Self.freshness else { self = .unknown(.stale); return }
        let problem: Problem? = switch (status.scope, status.check) {
        case (nil, _): .rulesNotLoaded
        case (.testTable?, _): .testRules
        // 只有别的都过、单单网卡不在，才敢说「全被拦下」
        case (_, let check?) where !check.tunnelPresent && check.passedApartFromTunnel: .tunnelMissing
        case (_, let check?) where check.passed: failed
        default: .checkFailed
        }
        self = status.mode == .trial ? .trial(endsAt: status.trialEndsAt, problem: problem) : .on(problem: problem)
    }

    /// 开关显示成开：试运行、开着，和说不清的时候（让人能点「关」）。没有摘要也算说不清：守护进程可能在拦、只是摘要写不进去
    public var switchedOn: Bool {
        switch self {
        case .notInstalled, .off: false
        case .trial, .on, .unknown: true
        }
    }

    /// 给不给「保留」：只在试运行一切正常时给。网卡不在时外网全被拦，这时保留就是把断网锁成重启也在。
    /// 测试规则只拦去测试表的流量，照样能保留
    public var canKeep: Bool {
        switch self {
        case .trial(_, nil), .trial(_, .testRules?): true
        default: false
        }
    }

    /// 开启、保留、关闭之后，开关能不能照摘要显示了：摘要是命令开始之后那一轮写的，或者等满 3 轮（守护进程可能没起来）。
    /// 从点下开始算，不从命令返回算：摘要只精确到秒，关闭后守护进程跑完那一轮就退出，晚一点取时刻就再也等不到更新的摘要
    public static func settled(checkedAt: Date?, commandStarted: Date, now: Date) -> Bool {
        checkedAt.map { $0 > commandStarted } ?? false || now.timeIntervalSince(commandStarted) > freshness
    }
}
