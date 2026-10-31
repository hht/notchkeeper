/// 回答：开着的防火墙此刻真的在拦吗（docs/firewall.md §4「核对」、§5「fail-open」）。
/// 任何一项不过，App 都不能显示「已保护」。只解析 pfctl / ifconfig 的输出，不知道它们怎么来的。
public struct FirewallCheck: Codable, Equatable, Sendable {
    /// pf 开着（`pfctl -s info` 是 `Status: Enabled`）：有人 pfctl -d 后规则还在 anchor 里也不生效。
    /// `nil` 是读不出：和明确停了分开，停了说明所有引用都被作废了
    public var pfEnabled: Bool?
    /// 主规则集里还有 `anchor "com.apple/*"`：有人 `pfctl -f` 换掉主规则集，本 anchor 就不再被求值
    public var anchorPointPresent: Bool
    /// 本 anchor 里有规则
    public var rulesLoaded: Bool
    /// 本 anchor 各条规则 Evaluations 的和；读不出数字时 `nil`
    public var evaluations: UInt64?
    /// 比上一轮涨了：本 anchor 真的在被求值。`nil` 是没有上一轮可比（刚装上、刚重装、读不出数字）
    public var evaluationsGrowing: Bool?
    /// TUN 网卡在：网卡名写错或 Clash 改了名，规则会把所有流量都拦掉（往安全方向出错），要让人看得出来
    public var tunnelPresent: Bool

    public init(pfEnabled: Bool?, anchorPointPresent: Bool, rulesLoaded: Bool, evaluations: UInt64?, evaluationsGrowing: Bool?, tunnelPresent: Bool) {
        self.pfEnabled = pfEnabled
        self.anchorPointPresent = anchorPointPresent
        self.rulesLoaded = rulesLoaded
        self.evaluations = evaluations
        self.evaluationsGrowing = evaluationsGrowing
        self.tunnelPresent = tunnelPresent
    }

    /// - Parameters:
    ///   - mainRules: `pfctl -sr` 的 stdout，anchor 点是一行 `anchor "com.apple/*" all`（本机实测）；比到右引号，`anchor "com.apple.internet-sharing"` 不算
    ///   - anchorRules: `pfctl -a <anchor> -vsr` 的 stdout，每条规则下一行是 `[ Evaluations: <n> … ]`
    ///   - info: `pfctl -s info` 的 stdout，第一行是 `Status: Enabled …` 或 `Status: Disabled …`（本机实测）
    ///   - interfaces: `ifconfig -l` 的 stdout
    ///   - previousEvaluations: 上一轮的 `evaluations`
    /// 哪一条命令失败了，调用方传空串：每一项都判不过
    public init(mainRules: String, anchorRules: String, info: String, interfaces: String, tunnel: String, previousEvaluations: UInt64?) {
        pfEnabled = info.hasPrefix("Status: Enabled") ? true : info.hasPrefix("Status: Disabled") ? false : nil
        anchorPointPresent = mainRules.split(separator: "\n").contains { $0.hasPrefix(#"anchor "com.apple/*""#) }
        let lines = anchorRules.split(separator: "\n")
        let ruleCount = lines.filter { !$0.hasPrefix(" ") }.count
        let counts = lines.compactMap { line -> UInt64? in
            let words = line.split(separator: " ")
            return words.firstIndex(of: "Evaluations:").flatMap { words.indices.contains($0 + 1) ? UInt64(words[$0 + 1]) : nil }
        }
        rulesLoaded = ruleCount > 0
        // 每条规则都要有一个读得出的数，少一个都不算；&+ 不会因溢出让 root 守护进程崩掉
        evaluations = rulesLoaded && counts.count == ruleCount ? counts.reduce(0, &+) : nil
        evaluationsGrowing = evaluations.flatMap { now in previousEvaluations.map { now > $0 } }
        tunnelPresent = interfaces.split(whereSeparator: \.isWhitespace).contains { $0 == tunnel }
    }

    /// 都过了才算在拦。没有上一轮可比（`evaluationsGrowing == nil`）不算不过：刚装上的那一轮不该报异常；
    /// 读不出 Evaluations 的数字算不过，否则格式变了就永远比不出来、永远「过」
    public var passed: Bool {
        pfEnabled == true && anchorPointPresent && rulesLoaded && tunnelPresent && evaluations != nil && evaluationsGrowing != false
    }
}

/// 回答：pfctl 命令的输出里认出什么。格式按本机实测（docs/firewall.md §6）
public enum PFOutput {
    /// `pfctl -E` 的 stderr 里恰好一行 `Token : <数字>`；认不出（没有、不是数字、不止一行）是 `nil`
    public static func token(fromEnable stderr: String) -> String? {
        let tokens = stderr.split(separator: "\n").compactMap { line -> Substring? in
            guard line.hasPrefix("Token : ") else { return nil }
            return line.dropFirst("Token : ".count)
        }
        guard tokens.count == 1, let t = tokens.first, !t.isEmpty, t.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return String(t)
    }
}

extension PFOutput {
    /// `pfctl -s References` 的 stdout 里有哪些 token。每行是 PID、进程名、token、`<n> days HH:MM:SS`；
    /// 进程名可能带空格，所以 token 从行尾往前数第 4 列。认不出格式（没有表头、某行对不上）是 `nil`，不是「一个都没有」
    public static func tokens(fromReferences stdout: String) -> Set<String>? {
        let lines = stdout.split(separator: "\n")
        guard let header = lines.firstIndex(where: { $0.hasPrefix("PID") }) else { return nil }
        var tokens: Set<String> = []
        for line in lines[(header + 1)...] {
            let fields = line.split(separator: " ")
            guard fields.count >= 5, fields[fields.count - 2] == "days",
                  case let t = fields[fields.count - 4], t.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            tokens.insert(String(t))
        }
        return tokens
    }
}
