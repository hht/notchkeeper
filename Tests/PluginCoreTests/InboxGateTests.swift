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
