import Foundation
import Testing
@testable import FirewallCore

@Suite struct StateFileFormat {
    @Test func roundTripsEveryShape() throws {
        var trial = FirewallState(bootSession: boot)
        try trial.enable(at: at(100))
        trial.record(.load(FirewallRules(tunnel: "utun1024")!))
        trial.record(.enable, token: "1864012227745836441")
        var on = trial
        try on.keep(at: at(110))
        on.record(.enable, token: nil)
        _ = on.check(mainRules: "", anchorRules: "pass all\n  [ Evaluations: 7055 ]\n", info: "", interfaces: "", tunnel: "utun1024")
        #expect(on.lastEvaluations == 7055)
        for s in [FirewallState(bootSession: boot), trial, on] {
            #expect(try FirewallState.restore(from: s.encoded()) == .valid(s))
        }
    }

    /// 恢复脚本用 `plutil -extract <key> raw` 读 token 和 bootSession：用真的 plutil 读一遍
    @Test func rescueScriptCanReadTokenAndBootSession() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        s.record(.enable, token: "18446744073709551615")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("firewall-\(UUID().uuidString).state")
        try s.encoded().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try plutilExtract("token", url) == "18446744073709551615")
        #expect(try plutilExtract("bootSession", url) == boot)
    }

    @Test func missingFileIsMissing() { #expect(FirewallState.restore(from: nil) == .missing) }

    /// 缺字段用默认值：什么都没有就是 off、开机标识对不上（下一轮按新开机处理）
    @Test func missingFieldsDefaultToOff() {
        #expect(FirewallState.restore(from: Data("{}".utf8)) == .valid(FirewallState(bootSession: "")))
    }

    @Test(arguments: [
        "not json",
        #"{"mode":"trial","bootSession":"B"}"#, // 试运行没有截止时间
        #"{"mode":"armed","bootSession":"B"}"#,
        #"{"mode":"on","bootSession":"B","token":"12ab"}"#,
        #"{"mode":"on","bootSession":"B","token":""}"#,
        #"{"mode":"on","bootSession":"B","token":"12","tokenUnknown":true}"#,
    ])
    func malformedIsUnreadable(_ json: String) {
        #expect(FirewallState.restore(from: Data(json.utf8)) == .unreadable)
    }
}

private func plutilExtract(_ key: String, _ url: URL) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    p.arguments = ["-extract", key, "raw", "-o", "-", url.path]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
}
