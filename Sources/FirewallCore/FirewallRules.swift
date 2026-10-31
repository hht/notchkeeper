/// 回答：本 anchor 里装什么规则。照搬 Mullvad 的 macOS pf 规则，偏差和原因见 docs/firewall.md §4。
/// 不知道规则怎么装进 pf、装没装上。
/// @see https://github.com/mullvad/mullvadvpn-app/blob/33a63e2916adf294d3b4332c4274e2aa1cb1f811/talpid-core/src/firewall/macos.rs
public struct FirewallRules: Equatable, Sendable {
    /// 交给 `pfctl -a <anchor> -f -` 的全文
    public let text: String

    /// block 拦谁
    public enum Scope: String, Codable, Sendable {
        /// 正式规则：除隧道、局域网和 root 外一律拦
        case everyone
        /// 测试规则：block 只拦 `nobody`，其余进程照常上网，测试时不真的断网（docs/firewall.md §7）。
        /// pf 的 `user` 只匹配 TCP / UDP，所以这几条 block 都带上 proto
        case testUser
    }

    /// `tunnel` 是 Clash 的 TUN 网卡名；会原样拼进 root 加载的规则，所以只收 BSD 网卡名的样子（小写字母开头、数字结尾），别的返回 `nil`
    public init?(tunnel: String, scope: Scope = .everyone) {
        let letters = tunnel.prefix { ("a"..."z").contains($0) }
        let digits = tunnel.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        let (only, tcpUDP) = scope == .testUser ? (" user nobody", "proto { tcp, udp } ") : ("", "")
        text = """
        tun  = "\(tunnel)"
        lan4 = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }"
        mc4  = "{ 255.255.255.255, 224.0.0.0/24, 239.0.0.0/8 }"
        lan6 = "{ fe80::/10, fc00::/7 }"
        mc6  = "{ ff01::/16, ff02::/16, ff03::/16, ff04::/16, ff05::/16 }"
        pass quick on lo0 no state
        pass quick on $tun no state
        pass out quick inet6 proto icmp6 icmp6-type { 133, 135, 136 }
        pass in  quick inet6 proto icmp6 icmp6-type { 134, 135, 136, 137 }
        pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67
        pass in  quick inet proto udp from any port 67 to any port 68
        pass out quick proto { tcp, udp } all user root
        block return out quick proto { tcp, udp } to any port 53\(only)
        pass out quick to $lan4
        pass in  quick from $lan4
        pass out quick to $lan6
        pass in  quick from $lan6
        pass out quick to { $mc4, $mc6 }
        block return out quick \(tcpUDP)all\(only)
        block drop   in  quick \(tcpUDP)all\(only)

        """
    }
}
