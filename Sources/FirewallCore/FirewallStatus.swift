import Foundation

/// 回答：守护进程这一轮看到的防火墙是什么样，以什么格式交给 App（`firewall-status.json`，root 0644，docs/firewall.md §4）。
/// App 只读它，不常驻特权代码；新不新鲜、算不算「已保护」由读的一方按 `checkedAt` 判。不知道文件放在哪、怎么写。
public struct FirewallStatus: Codable, Equatable, Sendable {
    public static let fileName = "firewall-status.json"

    public enum Mode: String, Codable, Sendable {
        case off, trial, on
        /// 防火墙状态文件读不出来：按 off 办（清规则、不覆盖原文件），要报出来
        case stateUnreadable
    }

    public var mode: Mode
    /// 装的是哪种规则；`nil` 是不知道。只有 `.everyone` 才算真的在拦（测试规则只拦 nobody），App 据此决定能不能显示「已保护」
    public var scope: FirewallRules.Scope?
    /// 试运行到几点结束（墙上时间，只给界面倒计时用；真正的截止按单调时钟，见 `FirewallState`）
    public var trialEndsAt: Date?
    /// 只有开着时才核对
    public var check: FirewallCheck?
    /// 这一轮做失败的 pf 动作，下一轮会重做
    public var failedSteps: [PFStep]
    public var checkedAt: Date

    public init(mode: Mode, scope: FirewallRules.Scope?, trialEndsAt: Date? = nil, check: FirewallCheck? = nil,
                failedSteps: [PFStep] = [], checkedAt: Date) {
        self.mode = mode
        self.scope = scope
        self.trialEndsAt = trialEndsAt
        self.check = check
        self.failedSteps = failedSteps
        self.checkedAt = checkedAt
    }

    /// 缺字段用默认值，多的字段忽略（CLAUDE.md「配置与状态文件」）；`checkedAt` 没有就解不开：没有它判断不了新鲜
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .off
        scope = try c.decodeIfPresent(FirewallRules.Scope.self, forKey: .scope)
        trialEndsAt = try c.decodeIfPresent(Date.self, forKey: .trialEndsAt)
        check = try c.decodeIfPresent(FirewallCheck.self, forKey: .check)
        failedSteps = try c.decodeIfPresent([PFStep].self, forKey: .failedSteps) ?? []
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> FirewallStatus {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(FirewallStatus.self, from: data)
    }
}
