import Foundation
import Testing
import GuardCore
import GuardProbes
@testable import guardd

private let allowed = IPv4("198.51.100.8")!

@Suite struct RoundDeadline {
    private let clock = ContinuousClock()

    @Test func deadlineIsEightSeconds() { #expect(PollSchedule.roundDeadline == .seconds(8)) }

    @Test func onTimeResultPassesThrough() async {
        #expect(await Deadline.run(by: clock.now + .seconds(5), clock: clock) { 42 } == 42)
    }

    /// 超时就是「没有结果」，而且要等被取消的工作真的停下才返回（不留后台任务）
    @Test func missedDeadlineIsNoResultAndCancelsWork() async {
        let begin = clock.now
        let result = await Deadline.run(by: begin + .milliseconds(50), clock: clock) { () async -> Int in
            do { try await Task.sleep(for: .seconds(3)) } catch { return -1 }
            return 42
        }
        #expect(result == nil)
        #expect(clock.now - begin < .seconds(1))
    }
}

@Suite struct RoundMerge {
    private let sample = EgressProbe.Sample(ips: [allowed], failures: [.transport: 1])

    private func verdict(_ o: Observation) -> Verdict {
        var g = EgressGuard()
        return g.observe(o, allowlist: [allowed])
    }

    @Test func onTimeProbesPassThrough() {
        let (o, failures) = Guardd.merge(local: ("utun1024", true), egress: sample, egressEndpoints: 3)
        #expect(o.routeInterface == "utun1024" && o.clashRunning == true && o.egressIPs == [allowed])
        #expect(failures == ["transport": 1])
        #expect(verdict(o) == .healthy)
    }

    /// 本地探针超时：路由和 Clash 都是未知，绝不算「好」
    @Test func missedLocalIsUnknown() {
        let (o, _) = Guardd.merge(local: nil, egress: sample, egressEndpoints: 3)
        #expect(o.routeInterface == nil && o.clashRunning == nil)
        #expect(verdict(o) == .unknown)
    }

    /// 出口探针超时：没有 IP，每个回显服务都记一次 timeout
    @Test func missedEgressCountsEveryEndpointAsTimeout() {
        let (o, failures) = Guardd.merge(local: ("utun1024", true), egress: nil, egressEndpoints: 3)
        #expect(o.egressIPs.isEmpty)
        #expect(failures == ["timeout": 3])
        #expect(verdict(o) == .unknown)
    }
}

private struct StubPath: NetworkPathSource {
    var path: NetworkPath?
    var hang = false
    func current() async -> NetworkPath? {
        if hang { try? await Task.sleep(for: .seconds(30)) }
        return path
    }
}

/// 网络快照接进一轮：和其他探针并发，共用 8 秒截止
@Suite struct RoundNetworkPath {
    private let clock = ContinuousClock()
    private let down = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: false)
    private func probes(path: StubPath) -> Guardd.Probes {
        Guardd.Probes(route: { nil }, clash: { true }, path: path,
                      egress: EgressProbe(endpoints: [URL(string: "https://example.invalid")!], fetch: { _ in throw URLError(.notConnectedToInternet) }))
    }

    @Test func snapshotReachesTheRound() async {
        let r = await Guardd.observe(deadline: clock.now + .seconds(2), clock: clock, probes: probes(path: StubPath(path: down)))
        #expect(r.path == down)
        #expect(r.observation.clashRunning == true)
    }

    /// 快照卡住时按截止时间返回，不拖垮路由和 Clash 的结果；原因只能是 probeFailed
    @Test func stuckSnapshotIsCutByDeadline() async {
        let begin = clock.now
        let r = await Guardd.observe(deadline: begin + .milliseconds(200), clock: clock,
                                     probes: probes(path: StubPath(path: down, hang: true)))
        #expect(clock.now - begin < .seconds(2))
        #expect(r.path == nil)
        #expect(r.observation.clashRunning == true)
        #expect(UnknownReason.decide(verdict: .unknown, path: r.path) == .probeFailed)
    }

    /// unknown 的原因变了要重新通知 App（文字要换），所以通知的比较对象带着原因
    /// 日志和 `--once` 的输出永远不带 IP，哪怕状态文件里有 `egressIP`
    @Test func summaryAndVerdictLogNeverContainIPs() {
        let o = Observation(clashRunning: true, routeInterface: "en0", egressIPs: [IPv4("198.51.100.9")!, allowed])
        for v in [Verdict.healthy, .egressMismatch, .unknown, .violated] {
            let s = GuardState(verdict: v, observation: o, allowlist: [allowed], egressFailures: ["timeout": 1], networkPath: nil,
                               violatedSince: Date(timeIntervalSince1970: 1_800_000_000), checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
            #expect(s.egressIP != nil)
            let lines = [Guardd.summary(s), Guardd.Shown(verdict: s.verdict, unknownReason: s.unknownReason).description]
            for line in lines {
                #expect(line.firstMatch(of: /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/) == nil)
                #expect(!line.contains("egressIP"))
            }
        }
    }

    @Test func reasonChangeIsANewShownState() {
        #expect(Guardd.Shown(verdict: .unknown, unknownReason: .offline) != Guardd.Shown(verdict: .unknown, unknownReason: .probeFailed))
        #expect(Guardd.Shown(verdict: .unknown, unknownReason: .offline).description == "unknown(offline)")
        #expect(Guardd.Shown(verdict: .healthy, unknownReason: nil).description == "healthy")
    }
}
