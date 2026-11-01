import Testing
@testable import FirewallCore

/// `pfctl -sr`：主规则集，macOS 26.5、系统默认 /etc/pf.conf 下的实际输出（stdout，docs/firewall.md §6）
private let mainRules = """
scrub-anchor "com.apple/*" all fragment reassemble
scrub-anchor "com.apple.internet-sharing" all fragment reassemble
anchor "com.apple/*" all
anchor "com.apple.internet-sharing" all

"""

/// `pfctl -a com.apple/300.Notchkeeper -vsr`，格式照 macOS 26.5 上演练时的实际输出
private func anchorRules(_ evaluations: [Int]) -> String {
    evaluations.map {
        """
        pass quick on lo0 all flags S/SA keep state
          [ Evaluations: \($0)       Packets: 0         Bytes: 0           States: 0     ]
          [ Inserted: uid 0 pid 91065 ]

        """
    }.joined()
}

private let interfaces = "lo0 gif0 stf0 en0 awdl0 utun0 utun1024 bridge100\n"
/// `pfctl -s info` 的第一行，照 macOS 26.5 上演练时的实际输出
private let info = "Status: Enabled for 18 days 12:22:58          Debug: Urgent\n\n"

@Suite struct Check {
    @Test func healthy() {
        let c = FirewallCheck(mainRules: mainRules, anchorRules: anchorRules([300, 26]), info: info, interfaces: interfaces,
                              tunnel: "utun1024", previousEvaluations: 100)
        #expect(c == FirewallCheck(pfEnabled: true, anchorPointPresent: true, rulesLoaded: true, evaluations: 326,
                                   evaluationsGrowing: true, tunnelPresent: true))
        #expect(c.passed)
    }

    private func check(main: String = mainRules, anchor: String = anchorRules([300, 26]), info i: String = info,
                       interfaces ifs: String = interfaces, previous: UInt64? = 100) -> FirewallCheck {
        FirewallCheck(mainRules: main, anchorRules: anchor, info: i, interfaces: ifs, tunnel: "utun1024", previousEvaluations: previous)
    }

    /// fail-open：有人 pfctl -d 停了 pf，规则还在 anchor 里也不生效；读不出（输出空）同样不算过。
    /// 停了和读不出分开：前者说明我们的引用一定被作废了，后者什么都说明不了
    @Test(arguments: [("Status: Disabled          Debug: Urgent\n", false), ("", nil)] as [(String, Bool?)])
    func pfNotEnabled(_ info: String, enabled: Bool?) {
        let c = check(info: info)
        #expect(c.pfEnabled == enabled)
        #expect(!c.passed)
    }

    /// fail-open：有人 pfctl -f 换掉了主规则集，本 anchor 不再被求值
    @Test func anchorPointGone() {
        let c = check(main: "anchor \"com.apple.internet-sharing\" all\npass all\n")
        #expect(!c.anchorPointPresent)
        #expect(!c.passed)
    }

    @Test func noRules() {
        let c = check(anchor: "")
        #expect(!c.rulesLoaded)
        #expect(c.evaluations == nil)
        #expect(!c.passed)
    }

    /// 计数不涨：规则在、却没被求值
    @Test func evaluationsNotGrowing() {
        let c = check(previous: 326)
        #expect(c.evaluationsGrowing == false)
        #expect(!c.passed)
    }

    /// 网卡名写错或 Clash 改了名：往安全方向出错，但要报出来
    @Test func tunnelMissing() {
        let c = check(interfaces: "lo0 en0 utun0 utun10240\n")
        #expect(!c.tunnelPresent)
        #expect(!c.passed)
    }

    /// 刚装上、没有上一轮可比：不算不过
    @Test func firstRoundAfterLoadPasses() {
        let c = check(previous: nil)
        #expect(c.evaluationsGrowing == nil)
        #expect(c.passed)
    }

    /// 格式变了读不出数：不能永远「过」
    @Test func unreadableEvaluationsFail() {
        let c = check(anchor: anchorRules([300]) + "pass out all\n  [ Evaluations: lots ]\n", previous: nil)
        #expect(c.evaluations == nil)
        #expect(!c.passed)
    }
}

@Suite struct EnableOutput {
    /// macOS 26.5 上演练时 `pfctl -E` 的实际输出：stdout 空，token 在 stderr
    @Test func readsTheToken() {
        let stderr = "No ALTQ support in kernel\nALTQ related functions disabled\npf enabled\nToken : 1864012227745836441\n"
        #expect(PFOutput.token(fromEnable: stderr) == "1864012227745836441")
    }

    @Test(arguments: ["pf enabled\n", "Token : \n", "Token : 12ab\n", "Token : 1\nToken : 2\n"])
    func unrecognizedIsNil(_ stderr: String) {
        #expect(PFOutput.token(fromEnable: stderr) == nil)
    }
}

@Suite struct ReferencesOutput {
    /// macOS 26.5 上演练时 `pfctl -s References` 的实际输出（stdout）
    @Test func readsTokens() {
        let out = """
        TOKENS:
        PID      Process Name                 TOKEN                    TIMESTAMP
        91055    pfctl                        1864012227745836441      0 days 00:00:12
        49256    pfd                          12184426722627826779     18 days 12:23:10

        """
        #expect(PFOutput.tokens(fromReferences: out) == ["1864012227745836441", "12184426722627826779"])
    }

    /// 进程名里有空格也认得出：token 是时间戳（三列）前面那一列
    @Test func processNameWithSpaces() {
        let out = "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\n812      Internet Sharing             42                       1 days 01:02:03\n"
        #expect(PFOutput.tokens(fromReferences: out) == ["42"])
    }

    @Test func noReferences() {
        #expect(PFOutput.tokens(fromReferences: "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\n") == [])
    }

    /// 认不出格式（没有表头、某行对不上）就是读不出，不能当成「一个都没有」：那样会让守护进程每轮重新 -E
    @Test(arguments: ["", "pfctl: DIOCGETSTARTERS: Permission denied\n",
                      "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\ngarbage line\n",
                      "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\n91055    pfctl    1864012227745836441    0 hours 00:00:12\n"])
    func unrecognizedIsNil(_ out: String) {
        #expect(PFOutput.tokens(fromReferences: out) == nil)
    }
}
