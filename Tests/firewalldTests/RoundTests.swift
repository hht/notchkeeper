import Foundation
import Testing
import FirewallCore
@testable import firewalld

@Suite struct Round {
    @Test func enableThenRoundLoadsRulesAndHoldsOneReference() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        let status = try #require(rig.round())
        #expect(rig.pf.anchor == rig.rules.text)
        #expect(rig.pf.references == ["1864012227745836441"])
        guard case .valid(let s) = rig.state else { Issue.record("防火墙状态文件读不出"); return }
        #expect(s.reference == .held(token: "1864012227745836441"))
        #expect(status.mode == .trial)
        #expect(status.check?.passed == true)
        #expect(rig.status == status)
    }

    /// 稳态不再 -E、不重装：引用数不涨、Evaluations 不归零
    @Test func steadyRoundsNeitherReEnableNorReload() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        _ = rig.round()
        rig.seconds += 10
        let status = try #require(rig.round())
        #expect(rig.pf.references.count == 1)
        #expect(rig.pf.calls.filter { $0.contains("-f") }.count == 1)
        #expect(status.check?.evaluationsGrowing == true)
    }

    /// 拿到 token 就落盘：-E 之后的下一步（再读一次引用列表）之前，防火墙状态文件里已经有它。
    /// 恢复脚本 bootout 时正好杀在这一步，也找得到这个 token 去释放
    @Test func tokenIsOnDiskBeforeTheNextStep() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        var next: [String]?
        var seen: FirewallState.Restored?
        rig.pf.onCall = { call in
            if next == nil, rig.pf.calls.last == ["/sbin/pfctl", "-E"] { (next, seen) = (call, rig.state) }
        }
        _ = rig.round()
        #expect(next == ["/sbin/pfctl", "-s", "References"])
        guard case .valid(let s) = seen else { Issue.record("下一步时防火墙状态文件读不出"); return }
        #expect(s.reference == .held(token: "1864012227745836441"))
    }

    /// 防火墙状态文件坏了：按 off 办（清掉残留规则），不覆盖原文件，摘要里报出来
    @Test func unreadableStateIsTreatedAsOffAndKept() throws {
        let rig = try Rig()
        let url = rig.directory.appendingPathComponent(FirewallState.fileName)
        try Data("garbage".utf8).write(to: url)
        rig.pf.anchor = "pass all\n"
        let status = try #require(rig.round())
        #expect(rig.pf.anchor == "")
        #expect(try Data(contentsOf: url) == Data("garbage".utf8))
        #expect(status.mode == .stateUnreadable)
    }

    /// 做失败的动作报进摘要，下一轮重做
    @Test func failedActionIsReportedAndRetried() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        rig.pf.failing = "-E"
        #expect(rig.round()?.failedSteps == [.enable])
        #expect(rig.pf.references.isEmpty)
        rig.pf.failing = nil
        rig.seconds += 10
        #expect(rig.round()?.failedSteps == [])
        #expect(rig.pf.references.count == 1)
    }

    @Test func disableFlushesAndReleases() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        _ = rig.round()
        try Helper.command(.disable, rig.system)
        let status = try #require(rig.round())
        #expect(rig.pf.anchor == "")
        #expect(rig.pf.references.isEmpty)
        #expect(status.mode == .off)
        #expect(status.check == nil)
    }

    /// 到期回滚由一轮执行，不靠 App；过期后点保留被拒
    @Test func expiredTrialRollsBackAndCannotBeKept() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        _ = rig.round()
        rig.seconds += 120
        #expect(throws: Helper.Failure.command(.notInTrial)) { try Helper.command(.keep, rig.system) }
        let status = try #require(rig.round())
        #expect(status.mode == .off)
        #expect(rig.pf.anchor == "")
        #expect(rig.pf.references.isEmpty)
    }

    @Test func trialShowsWhenItEnds() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        rig.seconds += 30
        #expect(rig.round()?.trialEndsAt == rig.system.now().addingTimeInterval(90))
    }

    /// 命令只改防火墙状态文件，再让守护进程马上跑一轮
    @Test func commandsKickstartTheDaemon() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        #expect(rig.pf.calls == [["/bin/launchctl", "kickstart", "system/com.notchkeeper.firewall"]])
    }

    /// 防火墙状态文件只有 root 可读（里面有 token）；摘要给 App 读
    @Test func filePermissions() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        _ = rig.round()
        func mode(_ name: String) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: rig.directory.appendingPathComponent(name).path)[.posixPermissions] as? Int
        }
        #expect(try mode(FirewallState.fileName) == 0o600)
        #expect(try mode(FirewallStatus.fileName) == 0o644)
    }

    /// 有人 pfctl -d：引用全作废、pf 停了。下一轮看出我们的 token 不在了，重新 -E，核对又过
    @Test func recoversAfterSomeoneDisablesPF() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        _ = rig.round()
        rig.pf.references = []
        rig.pf.enabled = false
        rig.seconds += 10
        let status = try #require(rig.round())
        #expect(rig.pf.references.count == 1)
        #expect(status.check?.pfEnabled == true)
    }

    /// -E 给的号码在引用列表里找不到（格式对不上）：只拿一个引用，不每轮多拿
    @Test func unlistedTokenIsNotReEnabledEveryRound() throws {
        let rig = try Rig()
        rig.pf.listsOurReferences = false
        try Helper.command(.enable, rig.system)
        _ = rig.round()
        rig.seconds += 10
        _ = rig.round()
        #expect(rig.pf.references.count == 1)
    }

    /// 锁被占着（另一轮或命令卡住）：等到上限就放弃，什么都不改
    @Test func givesUpWhenTheLockIsHeld() throws {
        let rig = try Rig()
        rig.lockTimeout = 0.2
        let fd = open(rig.directory.appendingPathComponent(FirewallPaths.lockFile).path, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX) == 0)
        #expect(throws: Helper.Failure.busy) { try Helper.command(.enable, rig.system) }
        #expect(rig.round() == nil)
        #expect(rig.state == .missing)
        #expect(rig.pf.calls.isEmpty)
    }

    /// 坏掉的防火墙状态文件谁都不覆盖：开启被拒（先跑恢复脚本）；关闭照样算成功（每一轮本来就按 off 办）
    @Test func commandsDoNotOverwriteAnUnreadableState() throws {
        let rig = try Rig()
        let url = rig.directory.appendingPathComponent(FirewallState.fileName)
        try Data("garbage".utf8).write(to: url)
        #expect(throws: Helper.Failure.stateUnreadable) { try Helper.command(.enable, rig.system) }
        try Helper.command(.disable, rig.system)
        #expect(try Data(contentsOf: url) == Data("garbage".utf8))
    }

    @Test func releaseFailureIsRetried() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        _ = rig.round()
        try Helper.command(.disable, rig.system)
        rig.pf.failing = "-X"
        #expect(rig.round()?.failedSteps == [.release])
        rig.pf.failing = nil
        #expect(rig.round()?.failedSteps == [])
        #expect(rig.pf.references.isEmpty)
    }

    /// 摘要写明装的是哪种规则：测试规则不能让 App 显示「已保护」
    @Test func statusSaysWhichRules() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        #expect(rig.round(scope: .testUser)?.scope == .testUser)
        #expect(rig.pf.anchor == FirewallRules(tunnel: "utun1024", scope: .testUser)?.text)
    }

    /// 读不出开机标识：开启报错、说得出原因；一轮照常按 off 办，防火墙状态文件里不写开机标识
    @Test func unreadableBootSession() throws {
        let rig = try Rig()
        rig.bootSession = nil
        #expect(throws: Helper.Failure.command(.bootSessionUnknown)) { try Helper.command(.enable, rig.system) }
        rig.pf.anchor = "pass all\n"
        #expect(rig.round()?.mode == .off)
        #expect(rig.pf.anchor == "")
        guard case .valid(let s) = rig.state else { Issue.record("防火墙状态文件读不出"); return }
        #expect(s.bootSession == nil)
    }

    /// 换规则那轮装失败：anchor 里还是旧规则，摘要不能说成新规则
    @Test func statusHasNoScopeWhenTheseRulesAreNotLoaded() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        _ = rig.round(scope: .testUser)
        rig.pf.failing = "-f"
        rig.seconds += 10
        #expect(rig.round(scope: .everyone)?.scope == nil)
    }

    /// 防火墙状态文件写不进去时不 -E：拿到的 token 记不下来，下一轮又会 -E，引用越涨越多
    @Test func doesNotEnableWhenStateCannotBeSaved() throws {
        let rig = try Rig()
        try Helper.command(.enable, rig.system)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.directory.path) }
        #expect(rig.round()?.failedSteps == [.enable])
        #expect(rig.pf.references.isEmpty)
    }
}

@Suite struct Arguments {
    @Test func productionRules() {
        let c = Firewalld.roundConfig(["round", "--tunnel", "utun1024"])
        #expect(c?.scope == .everyone)
        #expect(c?.rules == FirewallRules(tunnel: "utun1024"))
    }

    @Test func testRules() {
        #expect(Firewalld.roundConfig(["round", "--tunnel", "utun1024", "--test-rules"])?.scope == .testUser)
    }

    @Test(arguments: [[], ["round"], ["round", "--tunnel"], ["round", "--tunnel", "utun 1"], ["round", "--tunnel", "utun1024", "--extra"],
                      ["round", "--tunnel", "utun1024", "--test-rules", "x"], ["--tunnel", "utun1024", "round"]])
    func rejects(_ args: [String]) {
        #expect(Firewalld.roundConfig(args) == nil)
    }
}
