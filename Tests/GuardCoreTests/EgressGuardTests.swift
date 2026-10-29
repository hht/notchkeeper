import Testing
@testable import GuardCore

private let allowed = IPv4("198.51.100.8")!
private let leaked = IPv4("1.2.3.4")!
private let allowlist: Set<IPv4> = [allowed, IPv4("198.51.100.7")!]

private func obs(clash: Bool? = true, iface: String? = "utun4", ips: [IPv4] = [allowed]) -> Observation {
    Observation(clashRunning: clash, routeInterface: iface, egressIPs: ips)
}

private func run(_ seq: [Observation]) -> [Verdict] {
    var g = EgressGuard()
    return seq.map { g.observe($0, allowlist: allowlist) }
}

@Suite struct IPv4Parsing {
    @Test(arguments: ["198.51.100.8", "0.0.0.0", "255.255.255.255"])
    func accepts(_ s: String) { #expect(IPv4(s)?.description == s) }

    @Test(arguments: ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1..2.3", "1.2.3.4 ", "+1.2.3.4", "١.2.3.4", "1234.1.1.1", "010.1.1.1", "1.2.3.00"])
    func rejects(_ s: String) { #expect(IPv4(s) == nil) }
}

@Suite struct Verdicts {
    @Test func allGoodIsHealthy() { #expect(run([obs()]) == [.healthy]) }

    /// Clash 不在但路由和 IP 都正常：流量没漏，只算 unknown
    @Test func clashDownAloneIsUnknown() {
        #expect(run([obs(clash: false)]) == [.unknown])
    }

    @Test func clashDownWithRouteOffTunnelIsViolated() {
        #expect(run([obs(clash: false, iface: "en0")]) == [.violated])
    }

    @Test func routeOffTunnelIsImmediate() {
        #expect(run([obs(iface: "en0")]) == [.violated])
    }

    /// 出口 IP 不在允许列表只提示，永远不判 violated（回显服务可能和别的 App 不在同一节点）
    @Test func badEgressOnlyWarnsNeverViolates() {
        #expect(run([obs(ips: [leaked]), obs(ips: [leaked]), obs(ips: [leaked])])
            == [.egressMismatch, .egressMismatch, .egressMismatch])
    }

    @Test func anyBadProbeIsMismatch() {
        #expect(run([obs(ips: [allowed, leaked])]) == [.egressMismatch])
    }

    @Test func mismatchWinsOverMissingSignals() {
        #expect(run([obs(clash: nil, ips: [leaked])]) == [.egressMismatch])
    }

    @Test func goodRoundClearsMismatch() {
        #expect(run([obs(ips: [leaked]), obs()]) == [.egressMismatch, .healthy])
    }

    @Test(arguments: [
        obs(clash: nil), obs(iface: nil), obs(ips: []),
    ])
    func missingSignalIsUnknown(_ o: Observation) { #expect(run([o]) == [.unknown]) }

    /// violated 只有一轮完整 healthy 才解除：断网、探针超时、IP 不符都不放行
    @Test func violationIsStickyUntilHealthy() {
        #expect(run([obs(iface: "en0"), obs(ips: []), obs(clash: nil), obs(ips: [leaked])])
            == [.violated, .violated, .violated, .violated])
    }

    @Test func fullHealthyRoundClearsViolation() {
        #expect(run([obs(iface: "en0"), obs()]) == [.violated, .healthy])
    }

    @Test func routeRuleWinsOverMismatch() {
        #expect(run([obs(iface: "en0", ips: [leaked])]) == [.violated])
    }

    /// 允许列表为空是配置问题：IP 一律算未知
    @Test func emptyAllowlistIsUnknown() {
        var g = EgressGuard()
        #expect(g.observe(obs(ips: [leaked]), allowlist: []) == .unknown)
    }

    /// 只有 violated 触发拦截；琥珀色两态只显示
    @Test func onlyViolatedIntercepts() {
        #expect(Verdict.violated.intercepts)
        #expect(![Verdict.healthy, .unknown, .egressMismatch].contains { $0.intercepts })
    }
}
