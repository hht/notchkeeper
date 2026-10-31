import Foundation
import Testing
import NotchCore

/// 插件的设置（docs/ui.md「面板布局」）：缺省都开着、每段最多露 5 行，常驻插件是出口守卫
@Suite struct PluginConfig {
    private func decode(_ json: String) throws -> Config { try JSONDecoder().decode(Config.self, from: Data(json.utf8)) }

    @Test func defaults() {
        let c = Config()
        #expect(c.isEnabled("guard") && c.isEnabled("terminal"))
        #expect(c.maxRows("claude") == 5)
        #expect(c.residentPlugin == "guard" && c.showsEarMascot && c.pluginOrder.isEmpty)
    }

    /// 缺字段用默认值；行数压在 1…5
    @Test func partialEntries() throws {
        let c = try decode(#"{"plugins":{"claude":{"enabled":false},"terminal":{"maxRows":9},"dl":{"maxRows":0}}}"#)
        #expect(!c.isEnabled("claude") && c.maxRows("claude") == 5)
        #expect(c.isEnabled("terminal") && c.maxRows("terminal") == 5)
        #expect(c.maxRows("dl") == 1)
    }

    /// 空串是不常驻
    @Test func noResident() throws {
        #expect(try decode(#"{"residentPlugin":""}"#).resident == nil)
        #expect(Config().resident == "guard")
    }

    /// 段的顺序：用户排过的在前，没排过的按给的默认顺序跟在后面；排过但已经没了的不出现
    @Test func sectionOrder() throws {
        let c = try decode(#"{"pluginOrder":["terminal","gone","claude"]}"#)
        #expect(c.ordered(["claude", "dl", "terminal"]) == ["terminal", "claude", "dl"])
        #expect(Config().ordered(["claude", "dl"]) == ["claude", "dl"])
    }

    @Test func setters() {
        var c = Config()
        c.setEnabled(false, for: "dl")
        c.setMaxRows(2, for: "dl")
        #expect(!c.isEnabled("dl") && c.maxRows("dl") == 2)
        c.move("dl", by: -1, in: ["claude", "dl"])
        #expect(c.ordered(["claude", "dl"]) == ["dl", "claude"])
        c.move("dl", by: -1, in: ["claude", "dl"])
        #expect(c.ordered(["claude", "dl"]) == ["dl", "claude"])
    }

    @Test func roundTrips() throws {
        var c = Config()
        c.setEnabled(false, for: "guard")
        c.residentPlugin = ""
        c.showsEarMascot = false
        c.pluginOrder = ["dl"]
        #expect(try decode(String(decoding: JSONEncoder().encode(c), as: UTF8.self)) == c)
    }
}
