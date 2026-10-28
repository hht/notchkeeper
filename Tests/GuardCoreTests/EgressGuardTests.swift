import Testing
@testable import GuardCore

private let allowed = IPv4("216.36.90.150")!
private let leaked = IPv4("1.2.3.4")!
private let allowlist: Set<IPv4> = [allowed, IPv4("216.36.90.116")!]

private func obs(clash: Bool? = true, iface: String? = "utun4", ips: [IPv4] = [allowed]) -> Observation {
    Observation(clashRunning: clash, primaryInterface: iface, egressIPs: ips)
}

private func run(_ seq: [Observation]) -> [Verdict] {
    var g = EgressGuard()
    return seq.map { g.observe($0, allowlist: allowlist) }
}

@Suite struct IPv4Parsing {
    @Test(arguments: ["216.36.90.150", "0.0.0.0", "255.255.255.255"])
    func accepts(_ s: String) { #expect(IPv4(s)?.description == s) }

    @Test(arguments: ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1..2.3", "1.2.3.4 ", "+1.2.3.4", "١.2.3.4", "1234.1.1.1", "010.1.1.1", "1.2.3.00"])
    func rejects(_ s: String) { #expect(IPv4(s) == nil) }
}

@Suite struct Verdicts {
    @Test func allGoodIsHealthy() { #expect(run([obs()]) == [.healthy]) }

    /// Clash 不在但路由和 IP 都正常：不是「明确异常」（AGENTS.md 硬规则），只算 unknown
    @Test func clashDownAloneIsUnknown() {
        #expect(run([obs(clash: false)]) == [.unknown])
    }

    @Test func clashDownWithRouteOffTunnelIsViolated() {
        #expect(run([obs(clash: false, iface: "en0")]) == [.violated(.routeOffTunnel)])
    }

    @Test func routeOffTunnelIsImmediate() {
        #expect(run([obs(iface: "en0")]) == [.violated(.routeOffTunnel)])
    }

    @Test func badEgressNeedsTwoConsecutiveRounds() {
        #expect(run([obs(), obs(ips: [leaked]), obs(ips: [leaked])])
            == [.healthy, .healthy, .violated(.egressNotAllowed)])
    }

    @Test func goodRoundResetsBadCount() {
        #expect(run([obs(ips: [leaked]), obs(), obs(ips: [leaked])])
            == [.unknown, .healthy, .healthy])
    }

    @Test func anyBadProbeCountsAsBad() {
        #expect(run([obs(ips: [allowed, leaked]), obs(ips: [leaked, allowed])])
            == [.unknown, .violated(.egressNotAllowed)])
    }

    @Test(arguments: [
        obs(clash: nil), obs(iface: nil), obs(ips: []),
    ])
    func missingSignalIsUnknown(_ o: Observation) { #expect(run([o]) == [.unknown]) }

    @Test func violationIsStickyThroughUnknown() {
        #expect(run([obs(iface: "en0"), obs(ips: []), obs(clash: nil)])
            == [.violated(.routeOffTunnel), .violated(.routeOffTunnel), .violated(.routeOffTunnel)])
    }

    /// 超时那一轮不清零：探针时好时坏时，漏出去的 IP 照样会被确认
    @Test func timeoutBetweenBadRoundsDoesNotResetCount() {
        #expect(run([obs(ips: [leaked]), obs(ips: []), obs(ips: [leaked])])
            == [.unknown, .unknown, .violated(.egressNotAllowed)])
    }

    @Test func fullHealthyRoundClearsViolation() {
        #expect(run([obs(iface: "en0"), obs()]) == [.violated(.routeOffTunnel), .healthy])
    }

    @Test func immediateRuleWinsOverPendingEgress() {
        #expect(run([obs(iface: "en0", ips: [leaked])]) == [.violated(.routeOffTunnel)])
    }

    /// 允许列表为空是配置问题，不是「明确异常」：永远 unknown，不累计
    @Test func emptyAllowlistIsUnknownNeverViolated() {
        var g = EgressGuard()
        for _ in 0..<3 { #expect(g.observe(obs(ips: [leaked]), allowlist: []) == .unknown) }
    }
}
