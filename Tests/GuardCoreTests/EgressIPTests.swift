import Foundation
import Testing
@testable import GuardCore

// 测试只用 TEST-NET-3（203.0.113.0/24，RFC 5737）地址
private let allowedA = IPv4("203.0.113.10")!
private let allowedB = IPv4("203.0.113.11")!
private let outsideX = IPv4("203.0.113.9")!
private let outsideY = IPv4("203.0.113.200")!
private let allowlist: Set<IPv4> = [allowedA, allowedB]
private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)
private let down = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: false)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func obs(iface: String? = "utun4", ips: [IPv4]) -> Observation {
    Observation(clashRunning: true, routeInterface: iface, egressIPs: ips)
}

private func state(_ o: Observation, guard g: inout EgressGuard, path: NetworkPath? = up, at t: Date = t0) -> GuardState {
    let v = g.observe(o, allowlist: allowlist, at: t)
    return GuardState(verdict: v, observation: o, allowlist: allowlist, egressFailures: [:], networkPath: path,
                      violatedSince: g.violatedSince, checkedAt: t)
}

private func state(_ o: Observation, path: NetworkPath? = up) -> GuardState {
    var g = EgressGuard()
    return state(o, guard: &g, path: path)
}

/// 面板显示的出口 IP 和判定同源：guardd 把这一轮观测到的出口 IP 写进状态文件的 `egressIP`（完整地址，打不打码是 App 的事）
@Suite struct EgressIPInStateFile {
    @Test func healthyRoundWritesTheObservedIP() {
        let s = state(obs(ips: [allowedA, allowedA]))
        #expect(s.verdict == .healthy)
        #expect(s.egressIP == "203.0.113.10")
    }

    /// 出口不符时显示的是不在允许列表的那个，不是碰巧对上的那个
    @Test func mismatchPrefersTheIPOutsideTheAllowlist() {
        let s = state(obs(ips: [allowedA, outsideX, allowedB]))
        #expect(s.verdict == .egressMismatch)
        #expect(s.egressIP == "203.0.113.9")
    }

    /// 回显服务说法不一时：取出现次数最多的；一样多取数值最小的。和探针返回的先后顺序无关
    @Test func pickIsDeterministicRegardlessOfProbeOrder() {
        for ips in [[outsideY, outsideX, outsideY], [outsideX, outsideY, outsideY], [outsideY, outsideY, outsideX]] {
            #expect(obs(ips: ips).shownEgressIP(allowlist: allowlist) == outsideY)
        }
        for ips in [[outsideY, outsideX], [outsideX, outsideY]] {
            #expect(obs(ips: ips).shownEgressIP(allowlist: allowlist) == outsideX) // .9 < .200 按数值比，不按字符串
        }
        #expect(obs(ips: [allowedB, allowedA]).shownEgressIP(allowlist: allowlist) == allowedA)
    }

    /// 允许列表为空（配置问题）：verdict 是 unknown，但出口确实观测到了，照样写
    @Test func emptyAllowlistStillReportsTheObservedIP() {
        #expect(obs(ips: [outsideX]).shownEgressIP(allowlist: []) == outsideX)
    }

    /// 这一轮没观测到出口（断网、探针全失败或超时）就是 nil，键不写进文件
    @Test(arguments: [up, down, nil] as [NetworkPath?])
    func noObservedEgressWritesNil(_ path: NetworkPath?) throws {
        let s = state(obs(ips: []), path: path)
        #expect(s.verdict == .unknown)
        #expect(s.egressIP == nil)
        let json = try #require(String(data: s.encoded(), encoding: .utf8))
        #expect(!json.contains("egressIP"))
    }

    /// 绝不沿用上一轮的 IP：上一轮拿到了，这一轮探针失败，就写 nil
    @Test func neverCarriesOverThePreviousRoundsIP() {
        var g = EgressGuard()
        #expect(state(obs(ips: [allowedA]), guard: &g).egressIP == "203.0.113.10")
        #expect(state(obs(ips: []), guard: &g, at: t0.addingTimeInterval(5)).egressIP == nil)
    }

    /// 粘住的 violated 期间，IP 照样是这一轮的观测（verdict 粘，IP 不粘）
    @Test func stickyViolatedReportsThisRoundsIP() {
        var g = EgressGuard()
        let first = state(obs(iface: "en0", ips: [outsideX]), guard: &g)
        #expect(first.verdict == .violated && first.egressIP == "203.0.113.9")
        let sticky = state(obs(ips: [allowedA, outsideY]), guard: &g, at: t0.addingTimeInterval(5))
        #expect(sticky.verdict == .violated && sticky.egressIP == "203.0.113.200")
        let blind = state(obs(ips: []), guard: &g, at: t0.addingTimeInterval(10))
        #expect(blind.verdict == .violated && blind.egressIP == nil)
    }

    @Test func roundTrips() throws {
        for s in [state(obs(ips: [outsideX])), state(obs(ips: []))] {
            #expect(try GuardState.decode(s.encoded()) == s)
        }
    }

    /// 可选字段、不升格式版本：旧 guardd 写的文件没有这个键照样能解，解成 nil
    @Test func oldFileWithoutTheFieldDecodesAsNil() throws {
        let json = #"{"schemaVersion":1,"verdict":"healthy","checkedAt":"2027-01-15T08:00:00Z","egressFailures":{}}"#
        let s = try GuardState.decode(Data(json.utf8))
        #expect(s.egressIP == nil)
        #expect(s.schemaVersion == 1)
    }

    /// 只有 `egressIP` 这一个字段可以出现 IP；其余任何字段都不得出现点分四段
    @Test(arguments: [[allowedA, outsideX], [outsideY], []])
    func onlyEgressIPCarriesAnIP(_ ips: [IPv4]) throws {
        let s = state(obs(iface: "en0", ips: ips))
        var object = try #require(JSONSerialization.jsonObject(with: s.encoded()) as? [String: Any])
        let ip = object.removeValue(forKey: "egressIP") as? String
        #expect(ip.flatMap(IPv4.init)?.description == ip) // 有的话一定是合法的完整 IPv4
        #expect((ip == nil) == ips.isEmpty)
        let rest = try #require(String(data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8))
        #expect(rest.firstMatch(of: /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/) == nil)
        #expect(!rest.contains("203.0.113"))
    }
}

/// App 只在文件新鲜时显示 IP；过期、时钟跳变、读不了一律 nil（界面显示「—」），绝不显示旧 IP
@Suite struct EgressIPInDisplay {
    private let now = t0

    private func file(_ ips: [IPv4], iface: String = "utun4", age: TimeInterval = 0, schema: Int = 1) throws -> Data {
        var g = EgressGuard()
        var s = state(obs(iface: iface, ips: ips), guard: &g, at: now.addingTimeInterval(-age))
        s.schemaVersion = schema
        return try s.encoded()
    }

    private func read(_ data: Data?) -> GuardDisplay { GuardStateReader.display(data: data, now: now) }

    @Test func freshFileShowsTheIP() throws {
        let d = read(try file([allowedA]))
        #expect(d.reason == .fresh && d.verdict == .healthy)
        #expect(d.egressIP == "203.0.113.10")
        #expect(read(try file([outsideX], iface: "en0")).egressIP == "203.0.113.9")
    }

    @Test func freshFileWithoutIPShowsNil() throws {
        #expect(read(try file([])).egressIP == nil)
    }

    /// guardd 不响应时红卡可以靠 lastVerdict 保留，但 IP 不保留
    @Test func staleFileHidesTheIPButKeepsLastVerdict() throws {
        let d = read(try file([outsideX], iface: "en0", age: 16))
        #expect(d.reason == .stale && d.lastVerdict == .violated)
        #expect(d.egressIP == nil)
    }

    @Test func clockSkewHidesTheIP() throws {
        let d = read(try file([outsideX], iface: "en0", age: -6))
        #expect(d.reason == .clockSkew && d.lastVerdict == .violated)
        #expect(d.egressIP == nil)
    }

    @Test func newerSchemaMissingAndUnreadableHaveNoIP() throws {
        #expect(read(try file([allowedA], schema: 2)).egressIP == nil)
        #expect(read(nil).egressIP == nil)
        #expect(read(Data("{not json".utf8)).egressIP == nil)
    }

    /// 文件是外部数据：`egressIP` 不是合法 IPv4 就当没有，不把乱码交给界面；其余照常显示
    @Test func malformedIPIsDropped() throws {
        let json = #"{"schemaVersion":1,"verdict":"healthy","checkedAt":"2027-01-15T08:00:00Z","egressFailures":{},"egressIP":"not-an-ip"}"#
        let checkedAt = try #require(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let d = GuardStateReader.display(data: Data(json.utf8), now: checkedAt)
        #expect(d.reason == .fresh && d.verdict == .healthy)
        #expect(d.egressIP == nil)
    }
}
