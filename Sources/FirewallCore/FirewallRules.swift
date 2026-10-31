/// 回答：本 anchor 里装什么规则。照搬 Mullvad 的 macOS pf 规则，偏差和原因见 docs/firewall.md §4。
/// 不知道规则怎么装进 pf、装没装上，也不知道放行表里有什么。
/// @see https://github.com/mullvad/mullvadvpn-app/blob/33a63e2916adf294d3b4332c4274e2aa1cb1f811/talpid-core/src/firewall/macos.rs
public struct FirewallRules: Equatable, Sendable {
    /// 交给 `pfctl -a <anchor> -f -` 的全文
    public let text: String

    /// block 拦谁
    public enum Scope: String, Codable, Sendable {
        /// 正式规则：除隧道、局域网和两张放行表外一律拦
        case everyone
        /// 测试规则：block 只拦去（来自）测试表 `<test>` 的流量，其余照常上网，测试时不真的断网（docs/firewall.md §7）
        case testTable
    }

    /// 两张放行表和测试表的文件名（在 `directory` 下）；恢复脚本和安装脚本里也有，改了一起改
    public static let clashTableFile = "clash.table", cnTableFile = "cn.table", testTableFile = "test.table"

    /// `tunnel` 是 Clash 的 TUN 网卡名；会原样拼进 root 加载的规则，所以只收 BSD 网卡名的样子（小写字母开头、数字结尾），别的返回 `nil`。
    /// `directory` 是放行表文件所在的目录（root 0755，docs/firewall.md §4）。
    /// 哪种规则都不写 `user` / `group`：它们让 pf 在内核里死锁、只能重启（§5）
    public init?(tunnel: String, scope: Scope = .everyone, directory: String) {
        let letters = tunnel.prefix { ("a"..."z").contains($0) }
        let digits = tunnel.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        // 目录是调用方写死的常量，带引号或换行就是代码写错了
        guard !directory.contains(where: { $0 == "\"" || $0.isNewline }) else { preconditionFailure("表目录不能带引号或换行") }
        let test = scope == .testTable
        let table = { (name: String, file: String) in "table <\(name)> file \"\(directory)/\(file)\"\n" }
        text = """
        tun  = "\(tunnel)"
        lan4 = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }"
        mc4  = "{ 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 }"
        lan6 = "{ fe80::/10, fc00::/7 }"
        mc6  = "{ ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 }"
        \(table("clash", Self.clashTableFile))\(table("cn", Self.cnTableFile))\(test ? table("test", Self.testTableFile) : "")pass quick on lo0 no state
        pass quick on $tun no state
        pass out quick inet6 proto icmp6 icmp6-type { 133, 135, 136 }
        pass in  quick inet6 proto icmp6 icmp6-type { 134, 135, 136, 137 }
        pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67
        pass in  quick inet proto udp from any port 67 to any port 68
        pass out quick to <clash>
        block return out quick proto { tcp, udp } to \(test ? "<test>" : "any") port 53
        pass out quick to <cn>
        pass out quick to $lan4
        pass in  quick from $lan4
        pass out quick to $lan6
        pass in  quick from $lan6
        pass out quick to { $mc4, $mc6 }
        block return out quick \(test ? "to <test>" : "all")
        block drop   in  quick \(test ? "from <test>" : "all")

        """
    }
}
