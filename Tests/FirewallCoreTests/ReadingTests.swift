import Foundation
import Testing
@testable import FirewallCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let passed = FirewallCheck(pfEnabled: true, anchorPointPresent: true, rulesLoaded: true, evaluations: 10, evaluationsGrowing: true, tunnelPresent: true)
private let noTunnel = FirewallCheck(pfEnabled: true, anchorPointPresent: true, rulesLoaded: true, evaluations: 10, evaluationsGrowing: true, tunnelPresent: false)

private func read(_ mode: FirewallStatus.Mode, scope: FirewallRules.Scope? = .everyone, check: FirewallCheck? = passed, ago: TimeInterval = 5,
                  trialEndsAt: Date? = nil, failed: [PFStep] = []) -> FirewallReading {
    FirewallReading(installed: true, summary: .read(FirewallStatus(mode: mode, scope: scope, trialEndsAt: trialEndsAt, check: check,
                                                                   failedSteps: failed, checkedAt: now.addingTimeInterval(-ago))), now: now)
}

/// App 只信新鲜的状态摘要；只有正式规则、核对全过的 on 才算「已保护」（docs/firewall.md §2、§4）
@Suite struct FirewallReadingRules {
    @Test func protectedOnlyWhenOnFreshOfficialAndChecked() {
        #expect(read(.on) == .on(problem: nil))
        #expect(read(.on, scope: .testTable) == .on(problem: .testRules))
        // scope 是 nil：换规则那一轮装失败，anchor 里不是这一份，不是测试规则
        #expect(read(.on, scope: nil) == .on(problem: .rulesNotLoaded))
        // 隧道网卡不在：Clash 没开 TUN 或网卡名填错，这时是全拦，单独说
        #expect(read(.on, check: noTunnel) == .on(problem: .tunnelMissing))
        let pfStopped = FirewallCheck(pfEnabled: false, anchorPointPresent: true, rulesLoaded: true, evaluations: 10, evaluationsGrowing: true, tunnelPresent: true)
        #expect(read(.on, check: pfStopped) == .on(problem: .checkFailed))
        // 网卡不在、pf 也停了：什么都没在拦，不能说「全被拦下」
        let pfStoppedNoTunnel = FirewallCheck(pfEnabled: false, anchorPointPresent: true, rulesLoaded: true, evaluations: 10, evaluationsGrowing: true, tunnelPresent: false)
        #expect(read(.on, check: pfStoppedNoTunnel) == .on(problem: .checkFailed))
        let emptyAnchorNoTunnel = FirewallCheck(pfEnabled: true, anchorPointPresent: true, rulesLoaded: false, evaluations: nil, evaluationsGrowing: nil, tunnelPresent: false)
        #expect(read(.on, check: emptyAnchorNoTunnel) == .on(problem: .checkFailed))
        #expect(read(.on, check: nil) == .on(problem: .checkFailed))
    }

    @Test func trialShowsDeadline() {
        let end = now.addingTimeInterval(80)
        #expect(read(.trial, trialEndsAt: end) == .trial(endsAt: end, problem: nil))
        #expect(read(.trial, check: noTunnel, trialEndsAt: end) == .trial(endsAt: end, problem: .tunnelMissing))
        #expect(read(.trial) == .trial(endsAt: nil, problem: nil))
    }

    /// 说开着的摘要 30 秒（3 轮）没更新：守护进程被卸、崩了，或恢复脚本刚跑过，说不清是开是关
    @Test(arguments: [FirewallStatus.Mode.trial, .on])
    func staleOpenSummaryIsUnknown(_ mode: FirewallStatus.Mode) {
        #expect(read(mode, ago: 31) == .unknown(.stale))
        // 钟被往回调过：摘要的时刻在未来太远也不信
        #expect(read(mode, ago: -31) == .unknown(.stale))
        #expect(read(mode, ago: 29) != .unknown(.stale))
        #expect(read(mode, ago: 30) != .unknown(.stale))
    }

    /// off 时守护进程本来就不跑：不看新不新鲜
    @Test func offIgnoresFreshness() {
        #expect(read(.off, check: nil, ago: 3600) == .off(problem: nil))
    }

    /// 清规则、释放引用失败了：关着也可能还在拦，要让人看见
    @Test func failedStepsAreShown() {
        #expect(read(.off, check: nil, failed: [.flush]) == .off(problem: .failedSteps))
        // 关着时只是释放引用没做成：规则已经清了，多留一个引用不影响上网，守护进程也不再跑
        #expect(read(.off, check: nil, failed: [.release]) == .off(problem: nil))
        #expect(read(.on, failed: [.load]) == .on(problem: .failedSteps))
    }

    /// 「保留」只在试运行一切正常时给：网卡不在时外网全被拦，这时保留就是把断网锁成重启也在。测试规则不算保护，但照样能保留
    @Test func keepOnlyWhenTrialIsHealthy() {
        #expect(read(.trial).canKeep)
        #expect(read(.trial, scope: .testTable).canKeep)
        #expect(!read(.trial, check: noTunnel).canKeep)
        #expect(!read(.trial, check: nil).canKeep)
        #expect(!read(.trial, scope: nil).canKeep)
        #expect(!read(.trial, failed: [.load]).canKeep)
        #expect(!read(.on).canKeep)
        #expect(!read(.trial, ago: 31).canKeep)
    }

    /// 开关打开：试运行、开着，和说不清的时候，让人能点「关」。还没有摘要也算说不清：守护进程可能在拦、只是摘要写不进去
    @Test func switchedOn() {
        #expect(read(.trial).switchedOn && read(.on, check: noTunnel).switchedOn)
        #expect(FirewallReading(installed: true, summary: .missing, now: now).switchedOn)
        #expect(FirewallReading(installed: true, summary: .unreadable, now: now).switchedOn)
        #expect(read(.on, ago: 31).switchedOn)
        #expect(!read(.off).switchedOn && !read(.off, failed: [.flush]).switchedOn && !read(.stateUnreadable).switchedOn)
        #expect(!FirewallReading(installed: false, summary: .missing, now: now).switchedOn)
    }

    @Test func boundaryCases() {
        #expect(FirewallReading(installed: false, summary: .missing, now: now) == .notInstalled)
        // 刚装上、第一轮还没写；或者恢复脚本删到一半
        #expect(FirewallReading(installed: true, summary: .missing, now: now) == .unknown(.noSummary))
        #expect(FirewallReading(installed: true, summary: .unreadable, now: now) == .unknown(.unreadable))
        // 读不出状态文件时守护进程按 off 办、清了规则：开关该是关的，不然点「关」没反应
        #expect(read(.stateUnreadable) == .off(problem: .stateUnreadable))
        // 没装但还剩一份摘要（卸到一半）：按装着办，让人能看见、能再卸一次
        #expect(FirewallReading(installed: false, summary: .read(FirewallStatus(mode: .on, scope: .everyone, check: passed, checkedAt: now)), now: now)
                == .on(problem: nil))
    }
}

/// 实机（测试规则、保留之后）守护进程写下的一份摘要原文：格式和判读都对得上
@Suite struct FirewallReadingRealSummary {
    @Test func testRulesOnIsNotProtected() throws {
        let json = #"{"check":{"anchorPointPresent":true,"evaluations":40851,"evaluationsGrowing":true,"pfEnabled":true,"rulesLoaded":true,"tunnelPresent":true},"checkedAt":"2026-11-01T00:46:05Z","failedSteps":[],"mode":"on","scope":"testTable"}"#
        let status = try FirewallStatus.decode(Data(json.utf8))
        let now = status.checkedAt.addingTimeInterval(3)
        #expect(FirewallReading(installed: true, summary: .read(status), now: now) == .on(problem: .testRules))
        var official = status
        official.scope = .everyone
        #expect(FirewallReading(installed: true, summary: .read(official), now: now) == .on(problem: nil))
    }
}

/// 开启、保留、关闭之后，什么时候开关能照摘要显示：摘要只精确到秒，关闭后守护进程跑完那一轮就退出
@Suite struct FirewallCommandSettling {
    /// 从点下开始算（密码框要好几秒），摘要是之后那一轮写的就信
    @Test func summaryAfterCommandStartSettles() {
        let started = Date(timeIntervalSince1970: 1_800_000_000.6)
        let round = Date(timeIntervalSince1970: 1_800_000_004) // 只精确到秒
        #expect(FirewallReading.settled(checkedAt: round, commandStarted: started, now: round.addingTimeInterval(0.5)))
        #expect(!FirewallReading.settled(checkedAt: Date(timeIntervalSince1970: 1_800_000_000), commandStarted: started, now: round))
    }

    /// 守护进程没起来：等满 3 轮就照摘要显示，开关不会一直锁着
    @Test func givesUpAfterFreshness() {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!FirewallReading.settled(checkedAt: nil, commandStarted: started, now: started.addingTimeInterval(29)))
        #expect(FirewallReading.settled(checkedAt: nil, commandStarted: started, now: started.addingTimeInterval(31)))
    }
}
