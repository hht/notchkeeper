import Foundation
import Testing
@testable import GuardCore

private let allowed = IPv4("198.51.100.8")!
private let leaked = IPv4("1.2.3.4")!
private let allowlist: Set<IPv4> = [allowed]
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func state(clash: Bool? = true, iface: String? = "utun1024", ips: [IPv4] = [allowed],
                   allowlist: Set<IPv4> = allowlist, failures: [String: Int] = [:]) -> GuardState {
    let o = Observation(clashRunning: clash, routeInterface: iface, egressIPs: ips)
    var g = EgressGuard()
    return GuardState(verdict: g.observe(o, allowlist: allowlist), observation: o, allowlist: allowlist,
                      egressFailures: failures, networkPath: NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true),
                      checkedAt: t0)
}

@Suite struct GuardStateSnapshot {
    @Test func roundTrips() throws {
        for s in [state(), state(clash: nil, iface: nil, ips: [], failures: ["timeout": 2, "transport": 1]),
                  state(iface: "en0", ips: [leaked])] {
            let decoded = try GuardState.decode(s.encoded())
            #expect(decoded == s)
        }
    }

    /// App 按字符串读 verdict，名字就是文件格式的一部分
    @Test func verdictIsEncodedByName() throws {
        let json = try #require(String(data: state(ips: [leaked]).encoded(), encoding: .utf8))
        #expect(json.contains(#""verdict":"egressMismatch""#))
        #expect(json.contains(#""schemaVersion":1"#))
    }

    /// 状态文件只有 `egressIP` 一个字段可以带 IP（面板显示用，文件 0600、不是日志）；其余字段只留布尔值。
    /// 更细的正反向断言见 EgressIPTests 的 `onlyEgressIPCarriesAnIP`
    @Test func onlyEgressIPFieldContainsAnIP() throws {
        var object = try #require(JSONSerialization.jsonObject(with: state(ips: [allowed, leaked]).encoded()) as? [String: Any])
        #expect(object.removeValue(forKey: "egressIP") as? String == leaked.description)
        let rest = try #require(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        #expect(rest.firstMatch(of: /\d+\.\d+\.\d+\.\d+/) == nil)
    }

    @Test func summarizesSignals() {
        let s = state()
        #expect(s.verdict == .healthy)
        #expect(s.clashRunning == true && s.routeOnTunnel == true && s.egressMatches == true)
        #expect(state(iface: "en0").routeOnTunnel == false)
        #expect(state(iface: nil).routeOnTunnel == nil)
        #expect(state(ips: [allowed, leaked]).egressMatches == false)
    }

    /// 没拿到 IP、或允许列表为空，都是「不知道」，不是「对上了」
    @Test func egressMatchIsUnknownWithoutEvidence() {
        #expect(state(ips: []).egressMatches == nil)
        #expect(state(ips: [leaked], allowlist: []).egressMatches == nil)
    }
}

@Suite struct PollScheduling {
    private let start = ContinuousClock.now
    private func next(roundTook d: Duration) -> ContinuousClock.Instant {
        PollSchedule.nextRoundStart(lastStart: start, lastEnd: start + d, interval: PollSchedule.interval)
    }

    @Test func intervalIsFiveSeconds() { #expect(PollSchedule.interval == .seconds(5)) }
    @Test func shortRoundWaitsForInterval() { #expect(next(roundTook: .seconds(1)) == start + .seconds(5)) }
    /// 一轮超过间隔（出口探针最长 6 秒）时紧接着开下一轮，不重叠、也不补跑
    @Test func longRoundStartsRightAfter() { #expect(next(roundTook: .seconds(7)) == start + .seconds(7)) }
    @Test func neverStartsBeforeLastEnd() {
        for d in [Duration.zero, .milliseconds(4999), .seconds(5), .seconds(6), .seconds(30)] {
            #expect(next(roundTook: d) >= start + d)
        }
    }
}
