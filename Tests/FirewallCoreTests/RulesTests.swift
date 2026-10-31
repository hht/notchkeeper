import Testing
import Foundation
@testable import FirewallCore

/// docs/firewall.md §4 的规则草稿，逐字抄来，是正式规则的标准答案；改规则先改文档
private let documentedRules = """
tun  = "utun1024"
lan4 = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }"
mc4  = "{ 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 }"
lan6 = "{ fe80::/10, fc00::/7 }"
mc6  = "{ ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 }"
pass quick on lo0 no state
pass quick on $tun no state
pass out quick inet6 proto icmp6 icmp6-type { 133, 135, 136 }
pass in  quick inet6 proto icmp6 icmp6-type { 134, 135, 136, 137 }
pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67
pass in  quick inet proto udp from any port 67 to any port 68
pass out quick proto { tcp, udp } all user root
block return out quick proto { tcp, udp } to any port 53
pass out quick to $lan4
pass in  quick from $lan4
pass out quick to $lan6
pass in  quick from $lan6
pass out quick to { $mc4, $mc6 }
block return out quick all
block drop   in  quick all

"""

@Suite struct Rules {
    @Test func productionRulesAreTheDocumentedDraft() {
        #expect(FirewallRules(tunnel: "utun1024")?.text == documentedRules)
    }

    /// 网卡名原样拼进 root 加载的规则，只收 BSD 网卡名的样子：字母开头、数字结尾
    @Test(arguments: ["", "utun", "1024", "utun 1024", "utun1024\"", "utun1024\nblock all", "UTUN1024", "utun1024}", "u\u{301}tun0"])
    func rejectsNonInterfaceNames(_ name: String) {
        #expect(FirewallRules(tunnel: name) == nil)
    }

    @Test(arguments: ["utun0", "utun1024", "en0"])
    func acceptsInterfaceNames(_ name: String) {
        #expect(FirewallRules(tunnel: name) != nil)
    }

    /// 测试规则（docs/firewall.md §7「测试时不能真的断网」）：只有三条 block 改成只拦这个用户，其余逐字和正式规则一样。
    /// pf 的 user 只匹配 TCP / UDP，所以 block 里都带上 proto
    @Test func testRulesBlockOnlyTheTestUser() {
        let expected = documentedRules
            .replacingOccurrences(of: "tun  = \"utun1024\"", with: "tun  = \"utun9999\"")
            .replacingOccurrences(of: "block return out quick proto { tcp, udp } to any port 53\n",
                                  with: "block return out quick proto { tcp, udp } to any port 53 user nobody\n")
            .replacingOccurrences(of: "block return out quick all\n",
                                  with: "block return out quick proto { tcp, udp } all user nobody\n")
            .replacingOccurrences(of: "block drop   in  quick all\n",
                                  with: "block drop   in  quick proto { tcp, udp } all user nobody\n")
        #expect(expected != documentedRules)
        #expect(FirewallRules(tunnel: "utun9999", scope: .testUser)?.text == expected)
    }

    /// 系统的 pfctl 只解析不加载（`-n` 不要 root），抓语法错误；它认不认得出坏规则，第二条用例自证
    @Test(arguments: [FirewallRules.Scope.everyone, .testUser])
    func pfctlParsesTheRules(_ scope: FirewallRules.Scope) throws {
        #expect(try pfctlParses(#require(FirewallRules(tunnel: "utun1024", scope: scope)).text))
        #expect(try !pfctlParses("block bogus\n"))
    }
}

private func pfctlParses(_ rules: String) throws -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
    p.arguments = ["-nf", "-"]
    let input = Pipe()
    p.standardInput = input
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    input.fileHandleForWriting.write(Data(rules.utf8))
    try input.fileHandleForWriting.close()
    p.waitUntilExit()
    return p.terminationStatus == 0
}
