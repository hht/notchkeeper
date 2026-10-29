import Foundation
import Testing
import GuardCore
@testable import guardd

/// KeepAlive 会重启 guardd。粘性如果只在内存里，重启后第一轮 unknown / 出口不符就会把 violated 文件覆盖掉，红卡悄悄消失。
@Suite struct RestartResume {
    private let allowed = IPv4("198.51.100.8")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("guardd-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("guard-state.json")
    }

    private func write(_ v: Verdict, since: Date?, to url: URL) throws {
        let o = Observation(clashRunning: true, routeInterface: v == .violated ? "en0" : "utun4", egressIPs: [allowed])
        try StateFile.write(GuardState(verdict: v, observation: o, allowlist: [allowed], egressFailures: [:], networkPath: nil,
                                       violatedSince: since, checkedAt: t0).encoded(), to: url)
    }

    @Test func restartAfterViolatedKeepsItThroughAnUnknownFirstRound() throws {
        let url = try scratch()
        try write(.violated, since: t0, to: url)
        var g = Guardd.resumedGuard(stateURL: url)
        let probesFail = Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [])
        #expect(g.observe(probesFail, allowlist: [allowed], at: t0.addingTimeInterval(60)) == .violated)
        #expect(g.violatedSince == t0)
    }

    /// 重启只接续粘性和 violatedSince，不接续 IP：重启后第一轮探针失败，文件里的 egressIP 是 nil，不是上一份的
    @Test func restartDoesNotResumeTheEgressIP() throws {
        let url = try scratch()
        let o = Observation(clashRunning: true, routeInterface: "en0", egressIPs: [IPv4("203.0.113.9")!])
        try StateFile.write(GuardState(verdict: .violated, observation: o, allowlist: [allowed], egressFailures: [:], networkPath: nil,
                                       violatedSince: t0, checkedAt: t0).encoded(), to: url)
        #expect(GuardState.resumable(from: try Data(contentsOf: url))?.egressIP == "203.0.113.9") // 上一份确实带了 IP
        var g = Guardd.resumedGuard(stateURL: url)
        let probesFail = Observation(clashRunning: true, routeInterface: "utun4", egressIPs: [])
        let t1 = t0.addingTimeInterval(60)
        let v = g.observe(probesFail, allowlist: [allowed], at: t1)
        let next = GuardState(verdict: v, observation: probesFail, allowlist: [allowed], egressFailures: [:], networkPath: nil,
                              violatedSince: g.violatedSince, checkedAt: t1)
        #expect(next.verdict == .violated && next.violatedSince == t0)
        #expect(next.egressIP == nil)
    }

    @Test func restartAfterHealthyStartsFresh() throws {
        let url = try scratch()
        try write(.healthy, since: nil, to: url)
        #expect(Guardd.resumedGuard(stateURL: url).verdict == .unknown)
    }

    @Test func noPreviousFileStartsFresh() throws {
        #expect(Guardd.resumedGuard(stateURL: try scratch()).verdict == .unknown)
    }
}
