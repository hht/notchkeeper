import Foundation
import Testing
import NotchCore
@testable import PluginCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private let terminal = Manifest(id: "terminal", name: "终端", symbol: "terminal")
private let plugins = ["terminal": terminal]

private func message(plugin: String = "terminal", id: UUID = UUID(), sent: Date = t0, group: String? = nil, staleAt: Date? = nil) -> Message {
    Message(plugin: plugin, id: id, at: sent, group: group, title: "npm 跑完了", subtitle: "~/x", value: "12 秒", outcome: .failed,
            block: .facts([.init(title: "退出码", value: "1")]), action: .activate(bundleID: "com.mitchellh.ghostty"),
            buttons: [.init(title: "看文档", action: .open(URL(string: "https://example.com")!))], staleAt: staleAt)
}

@Suite struct ManifestParsing {
    private func parse(_ json: String, in directory: String = "terminal") throws -> Manifest {
        try Manifest.parse(Data(json.utf8), directoryName: directory)
    }

    @Test func parses() throws {
        #expect(try parse(#"{"id":"terminal","name":"终端","symbol":"terminal","future":1}"#) == terminal)
    }

    /// 目录名就是插件 id：对不上的不认，免得一个插件冒用另一个的名字
    @Test func idMustMatchDirectory() {
        #expect(throws: ManifestError.badID) { try parse(#"{"id":"guard","name":"终端","symbol":"terminal"}"#) }
    }

    /// 目录名对上了、但不是合规的插件 id
    @Test func badIDRejected() {
        #expect(throws: ManifestError.badID) { try parse(#"{"id":"Terminal","name":"终端","symbol":"terminal"}"#, in: "Terminal") }
    }

    @Test(arguments: [#"{"id":"terminal","name":" ","symbol":"terminal"}"#, #"{"id":"terminal","name":"终端","symbol":""}"#])
    func blankFieldsRejected(_ json: String) {
        #expect(throws: ManifestError.missingField) { try parse(json) }
    }

    @Test(arguments: ["{", #"{"id":"terminal","name":"终端"}"#])
    func malformedRejected(_ json: String) {
        #expect(throws: ManifestError.malformed) { try parse(json) }
    }

    /// 名字卡上只放得下 `Card.maxValue` 个字：安装时就拦，免得装上了才发现被截断
    @Test(arguments: [#"{"id":"terminal","name":"\#(String(repeating: "长", count: 25))","symbol":"terminal"}"#,
                      #"{"id":"terminal","name":"终端","symbol":"\#(String(repeating: "a", count: 65))"}"#])
    func tooLongRejectedAtInstall(_ json: String) {
        #expect(throws: ManifestError.tooLong) { try Manifest.parse(Data(json.utf8), directoryName: nil) }
    }

    /// 已经装着的（装好后登记被改长了）照常收卡：名字由卡片截短，图标名对不上由 App 换成拼图块
    @Test func tooLongStillRegistered() throws {
        let name = String(repeating: "长", count: 25)
        #expect(try parse(#"{"id":"terminal","name":"\#(name)","symbol":"terminal"}"#).name == name)
    }

    @Test func longestAccepted() throws {
        let name = String(repeating: "长", count: Card.maxValue)
        #expect(try Manifest.parse(Data(#"{"id":"terminal","name":"\#(name)","symbol":"terminal"}"#.utf8), directoryName: nil).name == name)
    }
}

/// 收件箱和登记都是外部写的：任何字节都只会解析失败，不会让 App 崩溃（准则 5）
@Suite struct ParsingNeverTraps {
    /// 固定种子：失败了能复现（准则 4）
    @Test func randomBytes() {
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0..<2000 {
            let data = Data((0..<Int.random(in: 0...200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = try? Message.parse(data)
            _ = try? Manifest.parse(data, directoryName: nil)
        }
    }

    /// 合法消息的每一个前缀、以及逐字节改坏的版本
    @Test func mutatedValidMessages() {
        let valid = Data(#"{"v":1,"plugin":"ci","id":"8D3B7C1E-2F4A-4B6C-9D8E-1A2B3C4D5E6F","at":"2026-10-31T00:00:00Z","title":"x","outcome":"done","block":{"type":"progress","value":1e308},"buttons":[{"type":"Action.OpenUrl","title":"a","url":"https://a.com"}],"activity":{"id":"a","event":"start"}}"#.utf8)
        for i in valid.indices {
            _ = try? Message.parse(valid.prefix(i))
            for byte: UInt8 in [0, 0x22, 0x5C, 0x7B, 0x7D, 0xFF] {
                var bad = valid
                bad[i] = byte
                _ = try? Message.parse(bad)
            }
        }
    }
}

@Suite struct InboxAdmission {
    @Test func registeredMessageBecomesCard() throws {
        var gate = InboxGate()
        let admitted = try gate.admit(message(group: "tty1"), plugins: plugins, now: t0)
        let card = admitted.card
        #expect(card.source == .plugin(id: "terminal", name: "终端", symbol: "terminal"))
        #expect(card.title == "npm 跑完了" && card.subtitle == "~/x" && card.value == "12 秒" && card.outcome == .failed)
        #expect(card.block == .facts([.init(title: "退出码", value: "1")]))
        #expect(card.action == .activate(bundleID: "com.mitchellh.ghostty"))
        #expect(card.buttons == [.init(title: "看文档", action: .open(URL(string: "https://example.com")!))])
        #expect(admitted.key == .group(plugin: "terminal", name: "tty1"))
    }

    /// shell 没有进程启动时刻：按「pid 的 tty 还是这个」认它
    @Test func focusTerminalBecomesTerminalAction() throws {
        var gate = InboxGate()
        var m = message()
        m.action = .focusTerminal(tty: "/dev/ttys003", pid: 4242, cwd: "/Users/x")
        m.buttons = []
        let card = try gate.admit(m, plugins: plugins, now: t0).card
        #expect(card.action == .terminal(TerminalRef(pid: 4242, identity: .tty("/dev/ttys003"), cwd: "/Users/x")))
    }

    @Test func ungroupedHasNoKey() throws {
        var gate = InboxGate()
        #expect(try gate.admit(message(), plugins: plugins, now: t0).key == nil)
    }

    /// 没登记的插件发来的丢弃（CLAUDE.md 硬规则「插件」）
    @Test func unregisteredDropped() {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.unregistered) { try gate.admit(message(plugin: "build"), plugins: plugins, now: t0) }
    }

    @Test func staleAtPassedDropped() throws {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.stale) { try gate.admit(message(staleAt: at(10)), plugins: plugins, now: at(10)) }
        _ = try gate.admit(message(staleAt: at(10)), plugins: plugins, now: at(9))
    }

    /// 没写 staleAt：发出 10 分钟后不放（App 没开时攒下的）
    @Test func oldMessageDropped() throws {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.stale) { try gate.admit(message(), plugins: plugins, now: at(600)) }
        _ = try gate.admit(message(), plugins: plugins, now: at(599))
    }

    /// 交给队列的过期时刻：没写 staleAt 是发出后 10 分钟；staleAt 只能提前，不能推后；
    /// 发出时刻在未来（钟不准或写错）按收到时刻算，不会永不过期
    @Test(arguments: [(nil as TimeInterval?, 0.0, 600.0), (30, 0, 30), (3600, 0, 600), (nil, 86400, 600), (nil, -100, 500)])
    func staleAtHandedToQueue(_ staleAt: TimeInterval?, _ sent: TimeInterval, _ expected: TimeInterval) throws {
        var gate = InboxGate()
        let admitted = try gate.admit(message(sent: at(sent), staleAt: staleAt.map(at)), plugins: plugins, now: t0)
        #expect(admitted.staleAt == at(expected))
    }

    /// 同一个 id 只放一次：脚本重发同一条消息不弹两张
    @Test func sameIDOnce() throws {
        var gate = InboxGate()
        let id = UUID()
        _ = try gate.admit(message(id: id), plugins: plugins, now: t0)
        #expect(throws: InboxGate.Rejection.duplicate) { try gate.admit(message(id: id), plugins: plugins, now: at(1)) }
    }

    /// 去重只记到那条消息过期：之后同 id 再来（发出时刻也更新了）算新的一条
    @Test func sameIDAfterExpiryIsNew() throws {
        var gate = InboxGate()
        let id = UUID()
        _ = try gate.admit(message(id: id), plugins: plugins, now: t0)
        _ = try gate.admit(message(id: id, sent: at(600)), plugins: plugins, now: at(600))
    }

    /// 每个插件 1 分钟至多 6 条，超出的丢弃；别的插件不受影响，过了 1 分钟又能发
    @Test func rateLimitedPerPlugin() throws {
        var gate = InboxGate()
        let both = plugins.merging(["build": Manifest(id: "build", name: "构建", symbol: "hammer")]) { a, _ in a }
        for i in 0..<6 { _ = try gate.admit(message(sent: at(Double(i))), plugins: both, now: at(Double(i))) }
        #expect(throws: InboxGate.Rejection.rateLimited) { try gate.admit(message(sent: at(30)), plugins: both, now: at(30)) }
        _ = try gate.admit(message(plugin: "build", sent: at(30)), plugins: both, now: at(30))
        _ = try gate.admit(message(sent: at(60)), plugins: both, now: at(60))
        #expect(throws: InboxGate.Rejection.rateLimited) { try gate.admit(message(sent: at(60.5)), plugins: both, now: at(60.5)) }
    }

    /// 被拒的不占限流名额
    @Test func rejectedDoNotCount() throws {
        var gate = InboxGate()
        for _ in 0..<10 { _ = try? gate.admit(message(staleAt: t0), plugins: plugins, now: t0) }
        for _ in 0..<6 { _ = try gate.admit(message(), plugins: plugins, now: t0) }
    }
}

/// 内置插件的 id 留着：设置里的开关按 id 存，外部插件用了会和内置的串
@Suite struct ReservedPluginIDs {
    @Test(arguments: ["guard", "claude"])
    func builtInIDsRejected(_ id: String) {
        #expect(throws: ManifestError.reservedID) {
            try Manifest.parse(Data(#"{"id":"\#(id)","name":"x","symbol":"star"}"#.utf8), directoryName: id)
        }
    }
}

private func activity(_ event: Message.Activity.Event = .update, alert: Bool = false, sent: Date = t0, staleAt: Date? = nil) -> Message {
    var m = message(sent: sent, staleAt: staleAt)
    m.activity = .init(id: "xcode", event: event, alert: alert)
    return m
}

/// 活动消息不弹卡（除非 alert），也不进限流；只有 alert 的占名额，超了只是不弹，行照样更新
@Suite struct ActivityAdmission {
    @Test func becomesUpdate() throws {
        var gate = InboxGate()
        let u = try gate.admitActivity(activity(.start), plugins: plugins, now: t0)
        #expect(u.plugin == "terminal" && u.id == "xcode" && u.event == .start && u.at == t0 && !u.alert)
        #expect(u.card.title == "npm 跑完了" && u.card.source == .plugin(id: "terminal", name: "终端", symbol: "terminal"))
    }

    @Test func updatesAreNotRateLimited() throws {
        var gate = InboxGate()
        for i in 0..<20 { _ = try gate.admitActivity(activity(sent: at(Double(i))), plugins: plugins, now: at(Double(i))) }
        _ = try gate.admit(message(sent: at(20)), plugins: plugins, now: at(20))
    }

    @Test func alertOverLimitStillUpdatesRow() throws {
        var gate = InboxGate()
        for _ in 0..<6 { _ = try gate.admit(message(), plugins: plugins, now: t0) }
        let u = try gate.admitActivity(activity(alert: true), plugins: plugins, now: t0)
        #expect(!u.alert)
    }

    @Test func alertCountsAgainstLimit() throws {
        var gate = InboxGate()
        for _ in 0..<6 {
            let u = try gate.admitActivity(activity(alert: true), plugins: plugins, now: t0)
            #expect(u.alert)
        }
        #expect(throws: InboxGate.Rejection.rateLimited) { try gate.admit(message(), plugins: plugins, now: t0) }
    }

    /// 活动最长 8 小时（照 ActivityKit）：发出更早的不收；写了 staleAt 且过了也不收
    @Test func staleActivityDropped() throws {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.stale) { try gate.admitActivity(activity(), plugins: plugins, now: at(8 * 3600)) }
        _ = try gate.admitActivity(activity(), plugins: plugins, now: at(8 * 3600 - 1))
        #expect(throws: InboxGate.Rejection.stale) { try gate.admitActivity(activity(staleAt: at(5)), plugins: plugins, now: at(5)) }
    }

    @Test func unregisteredDropped() {
        var gate = InboxGate()
        #expect(throws: InboxGate.Rejection.unregistered) { try gate.admitActivity(activity(), plugins: [:], now: t0) }
    }
}

/// 发出时刻在未来（钟不准、本地时间错加了 Z）按收到时刻算：不然那一行永远不过期，之后的 update、end 也都算旧的
@Suite struct FutureActivity {
    @Test func futureAtClampedToNow() throws {
        var gate = InboxGate()
        var m = message(sent: at(86400))
        m.activity = .init(id: "x", event: .start, alert: false)
        #expect(try gate.admitActivity(m, plugins: plugins, now: t0).at == t0)
    }
}

/// 测试用的确定性随机数
/// @see https://prng.di.unimi.it/splitmix64.c
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
