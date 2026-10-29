import Foundation
import Testing
@testable import GuardCore

private let up = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true)
private let noInterface = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: true)
private let noRoute = NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: false)
private let nothing = NetworkPath(physicalInterfaceSatisfied: false, hasDefaultRoute: false)
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let unknownRound = Observation(clashRunning: true, routeInterface: nil, egressIPs: [])

@Suite struct UnknownReasonDecision {
    @Test(arguments: [noInterface, noRoute, nothing])
    func offlineWhenNoPhysicalInterfaceOrNoDefaultRoute(_ p: NetworkPath) {
        #expect(!p.isUp)
        #expect(UnknownReason.decide(verdict: .unknown, path: p) == .offline)
    }

    @Test func probeFailedWhenNetworkIsUp() {
        #expect(up.isUp)
        #expect(UnknownReason.decide(verdict: .unknown, path: up) == .probeFailed)
    }

    /// 没拿到网络快照（监视器还没回话或超时）不能断言「断网」，只能说探针没结果
    @Test func noSnapshotIsProbeFailed() { #expect(UnknownReason.decide(verdict: .unknown, path: nil) == .probeFailed) }

    /// 优先级：断网时探针必然也失败，原因报 offline
    @Test func offlineBeatsProbeFailed() {
        var g = EgressGuard()
        #expect(g.observe(Observation(clashRunning: nil, routeInterface: nil, egressIPs: []), allowlist: []) == .unknown)
        #expect(UnknownReason.decide(verdict: .unknown, path: nothing) == .offline)
    }

    @Test(arguments: [Verdict.healthy, .egressMismatch, .violated])
    func onlyUnknownCarriesAReason(_ v: Verdict) {
        for p in [up, noInterface, noRoute, nothing, nil] as [NetworkPath?] {
            #expect(UnknownReason.decide(verdict: v, path: p) == nil)
        }
    }
}

@Suite struct UnknownReasonInStateFile {
    private func state(_ v: Verdict, path: NetworkPath?) -> GuardState {
        GuardState(verdict: v, observation: unknownRound, allowlist: [], egressFailures: [:], networkPath: path, checkedAt: now)
    }

    @Test func unknownWritesTheReason() throws {
        let json = String(decoding: try state(.unknown, path: nothing).encoded(), as: UTF8.self)
        #expect(json.contains(#""unknownReason":"offline""#))
        #expect(try GuardState.decode(state(.unknown, path: up).encoded()).unknownReason == .probeFailed)
    }

    @Test(arguments: [Verdict.healthy, .egressMismatch, .violated])
    func otherVerdictsWriteNoReason(_ v: Verdict) throws {
        let s = state(v, path: nothing)
        #expect(s.unknownReason == nil)
        #expect(!String(decoding: try s.encoded(), as: UTF8.self).contains("unknownReason"))
    }

    /// 新增的是可选字段，格式版本不升：旧文件照样读，旧 App 读新文件也只是忽略这个键
    @Test func oldFileWithoutFieldStillDecodes() throws {
        #expect(GuardState.currentSchemaVersion == 1)
        let old = #"{"schemaVersion":1,"verdict":"unknown","checkedAt":"2027-01-15T08:00:00Z","egressFailures":{}}"#
        let s = try GuardState.decode(Data(old.utf8))
        #expect(s.verdict == .unknown && s.unknownReason == nil)
    }

    @Test func roundTrips() throws {
        for s in [state(.unknown, path: nothing), state(.unknown, path: up), state(.healthy, path: up)] {
            #expect(try GuardState.decode(s.encoded()) == s)
        }
    }
}

@Suite struct UnknownReasonDisplay {
    private func file(_ v: Verdict, path: NetworkPath?, age: TimeInterval = 0) throws -> Data {
        try GuardState(verdict: v, observation: unknownRound, allowlist: [], egressFailures: [:], networkPath: path,
                       checkedAt: now.addingTimeInterval(-age)).encoded()
    }
    private func read(_ d: Data?) -> GuardDisplay { GuardStateReader.display(data: d, now: now) }

    @Test func freshUnknownExposesTheReason() throws {
        #expect(read(try file(.unknown, path: nothing)).unknownReason == .offline)
        #expect(read(try file(.unknown, path: up)).unknownReason == .probeFailed)
        #expect(read(try file(.unknown, path: up)).reason == .fresh)
    }

    /// 旧 guardd 写的 unknown 没有 unknownReason：按 probeFailed 显示
    @Test func freshUnknownFromOldGuarddIsProbeFailed() {
        let old = #"{"schemaVersion":1,"verdict":"unknown","checkedAt":"2027-01-15T08:00:00Z","egressFailures":{}}"#
        let d = GuardStateReader.display(data: Data(old.utf8), now: ISO8601DateFormatter().date(from: "2027-01-15T08:00:03Z")!)
        #expect(d == GuardDisplay(verdict: .unknown, checkedAt: ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"),
                                  reason: .fresh, unknownReason: .probeFailed, lastVerdict: .unknown))
    }

    /// 文件里 healthy 却带了 unknownReason（手改或格式错误）：不显示原因
    @Test func reasonIsDroppedForOtherVerdicts() {
        let odd = #"{"schemaVersion":1,"verdict":"healthy","unknownReason":"offline","checkedAt":"2027-01-15T08:00:00Z","egressFailures":{}}"#
        let d = GuardStateReader.display(data: Data(odd.utf8), now: ISO8601DateFormatter().date(from: "2027-01-15T08:00:03Z")!)
        #expect(d.verdict == .healthy && d.unknownReason == nil)
    }

    /// App 侧原因（过期、缺失、时钟跳变、解不开、新格式）不带 guardd 的原因，文字走「守卫没有响应」
    @Test func appSideReasonsCarryNoGuarddReason() throws {
        #expect(read(try file(.unknown, path: nothing, age: 16)).unknownReason == nil)
        #expect(read(try file(.unknown, path: nothing, age: 16)).reason == .stale)
        #expect(read(try file(.unknown, path: nothing, age: -6)).unknownReason == nil)
        #expect(read(nil).unknownReason == nil)
        #expect(read(Data("{".utf8)).unknownReason == nil)
    }
}
