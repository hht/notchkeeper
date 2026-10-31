import Foundation
import Testing
import GuardCore
@testable import guardd

private func load(_ json: String?) -> AllowlistFile.Loaded { AllowlistFile.parse(json.map { Data($0.utf8) }) }
private let defaults = AllowlistFile.defaults

@Suite struct AllowlistLoading {
    /// 源码里不放真实出口 IP：默认允许列表是空的，判定里出口 IP 一律算未知（见 EgressGuardTests.emptyAllowlistIsUnknown）
    @Test func defaultsAreEmpty() {
        #expect(defaults.isEmpty)
    }

    /// App 写的是整份 Config，guardd 只取 allowlist，其余键一律忽略
    @Test func readsOnlyAllowlistIgnoringOtherKeys() {
        let l = load(#"{"agents":{"claudeCode":true},"allowlist":["1.2.3.4"],"soundEnabled":true,"future":[1]}"#)
        #expect(l == .init(allowlist: [IPv4("1.2.3.4")!], problem: nil))
    }

    @Test func missingFileFallsBackToDefaults() { #expect(load(nil) == .init(allowlist: defaults, problem: .missing)) }

    @Test(arguments: ["{not json", #"{"allowlist":"198.51.100.8"}"#, #"{"allowlist":[1,2]}"#, "[]"])
    func unreadableFallsBackToDefaults(_ json: String) {
        #expect(load(json) == .init(allowlist: defaults, problem: .unreadable))
    }

    /// 和 App 的 Config 一致：缺这个键就用默认值，不算问题
    @Test func missingKeyUsesDefaults() { #expect(load("{}") == .init(allowlist: defaults, problem: nil)) }

    /// 空列表是 Haitao 的设置，照用（判定里 IP 一律算未知），不偷偷换成默认值
    @Test func emptyListIsRespected() { #expect(load(#"{"allowlist":[]}"#) == .init(allowlist: [], problem: nil)) }

    @Test func invalidEntriesAreDroppedAndCounted() {
        #expect(load(#"{"allowlist":["198.51.100.8","bogus","010.1.1.1"]}"#)
            == .init(allowlist: [IPv4("198.51.100.8")!], problem: .invalidEntries(2)))
    }

    /// 日志不记 IP
    @Test func problemMessagesHaveNoIPs() {
        for p in [AllowlistFile.Problem.missing, .unreadable, .invalidEntries(2)] {
            #expect(p.message.firstMatch(of: /\d+\.\d+\.\d+\.\d+/) == nil)
            #expect(!p.message.isEmpty)
        }
    }

    @Test func readsMissingFileAsMissing() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nk-absent-\(UUID().uuidString).json")
        #expect(AllowlistFile.read(url) == .init(allowlist: defaults, problem: .missing))
    }
}
