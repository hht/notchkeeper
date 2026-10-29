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
        let o = Observation(clashRunning: true, routeInterface: "en0", egressIPs: [IPv4("198.51.100.9")!])
        try StateFile.write(GuardState(verdict: .violated, observation: o, allowlist: [allowed], egressFailures: [:], networkPath: nil,
                                       violatedSince: t0, checkedAt: t0).encoded(), to: url)
        #expect(try GuardState.decode(Data(contentsOf: url)).egressIP == "198.51.100.9") // 上一份确实带了 IP
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
        var logged: [String] = []
        #expect(Guardd.resumedGuard(stateURL: try scratch(), log: { logged.append($0) }).verdict == .unknown)
        #expect(logged.isEmpty)
    }

    /// 文件在但读不出来（这里用同名目录模拟）：拿不到证据，不能凭空判 violated，从 unknown 开始；但要记一行，不能悄悄吞掉
    @Test func unreadablePreviousFileStartsFreshAndIsLogged() throws {
        let url = try scratch()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var logged: [String] = []
        #expect(Guardd.resumedGuard(stateURL: url, log: { logged.append($0) }).verdict == .unknown)
        #expect(logged.count == 1)
    }

    /// 解不开或格式版本不同：同样从 unknown 开始并记一行，不能当成「没有上一份」悄悄吞掉
    @Test(arguments: [Data("{not json".utf8), nil])
    func undecodablePreviousFileStartsFreshAndIsLogged(_ data: Data?) throws {
        let url = try scratch()
        if let data {
            try data.write(to: url)
        } else {
            var s = try GuardState.decode(GuardState(verdict: .violated, observation: Observation(clashRunning: true, routeInterface: "en0", egressIPs: []),
                                                     allowlist: [allowed], egressFailures: [:], networkPath: nil,
                                                     violatedSince: t0, checkedAt: t0).encoded())
            s.schemaVersion = 2
            try JSONEncoder().encode(s).write(to: url)
        }
        var logged: [String] = []
        #expect(Guardd.resumedGuard(stateURL: url, log: { logged.append($0) }).verdict == .unknown)
        #expect(logged.count == 1)
    }
}
