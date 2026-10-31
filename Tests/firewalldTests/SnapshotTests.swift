import Foundation
import Testing
import FirewallCore
@testable import firewalld

/// 开启时拍放行表的快照（docs/firewall.md §4）：只有开启读用户目录，守护进程只装 root 目录里的两个表文件
@Suite struct Snapshot {
    @Test func enableWritesBothAllowTables() throws {
        let rig = try Rig()
        try rig.enable()
        #expect(rig.table("clash") == "198.51.100.1/32\n198.51.100.53/32\n127.0.0.1/32\n")
        #expect(rig.table("cn") == "0.0.0.0/8\n")
        let mode = try FileManager.default.attributesOfItem(atPath: rig.directory.appendingPathComponent("cn.table").path)[.posixPermissions]
        #expect(mode as? Int == 0o644)
        // 节点域名问 mihomo 查节点用的那个上游，A 和 AAAA 都问
        #expect(rig.pf.calls.filter { $0.first == "/usr/bin/dig" }.map { $0[8] } == ["A", "AAAA"])
    }

    /// 开启把两张表交回去，命令行据此打印各多少条给人核对（mmdb 被人改过时看得出来）
    @Test func enableReturnsTheTables() throws {
        let rig = try Rig()
        let tables = try Helper.command(.enable(clash: rig.clash), rig.system)
        #expect(tables?.clash.count == 3)
        #expect(tables?.cn.count == 1)
    }

    /// 库里一段 CN 都没有（库换了样子）：拒绝开启，否则正式规则下 DIRECT 全不通
    @Test func enableRefusesAnEmptyCountryTable() throws {
        let rig = try Rig()
        var mmdb = Rig.countryDatabase(prefix: 8)
        let cn = Array("CN".utf8)
        let at = try #require(mmdb.indices.first { mmdb[$0] == cn[0] && mmdb[$0 + 1] == cn[1] })
        mmdb.replaceSubrange(at...(at + 1), with: Array("US".utf8))
        try Data(mmdb).write(to: rig.clash.appendingPathComponent("Country.mmdb"))
        #expect(throws: Helper.Failure.snapshot(.noCountryNetworks)) { try rig.enable() }
    }

    /// 库被改成大半个互联网都算 CN：拒绝开启，否则正式规则等于什么都不拦、核对却全过（判定见 `CountryDatabase.isPlausible`）
    @Test func enableRefusesImplausiblyWideCountryNetworks() throws {
        let rig = try Rig()
        try Data(Rig.countryDatabase(prefix: 1)).write(to: rig.clash.appendingPathComponent("Country.mmdb"))
        #expect(throws: Helper.Failure.snapshot(.implausibleCountryNetwork)) { try rig.enable() }
    }

    /// 答案是 fake-ip：拒绝开启，状态不动、不写表
    @Test func enableRefusesFakeIPAnswers() throws {
        let rig = try Rig()
        rig.pf.dns["node.example"] = ["198.18.0.3"]
        #expect(throws: Helper.Failure.snapshot(.table(.fakeAnswer(node: 1)))) { try rig.enable() }
        #expect(rig.state == .missing)
        #expect(rig.table("clash") == nil)
        #expect(!rig.pf.calls.contains { $0.first == "/bin/launchctl" })
    }

    @Test func enableRefusesUnreadableClashFiles() throws {
        let rig = try Rig()
        try FileManager.default.removeItem(at: rig.clash.appendingPathComponent("Country.mmdb"))
        #expect(throws: Helper.Failure.snapshot(.unreadable("Country.mmdb"))) { try rig.enable() }
        #expect(rig.state == .missing)
    }

    /// root 读用户可写的目录：符号链接（可能指向只有 root 能读的文件、/dev/zero）和 FIFO（读了就一直等）都不读
    @Test func enableRefusesLinksAndPipes() throws {
        let rig = try Rig()
        let mmdb = rig.clash.appendingPathComponent("Country.mmdb")
        try FileManager.default.removeItem(at: mmdb)
        try FileManager.default.createSymbolicLink(at: mmdb, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(throws: Helper.Failure.snapshot(.unreadable("Country.mmdb"))) { try rig.enable() }
        try FileManager.default.removeItem(at: mmdb)
        #expect(mkfifo(mmdb.path, 0o600) == 0)
        #expect(throws: Helper.Failure.snapshot(.unreadable("Country.mmdb"))) { try rig.enable() }
    }

    /// 已经开着时再开启：报「已经开着」，正在用的表不换
    @Test func enableWhileOnLeavesTheTablesAlone() throws {
        let rig = try Rig()
        try rig.enable()
        try Helper.command(.keep, rig.system)
        rig.pf.dns["node.example"] = ["198.51.100.9"]
        #expect(throws: Helper.Failure.command(.notOff)) { try rig.enable() }
        #expect(rig.table("clash")?.hasPrefix("198.51.100.1/32\n") == true)
    }
}

/// 守护进程：trial / on 时一轮接一轮，回到 off 跑完那一轮就退出（docs/firewall.md §2）
@Suite struct Serve {
    private let config = Helper.RoundConfig(tunnel: "utun1024", scope: .everyone)!

    @Test func keepsGoingWhileOnAndStopsAfterTheRoundThatTurnsOff() throws {
        let rig = try Rig()
        try rig.enable()
        var pauses = 0
        Helper.serve(rig.system, config) {
            pauses += 1
            rig.seconds += 10
            if pauses == 3 { _ = try? Helper.command(.disable, rig.system) }
        }
        #expect(pauses == 3)
        #expect(rig.pf.anchor == "")
        #expect(rig.status?.mode == .off)
    }

    /// 试运行到期那一轮回到 off，进程跟着退出：到期回滚不靠别的
    @Test func stopsWhenTheTrialExpires() throws {
        let rig = try Rig()
        try rig.enable()
        var pauses = 0
        Helper.serve(rig.system, config) {
            pauses += 1
            rig.seconds += 30
        }
        #expect(pauses == 4) // 30、60、90 秒时还在试运行，120 秒那一轮到期
        #expect(rig.pf.anchor == "")
    }

    /// 回到 off 那一轮清规则失败：不退出，下一轮重做，清掉了才退出。退出了就没人再清，整机拦截规则会一直挂着
    @Test func keepsGoingUntilOffIsCleanedUp() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        try Helper.command(.disable, rig.system)
        rig.pf.failing = "-F"
        var pauses = 0
        Helper.serve(rig.system, config) {
            pauses += 1
            if pauses == 2 { rig.pf.failing = nil }
        }
        #expect(pauses == 2)
        #expect(rig.pf.anchor == "")
        #expect(rig.pf.references.isEmpty)
    }

    /// 回到 off、只有释放引用失败：照样退出。多留一个引用不影响上网，为它每 10 秒跑一轮就成了 off 时的轮询
    @Test func stopsEvenIfOnlyTheReleaseFails() throws {
        let rig = try Rig()
        try rig.enable()
        _ = rig.round()
        try Helper.command(.disable, rig.system)
        rig.pf.failing = "-X"
        Helper.serve(rig.system, config) { Issue.record("只是释放失败，不该再等下一轮") }
        #expect(rig.pf.anchor == "")
    }

    @Test func offRunsOneRoundAndStops() throws {
        let rig = try Rig()
        rig.pf.anchor = "pass all\n"
        Helper.serve(rig.system, config) { Issue.record("off 时不该再等下一轮") }
        #expect(rig.pf.anchor == "")
    }
}
