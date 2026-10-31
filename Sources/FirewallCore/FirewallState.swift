/// 单调时钟上的一个时刻：`CLOCK_MONOTONIC_RAW`（见 firewalld 的 `FirewallSystem`），开机起算、睡眠也走、改系统时间不受影响，精确到毫秒。
public struct MonotonicTime: Comparable, Hashable, Sendable {
    public var milliseconds: Int64
    public init(milliseconds: Int64) { self.milliseconds = milliseconds }
    public static func < (a: Self, b: Self) -> Bool { a.milliseconds < b.milliseconds }
}

/// 此刻是哪一次开机的什么时候
public struct Moment: Sendable {
    /// `kern.bootsessionuuid`，每次开机都换；`nil` 是读不出来
    public var bootSession: String?
    public var now: MonotonicTime
    public init(bootSession: String?, now: MonotonicTime) {
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
    /// 状态是哪一次开机的（`kern.bootsessionuuid`）；`nil` 是不知道
    public var bootSession: String?
    /// 本次开机拿到的 pf 启用引用；`nil` 是还没拿
    public var reference: PFReference?
    /// 本次开机装进 anchor 的规则；`nil` 是没装（或已清掉）
    public var loadedRules: FirewallRules?
    /// 上一轮核对时本 anchor 的 Evaluations；重装规则后清掉（计数从 0 数起）
    public var lastEvaluations: UInt64?

    public init(bootSession: String?) { self.bootSession = bootSession }

    /// 开启后不点「保留」，过多久自动回到 off（docs/firewall.md §3）
    public static let trialMilliseconds: Int64 = 120_000

    /// 开启：进入试运行
    public mutating func enable(at moment: Moment) throws(FirewallCommandError) {
        advance(to: moment, liveTokens: nil)
        // 分不清是不是重启过，下一轮反正会把试运行当 off：直接报错，免得悄悄回滚、用户看不出为什么
        guard moment.bootSession != nil else { throw .bootSessionUnknown }
        guard mode == .off else { throw .notOff }
        mode = .trial(deadline: MonotonicTime(milliseconds: moment.now.milliseconds + Self.trialMilliseconds))
    }

    /// 保留：试运行转正
    public mutating func keep(at moment: Moment) throws(FirewallCommandError) {
        advance(to: moment, liveTokens: nil)
        guard moment.bootSession != nil else { throw .bootSessionUnknown }
        guard case .trial = mode else { throw .notInTrial }
        mode = .on
    }

    /// 关闭：任何状态都回到 off，不会失败（关闭是逃生办法之一）
    public mutating func disable() { mode = .off }

    /// 时间走到 `moment`：换了一次开机就把试运行当 off（开机不带着没确认过的规则上线）、忘掉装过什么；试运行到期回到 off。
    /// 每一轮和每条命令都先走这一步，所以「到期必回滚」「开机 trial 当 off」不靠调用方记得。
    /// `liveTokens` 是 `pfctl -s References` 里的 token，读不出（或命令根本不读）是 `nil`
    private mutating func advance(to moment: Moment, liveTokens: Set<String>?) {
        switch moment.bootSession {
        case nil:
            // 读不出开机标识：不知道换没换开机。试运行往安全方向当 off；引用和记下的开机标识不动：
            // 当成换了开机会丢掉还活着的引用（再也释放不了），或者把旧 token 配上错的开机标识
            if case .trial = mode { mode = .off }
        case let session? where session != bootSession:
            bootSession = session
            if case .trial = mode { mode = .off }
            loadedRules = nil
            // 换了开机标识，引用只有在列表里亲眼看见才留（开机标识读错过、其实没重启时，不丢掉还活着的引用、再多 -E 一个）。
            // 看不见就作废：留下的旧 token 会配上新开机标识落盘，恢复脚本据开机标识认 token，会去 -X 上一次开机的号码。
            // 认不出号码的引用在列表里看不见，也一律作废：开机标识误判时会多 -E 一个（推断极少见）
            switch reference {
            case .held(let token) where liveTokens?.contains(token) == true: break
            default: reference = nil
            }
        default:
            break
        }
        if case .trial(let deadline) = mode, moment.now >= deadline { mode = .off }
    }
}

/// 命令和状态机对不上：界面按钮和状态摘要不同步时会遇到（比如点「保留」时试运行刚好到期）
public enum FirewallCommandError: Error, Equatable {
    case notOff
    case notInTrial
    /// 读不出开机标识（`kern.bootsessionuuid`）
    case bootSessionUnknown
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
    /// 读不出引用列表时宁可少一个引用（不 -E）、晚一轮释放，也不让引用越涨越多、不释放可能已经是别人的号码。
    /// 例外是开机标识变了：列表读不出就当没有引用、照常 -E（见 `advance`），旧 token 不能配上新开机标识留下
    public mutating func tick(at moment: Moment, pf: PFSnapshot, rules: FirewallRules) -> [PFAction] {
        advance(to: moment, liveTokens: pf.tokens)
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

    /// 核对这一轮（参数见 `FirewallCheck`），记下计数给下一轮比；pf 明确停了时顺带作废认不出号码的引用（下一轮重新 -E）。
    /// 所以只在开着时、每轮各调一次，调完再落盘
    public mutating func check(mainRules: String, anchorRules: String, info: String, interfaces: String, tunnel: String) -> FirewallCheck {
        let c = FirewallCheck(mainRules: mainRules, anchorRules: anchorRules, info: info, interfaces: interfaces, tunnel: tunnel,
                              previousEvaluations: lastEvaluations)
        lastEvaluations = c.evaluations
        // 认不出号码的引用不在列表里核对，只能靠「pf 停了」知道它被 pfctl -d 作废了：停了就当没了，下一轮重新 -E。
        // 只认明确停了，info 读不出不算
        if reference == .unknownToken, c.pfEnabled == false { reference = nil }
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

    /// -E 记下之后，拿紧接着读的引用列表（读不出是 `nil`）对一眼。列表读得出却没有 -E 给的号码，说明两边格式对不上：
    /// 当认不出，否则下一轮以为引用没了，每轮多 -E 一个
    public mutating func confirmReference(liveTokens: Set<String>?) {
        if case .held(let token) = reference, let live = liveTokens, !live.contains(token) { reference = .unknownToken }
    }
}
