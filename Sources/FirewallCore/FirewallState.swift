/// 单调时钟上的一个时刻：`CLOCK_MONOTONIC`，开机起算、睡眠也走、改系统时间不受影响，精确到毫秒。
public struct MonotonicTime: Comparable, Hashable, Sendable {
    public var milliseconds: Int64
    public init(milliseconds: Int64) { self.milliseconds = milliseconds }
    public static func < (a: Self, b: Self) -> Bool { a.milliseconds < b.milliseconds }
}

/// 此刻是哪一次开机的什么时候
public struct Moment: Sendable {
    /// `kern.bootsessionuuid`，每次开机都换
    public var bootSession: String
    public var now: MonotonicTime
    public init(bootSession: String, now: MonotonicTime) {
        self.bootSession = bootSession
        self.now = now
    }
}

public enum FirewallMode: Equatable, Sendable {
    case off
    case trial(deadline: MonotonicTime)
    case on
}

public struct FirewallState: Equatable, Sendable {
    public var mode: FirewallMode = .off
    public var bootSession: String
    /// 本次开机拿到的 pf 启用引用；`nil` 是还没拿
    public var reference: PFReference?
    /// 本次开机装进 anchor 的规则；`nil` 是没装（或已清掉）
    public var loadedRules: FirewallRules?
    /// 上一轮核对时本 anchor 的 Evaluations；重装规则后清掉（计数从 0 数起）
    public var lastEvaluations: UInt64?

    public init(bootSession: String) { self.bootSession = bootSession }

    /// 开启后不点「保留」，过多久自动回到 off（docs/firewall.md §3）
    public static let trialMilliseconds: Int64 = 120_000

    /// 开启：进入试运行
    public mutating func enable(at moment: Moment) throws(FirewallCommandError) {
        advance(to: moment)
        guard mode == .off else { throw .notOff }
        mode = .trial(deadline: MonotonicTime(milliseconds: moment.now.milliseconds + Self.trialMilliseconds))
    }

    /// 保留：试运行转正
    public mutating func keep(at moment: Moment) throws(FirewallCommandError) {
        advance(to: moment)
        guard case .trial = mode else { throw .notInTrial }
        mode = .on
    }

    /// 关闭：任何状态都回到 off，不会失败（关闭是逃生办法之一）
    public mutating func disable() { mode = .off }

    /// 时间走到 `moment`：换了一次开机就把试运行当 off（开机不带着没确认过的规则上线）、忘掉装过什么；试运行到期回到 off。
    /// 每一轮和每条命令都先走这一步，所以「到期必回滚」「开机 trial 当 off」不靠调用方记得
    public mutating func advance(to moment: Moment) {
        if moment.bootSession != bootSession {
            bootSession = moment.bootSession
            if case .trial = mode { mode = .off }
            loadedRules = nil
            // 引用还在不在交给 tick 按 pfctl -s References 判（开机后旧 token 不在列表里，自然作废）：
            // 开机标识读错一次被当成重启时，不会丢掉还活着的引用、再多 -E 一个。认不出号码的引用核对不了，当没了
            if reference == .unknownToken { reference = nil }
        }
        if case .trial(let deadline) = mode, moment.now >= deadline { mode = .off }
    }
}

/// 命令和状态机对不上：界面按钮和状态摘要不同步时会遇到（比如点「保留」时试运行刚好到期）
public enum FirewallCommandError: Error, Equatable {
    case notOff
    case notInTrial
}

/// pf 启用引用（docs/firewall.md §4「启用 pf」）
public enum PFReference: Equatable, Sendable {
    /// `pfctl -X <token>` 能释放
    case held(token: String)
    /// `pfctl -E` 成功了但认不出 token：引用拿到了、释放不了。不能再 -E，否则每轮多一个引用
    case unknownToken
}

/// 一轮里对 pf 做的一件事，由守护进程按顺序执行
public enum PFAction: Equatable, Sendable {
    /// `pfctl -a <anchor> -f -`
    case load(FirewallRules)
    /// `pfctl -E`，拿一个启用引用
    case enable
    /// `pfctl -a <anchor> -F rules`
    case flush
    /// `pfctl -X <token>`
    case release(token: String)

    public var step: PFStep {
        switch self {
        case .load: .load
        case .enable: .enable
        case .flush: .flush
        case .release: .release
        }
    }
}

/// 动作的名字，写进状态摘要（做失败的那些）
public enum PFStep: String, Codable, Sendable {
    case load, enable, flush, release
}

/// 这一轮开始时 pf 的样子
public struct PFSnapshot: Sendable {
    /// 本 anchor 没有规则（`pfctl -a <anchor> -sr` 没有输出）；读不出来时传 `false`：off 时多清一次无妨
    public var anchorEmpty: Bool
    /// `pfctl -s References` 里的 token；`nil` 是读不出来
    public var tokens: Set<String>?

    public init(anchorEmpty: Bool, tokens: Set<String>?) {
        self.anchorEmpty = anchorEmpty
        self.tokens = tokens
    }
}

extension FirewallState {
    /// 这一轮要对 pf 做什么，按顺序。
    /// 不变量：off 绝不装规则；规则没变、anchor 没被清空就不重装；还拿着引用就不再 -E；只释放 pf 里还在的引用。
    /// 读不出引用列表时宁可少一个引用（不 -E）、晚一轮释放，也不让引用越涨越多、不释放可能已经是别人的号码
    public mutating func tick(at moment: Moment, pf: PFSnapshot, rules: FirewallRules) -> [PFAction] {
        advance(to: moment)
        if pf.anchorEmpty { loadedRules = nil }
        // 有人 pfctl -d 会作废所有引用（docs/firewall.md §6）：不在列表里就是没了
        if case .held(let token) = reference, let live = pf.tokens, !live.contains(token) { reference = nil }
        var actions: [PFAction] = []
        if mode == .off {
            if !pf.anchorEmpty { actions.append(.flush) }
            if case .held(let token) = reference, pf.tokens?.contains(token) == true { actions.append(.release(token: token)) }
        } else {
            if loadedRules != rules { actions.append(.load(rules)) }
            if reference == nil { actions.append(.enable) }
        }
        return actions
    }

    /// 核对这一轮（参数见 `FirewallCheck`），记下计数给下一轮比
    public mutating func check(mainRules: String, anchorRules: String, info: String, interfaces: String, tunnel: String) -> FirewallCheck {
        let c = FirewallCheck(mainRules: mainRules, anchorRules: anchorRules, info: info, interfaces: interfaces, tunnel: tunnel,
                              previousEvaluations: lastEvaluations)
        lastEvaluations = c.evaluations
        return c
    }

    /// 守护进程做成了一件事，记下来；做失败的不记，下一轮重做。`token` 只对 `.enable` 有意义：`nil` 是 -E 成功但认不出 token
    public mutating func record(_ done: PFAction, token: String? = nil) {
        switch done {
        case .load(let r): (loadedRules, lastEvaluations) = (r, nil)
        case .enable: reference = token.map(PFReference.held) ?? .unknownToken
        case .flush: loadedRules = nil
        case .release: reference = nil
        }
    }
}
