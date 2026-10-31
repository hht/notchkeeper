import Foundation

/// 回答：防火墙状态文件 `firewall.state` 长什么样、读出来算什么（docs/firewall.md §4）。
/// 恢复脚本 `scripts/firewall-rescue.sh` 用 plutil 从里面读 `token`（数字串）和 `bootSession`，这两个字段改名或改类型要两边一起改。
/// 不知道文件放在哪、怎么写。
extension FirewallState {
    public static let fileName = "firewall.state"

    /// 读防火墙状态文件的结果。读不出来（坏了、格式对不上）和没有文件分开：没有是常态（刚安装），坏了要报出来、不覆盖原文件
    public enum Restored: Equatable, Sendable {
        case valid(FirewallState)
        case missing
        case unreadable
    }

    /// `data == nil` 是文件不存在
    public static func restore(from data: Data?) -> Restored {
        guard let data else { return .missing }
        guard let f = try? JSONDecoder().decode(Fields.self, from: data) else { return .unreadable }
        var s = FirewallState(bootSession: f.bootSession)
        switch (f.mode ?? "off", f.deadline) {
        case ("off", _): s.mode = .off
        case ("trial", let deadline?): s.mode = .trial(deadline: MonotonicTime(milliseconds: deadline))
        case ("on", _): s.mode = .on
        default: return .unreadable
        }
        switch (f.token, f.tokenUnknown ?? false) {
        case (nil, false): s.reference = nil
        case (nil, true): s.reference = .unknownToken
        case (let token?, false) where !token.isEmpty && token.allSatisfy({ ("0"..."9").contains($0) }):
            s.reference = .held(token: token)
        default: return .unreadable
        }
        s.loadedRules = f.loadedRules.map(FirewallRules.init(loaded:))
        s.lastEvaluations = f.lastEvaluations
        return .valid(s)
    }

    public func encoded() throws -> Data {
        var f = Fields(bootSession: bootSession, loadedRules: loadedRules?.text, lastEvaluations: lastEvaluations)
        switch mode {
        case .off: f.mode = "off"
        case .trial(let deadline): (f.mode, f.deadline) = ("trial", deadline.milliseconds)
        case .on: f.mode = "on"
        }
        switch reference {
        case nil: break
        case .held(let token): f.token = token
        case .unknownToken: f.tokenUnknown = true
        }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(f)
    }

    /// 文件里的字段，缺了用默认值，多了忽略（CLAUDE.md「配置与状态文件」）
    private struct Fields: Codable {
        var mode: String?
        /// 试运行截止时间，单调时钟毫秒
        var deadline: Int64?
        var bootSession: String?
        var token: String?
        var tokenUnknown: Bool?
        var loadedRules: String?
        var lastEvaluations: UInt64?
    }
}

extension FirewallRules {
    /// 防火墙状态文件里记的「上次装进去的规则」：只拿来和这一轮该装的比，不再装进 pf
    init(loaded text: String) { self.text = text }
}
