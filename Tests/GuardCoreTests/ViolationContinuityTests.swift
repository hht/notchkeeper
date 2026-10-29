import Foundation
import Testing
@testable import GuardCore

/// guardd 停了、重启了、用户关了红卡，违规都不能「悄悄消失」：
/// - `GuardDisplay.lastVerdict`：过期 / 时钟跳变时也给出文件里最后的 verdict，App 据此保留红卡（只看这一次读到的，不靠内存历史）。
/// - `violatedSince`：一次违规从开始到被 healthy 解除的固定标识，App 用它记「用户关掉了哪一次」。
/// - `EgressGuard(resuming:)`：重启后从上一份 violated 文件接续粘性，只有 healthy 能解除。

private let allowed = IPv4("198.51.100.8")!
private let leaked = IPv4("1.2.3.4")!
private let allowlist: Set<IPv4> = [allowed]
private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let now = t0

private let healthy = Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [allowed])
private let routeOff = Observation(clashRunning: true, routeInterface: "en0", egressIPs: [allowed])
private let probesFail = Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [])
private let mismatch = Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [leaked])

private func file(_ v: Verdict, age: TimeInterval = 0, since: Date? = nil, schema: Int = 1) throws -> Data {
    var s = GuardState(verdict: v, observation: probesFail, allowlist: allowlist, egressFailures: [:], networkPath: up,
                       violatedSince: since, checkedAt: now.addingTimeInterval(-age))
    s.schemaVersion = schema
    return try s.encoded()
}
private func read(_ d: Data?) -> GuardDisplay { GuardStateReader.display(data: d, now: now) }

@Suite struct LastVerdict {
    /// 新鲜时 lastVerdict 就是 verdict（同一个「文件里写的是什么」，App 不用分情况）
    @Test(arguments: [Verdict.healthy, .egressMismatch, .unknown, .violated])
    func freshLastVerdictIsTheVerdict(_ v: Verdict) throws {
        let d = read(try file(v, age: 3))
        #expect(d.reason == .fresh && d.verdict == v && d.lastVerdict == v)
    }

    /// 过期：显示 unknown、原因照旧 stale，但带出最后的 verdict
    @Test(arguments: [Verdict.violated, .healthy, .egressMismatch, .unknown])
    func staleKeepsTheLastVerdict(_ v: Verdict) throws {
        let d = read(try file(v, age: 16))
        #expect(d.verdict == .unknown && d.reason == .stale && d.unknownReason == nil)
        #expect(d.lastVerdict == v)
    }

    @Test func clockSkewKeepsTheLastVerdict() throws {
        let d = read(try file(.violated, age: -6))
        #expect(d.verdict == .unknown && d.reason == .clockSkew && d.lastVerdict == .violated)
    }

    /// 恰好 15 秒仍新鲜（显示 violated），16 秒过期（unknown + lastVerdict violated）
    @Test func boundaryAtFifteenSeconds() throws {
        let at15 = read(try file(.violated, age: 15))
        #expect(at15.reason == .fresh && at15.verdict == .violated && at15.lastVerdict == .violated)
        let at16 = read(try file(.violated, age: 16))
        #expect(at16.reason == .stale && at16.verdict == .unknown && at16.lastVerdict == .violated)
    }

    /// 没有可信的文件内容就没有 lastVerdict
    @Test func noLastVerdictWithoutAReadableFile() throws {
        #expect(read(nil).lastVerdict == nil)
        #expect(read(Data("{not json".utf8)).lastVerdict == nil)
        #expect(read(try file(.violated, schema: 2)).lastVerdict == nil)
    }
}

@Suite struct ViolatedSince {
    private func run(_ steps: [(Observation, TimeInterval)], start g: EgressGuard = EgressGuard()) -> [(Verdict, Date?)] {
        var g = g
        return steps.map { o, t in
            let v = g.observe(o, allowlist: allowlist, at: t0.addingTimeInterval(t))
            return (v, g.violatedSince)
        }
    }

    @Test func setOnFirstViolatedRoundAndUnchangedWhileSticky() {
        let r = run([(healthy, 0), (routeOff, 5), (probesFail, 10), (mismatch, 15), (routeOff, 20)])
        #expect(r.map(\.0) == [.healthy, .violated, .violated, .violated, .violated])
        #expect(r[0].1 == nil)
        #expect(r.dropFirst().allSatisfy { $0.1 == t0.addingTimeInterval(5) })
    }

    @Test func clearedOnReleaseAndANewViolationGetsANewValue() {
        let r = run([(routeOff, 0), (healthy, 5), (mismatch, 10), (probesFail, 15), (routeOff, 20)])
        #expect(r.map(\.0) == [.violated, .healthy, .egressMismatch, .unknown, .violated])
        #expect(r.map(\.1) == [t0, nil, nil, nil, t0.addingTimeInterval(20)])
    }

    /// 文件里只有 violated 带 violatedSince；别的 verdict 传进来也不写
    @Test func onlyViolatedStatesCarryIt() throws {
        let violated = try GuardState.decode(file(.violated, since: t0))
        #expect(violated.violatedSince == t0)
        for v in [Verdict.healthy, .egressMismatch, .unknown] {
            let s = try GuardState.decode(file(v, since: t0))
            #expect(s.violatedSince == nil)
            #expect(!String(decoding: try file(v, since: t0), as: UTF8.self).contains("violatedSince"))
        }
    }

    @Test func readerExposesItForFreshAndStaleViolated() throws {
        let since = t0.addingTimeInterval(-600)
        #expect(read(try file(.violated, age: 3, since: since)).violatedSince == since)
        #expect(read(try file(.violated, age: 16, since: since)).violatedSince == since)
        #expect(read(try file(.violated, age: -6, since: since)).violatedSince == since)
    }

    /// 非 violated 的文件就算手改带了这个键，读出来也丢掉
    @Test func readerDropsItForOtherVerdicts() {
        for v in ["healthy", "egressMismatch", "unknown"] {
            let odd = #"{"schemaVersion":1,"verdict":"\#(v)","violatedSince":"2027-01-15T07:00:00Z","checkedAt":"2027-01-15T08:00:00Z","egressFailures":{}}"#
            let d = GuardStateReader.display(data: Data(odd.utf8), now: ISO8601DateFormatter().date(from: "2027-01-15T08:00:03Z")!)
            #expect(d.violatedSince == nil)
            let stale = GuardStateReader.display(data: Data(odd.utf8), now: ISO8601DateFormatter().date(from: "2027-01-15T08:01:00Z")!)
            #expect(stale.violatedSince == nil)
        }
    }
}

@Suite struct ResumeAfterRestart {
    private func resumed(_ d: Data?) -> EgressGuard { EgressGuard(resuming: d.flatMap { try? GuardState.decode($0) }) }

    /// 重启后第一轮是 unknown / 出口不符：仍然 violated，violatedSince 保持原值；healthy 才解除
    @Test func violatedFileSeedsStickinessAndKeepsViolatedSince() throws {
        let since = t0.addingTimeInterval(-3600)
        for first in [probesFail, mismatch] {
            var g = resumed(try file(.violated, since: since))
            #expect(g.verdict == .violated && g.violatedSince == since)
            #expect(g.observe(first, allowlist: allowlist, at: t0) == .violated)
            #expect(g.violatedSince == since)
            #expect(g.observe(healthy, allowlist: allowlist, at: t0.addingTimeInterval(5)) == .healthy)
            #expect(g.violatedSince == nil)
        }
    }

    /// 不看新旧：guardd 停了一天再起来，violated 也要接续（只有 healthy 能解除）
    @Test func seedsRegardlessOfAge() throws {
        var g = resumed(try file(.violated, age: 86_400, since: t0.addingTimeInterval(-90_000)))
        #expect(g.observe(probesFail, allowlist: allowlist, at: t0) == .violated)
    }

    /// 文件是外部数据：violated 缺 violatedSince 时用那份文件的 checkedAt 作为起点（固定值，不随每轮变）
    @Test func violatedFileWithoutSinceUsesItsCheckedAt() throws {
        let g = resumed(try file(.violated, age: 30))
        #expect(g.verdict == .violated && g.violatedSince == now.addingTimeInterval(-30))
    }

    /// 只从 violated 接续：别的 verdict、解不开、缺失、格式版本不同都从头开始（unknown，没有 violatedSince）
    @Test func seedsFromNothingElse() throws {
        var inputs: [Data?] = [nil, Data("{not json".utf8), try file(.violated, since: t0, schema: 2)]
        for v in [Verdict.healthy, .egressMismatch, .unknown] { inputs.append(try file(v)) }
        for d in inputs {
            var g = resumed(d)
            #expect(g.verdict == .unknown && g.violatedSince == nil)
            #expect(g.observe(probesFail, allowlist: allowlist, at: t0) == .unknown)
        }
    }

    @Test func freshGuardStartsUnknown() {
        let g = EgressGuard()
        #expect(g.verdict == .unknown && g.violatedSince == nil)
    }
}
