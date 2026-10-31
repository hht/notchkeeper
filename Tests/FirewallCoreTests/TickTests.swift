import Testing
@testable import FirewallCore

private let rules = FirewallRules(tunnel: "utun1024", directory: "/nk")!
private let token = "1864012227745836441"
/// 系统 pfd 的引用（10-31 本机 `pfctl -s References` 里就有一个）
private let pfdToken = "12184426722627826779"

/// 此刻 pf 的样子：anchor 空不空、`pfctl -s References` 里有哪些 token
private func pf(empty: Bool, tokens: Set<String>? = [pfdToken, token]) -> PFSnapshot {
    PFSnapshot(anchorEmpty: empty, tokens: tokens)
}

@Suite struct Tick {
    /// 先装规则再拿引用：pf 本来是停着的话，启用那一刻规则已经在了
    @Test func trialLoadsRulesThenEnablesPF() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(s.tick(at: at(101), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [.load(rules), .enable])
    }

    /// 装好、拿到引用之后什么都不做：每轮重装会让 Evaluations 归零（核对不了），每轮 -E 会让引用越涨越多
    @Test func steadyStateDoesNothing() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111), pf: pf(empty: false), rules: rules) == [])
    }

    /// 规则被别人清掉（root 进程 pfctl -F、主规则集被重载）就装回去，引用照旧
    @Test func reloadsWhenAnchorWasEmptied() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111), pf: pf(empty: true), rules: rules) == [.load(rules)])
    }

    /// 隧道网卡名改了：换上新规则
    @Test func reloadsWhenRulesChange() {
        var s = steadyTrial()
        let other = FirewallRules(tunnel: "utun7", directory: "/nk")!
        #expect(s.tick(at: at(111), pf: pf(empty: false), rules: other) == [.load(other)])
    }

    /// 认不出 token 时不再 -E：引用已经拿到了，再 -E 每轮多一个
    @Test func unknownTokenIsNotReEnabled() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        _ = s.tick(at: at(101), pf: pf(empty: true), rules: rules)
        s.record(.load(rules))
        s.record(.enable, token: nil)
        #expect(s.reference == .unknownToken)
        #expect(s.tick(at: at(111), pf: pf(empty: false), rules: rules) == [])
    }

    /// -E 之后列表读得出却没有这个 token（两边号码对不上）：当认不出，否则下一轮以为引用没了，每轮 -E 一个
    @Test func tokenMissingFromTheListRightAfterEnableIsUnknown() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        _ = s.tick(at: at(101), pf: pf(empty: true, tokens: [pfdToken]), rules: rules)
        s.record(.load(rules))
        s.record(.enable, token: token)
        s.confirmReference(liveTokens: [pfdToken])
        #expect(s.reference == .unknownToken)
        #expect(s.tick(at: at(111), pf: pf(empty: false, tokens: [pfdToken]), rules: rules) == [])
    }

    /// -E 之后读不出列表：先信 -E 给的 token，下一轮照常核对
    @Test func unreadableListRightAfterEnableKeepsTheToken() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        s.record(.enable, token: token)
        s.confirmReference(liveTokens: nil)
        #expect(s.reference == .held(token: token))
    }

    /// 认不出号码的引用只能靠「pf 停了」知道它被 pfctl -d 作废了：停了就当没了，下一轮重新 -E，不卡在 pf 停着
    @Test func unknownTokenIsDroppedWhenPFIsDisabled() throws {
        var s = FirewallState(bootSession: boot)
        s.reference = .unknownToken
        _ = s.check(mainRules: "", anchorRules: "", info: "", interfaces: "", tunnel: "utun1024")
        #expect(s.reference == .unknownToken) // 读不出 info 不算停了
        _ = s.check(mainRules: "", anchorRules: "", info: "Status: Disabled\n", interfaces: "", tunnel: "utun1024")
        #expect(s.reference == nil)
    }

    /// 有人 pfctl -d 作废了所有引用（docs/firewall.md §6）：我们的 token 不在了就重新 -E，不卡在「以为还拿着」
    @Test func reEnablesWhenOurReferenceIsGone() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111), pf: pf(empty: false, tokens: []), rules: rules) == [.enable])
    }

    /// 读不出引用列表时照旧：不能确定没了，就不 -E（宁可少一个引用，也不让引用越涨越多）
    @Test func unreadableReferencesKeepsTheToken() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111), pf: pf(empty: false, tokens: nil), rules: rules) == [])
        #expect(s.reference == .held(token: token))
    }
}

extension Tick {
    /// 先清规则再放引用：放完引用 pf 可能停掉，规则得先清掉，免得下次谁启用 pf 时我们的规则又生效
    @Test func offFlushesThenReleases() {
        var s = steadyTrial()
        s.disable()
        #expect(s.tick(at: at(111), pf: pf(empty: false), rules: rules) == [.flush, .release(token: token)])
        s.record(.flush)
        s.record(.release(token: token))
        #expect(s.tick(at: at(121), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [])
    }

    /// 只释放 pf 里还在的 token：作废了的号码可能已经分给了别人
    @Test func offDoesNotReleaseAGoneToken() {
        var s = steadyTrial()
        s.disable()
        #expect(s.tick(at: at(111), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [])
        #expect(s.reference == nil)
    }

    /// 读不出引用列表时这一轮先不释放，下一轮再看
    @Test func offWaitsWhenReferencesAreUnreadable() {
        var s = steadyTrial()
        s.disable()
        #expect(s.tick(at: at(111), pf: pf(empty: true, tokens: nil), rules: rules) == [])
        #expect(s.reference == .held(token: token))
    }

    /// 到期必回滚，App 不在也照样
    @Test func expiredTrialRollsBack() {
        var s = steadyTrial()
        #expect(s.tick(at: at(220), pf: pf(empty: false), rules: rules) == [.flush, .release(token: token)])
        #expect(s.mode == .off)
    }

    /// 开机后内核里的规则和引用都没了：on 重新装、重新拿引用（旧 token 不在引用列表里，不会被拿去释放）
    @Test func onAfterBootReloadsAndReEnables() throws {
        var s = steadyTrial()
        try s.keep(at: at(110))
        #expect(s.tick(at: at(5, boot: "OTHER-BOOT"), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [.load(rules), .enable])
        #expect(s.mode == .on)
    }

    /// 开机时 trial 当 off，也不释放上一次开机的 token
    @Test func trialAfterBootIsOffAndDoesNotReleaseTheOldToken() {
        var s = steadyTrial()
        #expect(s.tick(at: at(5, boot: "OTHER-BOOT"), pf: pf(empty: true, tokens: [pfdToken]), rules: rules) == [])
        #expect(s.mode == .off)
        #expect(s.reference == nil)
    }

    /// 读不出开机标识（sysctl 失败）：不知道换没换开机，试运行往安全方向当 off；引用和记下的开机标识都不动，
    /// 免得把活着的引用丢了、或者把旧 token 配上错的开机标识
    @Test func unreadableBootSessionEndsTheTrialButKeepsTheReference() {
        var s = steadyTrial()
        #expect(s.tick(at: at(111, boot: nil), pf: pf(empty: false, tokens: nil), rules: rules) == [.flush])
        #expect(s.mode == .off)
        #expect(s.reference == .held(token: token))
        #expect(s.bootSession == boot)
    }

    /// 开机标识变了、引用却还在列表里（开机标识读错过）：不丢掉还活着的引用，否则 on 每误判一次就多 -E 一个
    @Test func spuriousBootChangeKeepsALiveReference() throws {
        var s = steadyTrial()
        try s.keep(at: at(110))
        #expect(s.tick(at: at(120, boot: "OTHER-BOOT"), pf: pf(empty: false), rules: rules) == [.load(rules)])
        #expect(s.reference == .held(token: token))
    }

    /// 认不出号码的引用核对不了还在不在：开机标识变了就作废，on 重新 -E
    @Test func bootChangeDropsAnUnknownToken() throws {
        var s = steadyTrial()
        try s.keep(at: at(110))
        s.reference = .unknownToken
        #expect(s.tick(at: at(5, boot: "OTHER-BOOT"), pf: pf(empty: true), rules: rules) == [.load(rules), .enable])
    }

    /// 开机后读不出引用列表：旧 token 不能配上新的开机标识留下（恢复脚本据开机标识认 token，会去 -X 上一次开机的号码），on 要重新 -E
    @Test func bootChangeWithUnreadableReferencesDropsTheOldToken() throws {
        var s = steadyTrial()
        try s.keep(at: at(110))
        #expect(s.tick(at: at(5, boot: "OTHER-BOOT"), pf: pf(empty: true, tokens: nil), rules: rules) == [.load(rules), .enable])
        #expect(s.reference == nil)
    }

    /// 重装后计数从 0 数起：那一轮不拿来比，免得刚重装就报「计数不涨」
    @Test func reloadResetsTheEvaluationBaseline() {
        var s = steadyTrial()
        let anchor = { (n: Int) in "pass all\n  [ Evaluations: \(n)  Packets: 0 ]\n" }
        func check(_ n: Int) -> Bool? {
            s.check(mainRules: "anchor \"com.apple/*\" all\n", anchorRules: anchor(n), info: "Status: Enabled\n",
                    interfaces: "utun1024", tunnel: "utun1024").evaluationsGrowing
        }
        #expect(check(500) == nil)
        #expect(check(900) == true)
        s.record(.load(rules))
        #expect(check(40) == nil)
    }
}

/// 试运行中，规则装好、引用拿到
private func steadyTrial() -> FirewallState {
    var s = FirewallState(bootSession: boot)
    try! s.enable(at: at(100))
    _ = s.tick(at: at(101), pf: pf(empty: true, tokens: [pfdToken]), rules: rules)
    s.record(.load(rules))
    s.record(.enable, token: token)
    return s
}
