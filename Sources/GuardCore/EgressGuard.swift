/// 回答：根据一轮观测，出口现在是 healthy、unknown 还是 violated。
/// 不知道观测从哪来（Clash 进程、路由表、HTTP 探针都在外层），也不知道判定结果拿去做什么。
///
/// 规则（M3 设计，群内 2026-10-28 定）：
/// 「明确异常」只有两种（AGENTS.md 硬规则）：默认路由不走 utun，或出口 IP 不在允许列表。
/// 1. 默认路由不走 utun → 立即 violated。
/// 2. 探针拿到不在允许列表的 IP，累计 `requiredBadObservations` 轮才 violated，防抖动。
///    只有一轮全部正常的 IP 才清零；探针全超时的那一轮不清零，免得时好时坏的探针掩盖泄漏。
/// 3. Clash 在、路由走 utun、IP 都在允许列表，三者都成立才 healthy；其余（Clash 不在、
///    读不到路由、探针全超时）→ unknown。Clash 不在但路由和 IP 正常时流量并没有漏出去。
/// 允许列表为空是配置问题，不是异常：IP 一路记为未知，不累计。
/// 4. violated 是粘性的：只有一轮完整的 healthy 观测才能解除，不会降级成 unknown。
///    理由：断网时探针全失败，不能因此放行已经拦下的 Claude。

/// 一轮观测。`nil` 表示这一路没拿到结果，即「未知」，不是「正常」。
public struct Observation: Sendable {
    public var clashRunning: Bool?
    public var primaryInterface: String?
    /// 各探针拿到的出口 IP；失败的探针不放进来。
    public var egressIPs: [IPv4]

    public init(clashRunning: Bool?, primaryInterface: String?, egressIPs: [IPv4]) {
        self.clashRunning = clashRunning
        self.primaryInterface = primaryInterface
        self.egressIPs = egressIPs
    }
}

public enum Violation: Sendable, Equatable {
    case routeOffTunnel
    case egressNotAllowed
}

public enum Verdict: Sendable, Equatable {
    case healthy
    case unknown
    case violated(Violation)
}

public struct EgressGuard: Sendable {
    public static let requiredBadObservations = 2

    public private(set) var verdict: Verdict = .unknown
    private var badEgressCount = 0

    public init() {}

    public mutating func observe(_ o: Observation, allowlist: Set<IPv4>) -> Verdict {
        let ips = allowlist.isEmpty ? [] : o.egressIPs
        let egressBad = ips.contains { !allowlist.contains($0) }
        let egressGood = !ips.isEmpty && !egressBad
        if egressBad { badEgressCount += 1 } else if egressGood { badEgressCount = 0 }

        let next: Verdict
        if let iface = o.primaryInterface, !iface.hasPrefix("utun") {
            next = .violated(.routeOffTunnel)
        } else if badEgressCount >= Self.requiredBadObservations {
            next = .violated(.egressNotAllowed)
        } else if egressBad {
            next = verdict // 还没确认，维持上一轮的结论
        } else if egressGood, o.clashRunning == true, o.primaryInterface != nil {
            next = .healthy
        } else {
            next = .unknown
        }

        if case .violated = verdict, next == .unknown { return verdict } // 规则 4
        verdict = next
        return verdict
    }
}
