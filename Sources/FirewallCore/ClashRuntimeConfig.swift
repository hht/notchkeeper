import Foundation

/// 回答：Clash Verge 的运行时配置（mihomo 用 `-f` 加载的 `clash-verge.yaml`）里，mihomo 自己会直连哪些地址、节点域名该向谁查。
/// 只读这几样，别的字段（含密码）一概不看、不留；不知道文件在哪、怎么解析域名（docs/firewall.md §4「开启时拍放行表的快照」）。
///
/// 不是通用的 YAML 解析：Clash Verge 写出的是块状 YAML，列表和父键同一缩进，顶层键顶格、`dns` 下的键缩进两格。
/// 读到的几个键写成别的样子（一行的 `[…]`、`{…}`）就拒绝，宁可开不了也不当成没有
public struct ClashRuntimeConfig: Equatable, Sendable {
    /// 节点的 `server`，按出现顺序去重：IP 或域名
    public var servers: [String]
    /// mihomo 查节点域名用的上游：`proxy-server-nameserver` 里明文 UDP、写成 IP 的那些
    public var nodeResolvers: [DNSServer]
    /// mihomo 直连的 DNS 上游里写成 IP 的那些（写成域名的不在内）。`nameserver-policy` 里的不读：漏了只是那些域名查不了，不会漏流量
    public var upstreamAddresses: [IPNetwork]
    /// 查回来落在这里的是 fake-ip，不是真地址
    public var fakeIPRange: IPNetwork

    /// 域名节点最多几个。真实订阅几十到几百个；每个开启时要问两次 DNS
    public static let maxDomainNodes = 2000

    /// mihomo 没写 `fake-ip-range` 时用的。@see https://wiki.metacubex.one/config/dns/#fake-ip-range
    static let defaultFakeIPRange = IPNetwork("198.18.0.1/16")!
    /// mihomo 会直连的 DNS 上游列表。@see https://wiki.metacubex.one/config/dns/
    private static let upstreamKeys: Set<Substring> = ["default-nameserver", "nameserver", "fallback", "proxy-server-nameserver", "direct-nameserver"]

    public init(yaml: String) throws(ClashConfigError) {
        // 去重用 Set：外部文件，节点可能很多，数组 contains 是平方的
        var servers: [String] = [], seenServers: Set<String> = []
        var resolvers: [DNSServer] = []
        var upstreams: [IPNetwork] = [], seenUpstreams: Set<IPNetwork> = []
        var fakeIPRange: IPNetwork?
        var providers = false
        var section: Substring?
        var dnsKey: Substring?
        // 按 isNewline 切：Swift 把 "\r\n" 当成一个字符，按 "\n" 切不开 CRLF 文件
        for (index, line) in yaml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let unsupported = ClashConfigError.unsupported(line: index + 1)
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if body.isEmpty || body.first == "#" { continue }
            let item = body.hasPrefix("- ")

            if indent == 0, !item {
                guard let (key, value) = Self.keyValue(body) else { throw unsupported }
                (section, dnsKey) = (key, nil)
                switch key {
                case "proxy-providers": if !value.isEmpty, value != "{}" { throw unsupported }
                case "proxies", "dns": if !value.isEmpty { throw unsupported }
                default: break
                }
                continue
            }
            switch section {
            case "proxy-providers":
                providers = true
            case "proxies":
                // 每个节点是一个 `- ` 开头的 map，字段比 `- ` 多缩进两格；更深的是 plugin-opts 之类，里面的 server 不是节点。
                // 字段里的列表项（缩进两格的 `- `）只有 WireGuard 的 peers 带 server。写成一行的节点读不出 server，拒绝
                if indent == 0, item, body.dropFirst(2).first == "{" { throw unsupported }
                let (field, level) = (indent == 0 || indent == 2) && item ? (body.dropFirst(2), 2) : (body, indent)
                guard level == 2, let (key, value) = Self.keyValue(field), key == "server" else { continue }
                guard let server = Self.scalar(value), !server.isEmpty else { throw unsupported }
                if seenServers.insert(server).inserted { servers.append(server) }
            case "dns" where indent == 2 && !item:
                guard let (key, value) = Self.keyValue(body) else { throw unsupported }
                dnsKey = key
                if key == "fake-ip-range" {
                    guard let range = Self.scalar(value).flatMap(IPNetwork.init) else { throw unsupported }
                    fakeIPRange = range
                } else if Self.upstreamKeys.contains(key), !value.isEmpty {
                    throw unsupported
                }
            case "dns" where indent > 2 && item:
                // 上游列表缩进得比键深：这里只认和键同一缩进的，认不出就拒绝，免得漏掉上游
                if let key = dnsKey, Self.upstreamKeys.contains(key) { throw unsupported }
            case "dns" where indent == 2 && item:
                guard let key = dnsKey, Self.upstreamKeys.contains(key) else { continue }
                guard let entry = Self.scalar(body.dropFirst(2)) else { throw unsupported }
                let upstream = DNSUpstream(entry)
                if let address = upstream.address, seenUpstreams.insert(address).inserted { upstreams.append(address) }
                if key == "proxy-server-nameserver", let server = upstream.plainUDP { resolvers.append(server) }
            default:
                continue
            }
        }
        guard !providers else { throw .proxyProviders }
        guard !servers.isEmpty else { throw .noNodes }
        self.servers = servers
        nodeResolvers = resolvers
        upstreamAddresses = upstreams
        self.fakeIPRange = fakeIPRange ?? Self.defaultFakeIPRange
    }

    /// `key: value` 或 `key:`；键不带引号（读的这几个键都不带）
    private static func keyValue(_ s: Substring) -> (Substring, Substring)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let rest = s[s.index(after: colon)...]
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (s[..<colon], rest.drop { $0 == " " })
    }

    /// 单引号、不带转义的双引号、裸值（去掉 ` #` 起的注释）；认不出返回 `nil`
    private static func scalar(_ s: Substring) -> String? {
        let v = s.drop { $0 == " " }
        if v.first == "'" {
            guard v.count >= 2, v.last == "'" else { return nil }
            return v.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        if v.first == "\"" {
            guard v.count >= 2, v.last == "\"", !v.contains("\\") else { return nil }
            return String(v.dropFirst().dropLast())
        }
        let plain = v.range(of: " #").map { v[..<$0.lowerBound] } ?? v
        return String(plain.reversed().drop { $0 == " " }.reversed())
    }
}

public enum ClashConfigError: Error, Equatable {
    /// 订阅没展开在文件里（`proxy-providers`），节点地址拿不到
    case proxyProviders
    case noNodes
    /// 这一行写成了认不出的样子；不报内容，免得把配置里的密钥带进日志
    case unsupported(line: Int)
}

/// 一个明文 UDP 的 DNS 服务器
public struct DNSServer: Equatable, Sendable {
    public var address: IPNetwork
    public var port: Int
    public init(address: IPNetwork, port: Int) { (self.address, self.port) = (address, port) }
}

/// mihomo 的一条 DNS 上游：`223.5.5.5`、`198.51.100.53:5353`、`udp://…`、`tls://…`、`https://[2001:db8::53]/dns-query`、带 `#…` 参数的
/// @see https://wiki.metacubex.one/config/dns/
struct DNSUpstream {
    /// 写成 IP 的主机；写成域名（或 `system`、`dhcp://…`）是 `nil`
    let address: IPNetwork?
    /// 明文 UDP（没写协议或 `udp://`）时的服务器
    let plainUDP: DNSServer?

    init(_ entry: String) {
        var rest = Substring(entry.prefix { $0 != "#" })
        var scheme: Substring = "udp"
        if let r = rest.range(of: "://") {
            scheme = rest[..<r.lowerBound]
            rest = rest[r.upperBound...]
        }
        let authority = rest.prefix { $0 != "/" }
        var host = authority
        var port: Int? = 53
        if authority.first == "[" {
            // [v6] 或 [v6]:端口
            guard let close = authority.firstIndex(of: "]") else { (address, plainUDP) = (nil, nil); return }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let tail = authority[authority.index(after: close)...]
            if !tail.isEmpty { port = tail.first == ":" ? Int(tail.dropFirst()) : nil }
        } else if authority.filter({ $0 == ":" }).count == 1, let colon = authority.firstIndex(of: ":") {
            // v4:端口；不带括号、多个冒号的是裸 IPv6
            host = authority[..<colon]
            port = Int(authority[authority.index(after: colon)...])
        }
        let ip = IPNetwork(String(host)).flatMap { $0.prefix == $0.bytes.count * 8 ? $0 : nil }
        address = ip
        if let ip, let port, scheme == "udp" { plainUDP = DNSServer(address: ip, port: port) } else { plainUDP = nil }
    }
}

extension ClashRuntimeConfig {
    /// `<clash>` 表：节点地址（域名用 `resolve` 依次问 `nodeResolvers`，问到为止）加写成 IP 的 DNS 上游，去重、按出现顺序。
    /// 有一个节点查不到、或答案落在 fake-ip 段里就报错：放行表漏了节点，开着防火墙时 Clash 连不上它。
    /// `resolve` 返回 `nil` 是那个上游没回应：之后不再问它，免得每个节点都空等一遍超时。超过 `limit` 项报错：pf 装不下
    public func clashTable(limit: Int = CountryDatabase.maxTableEntries, resolve: (String, DNSServer) -> [IPNetwork]?) throws(AllowTableError) -> [IPNetwork] {
        guard servers.count(where: { IPNetwork($0) == nil }) <= Self.maxDomainNodes else { throw .tooManyNodes }
        var table: [IPNetwork] = [], seen: Set<IPNetwork> = []
        func add(_ n: IPNetwork) throws(AllowTableError) {
            guard seen.insert(n).inserted else { return }
            guard table.count < limit else { throw .tooManyEntries }
            table.append(n)
        }
        var silent: Set<Int> = []
        for (index, server) in servers.enumerated() {
            let node = index + 1
            if let ip = IPNetwork(server), ip.prefix == ip.bytes.count * 8 {
                try add(ip)
                continue
            }
            guard Self.isDomain(server) else { throw .notADomain(node: node) }
            guard !nodeResolvers.isEmpty else { throw .noResolver }
            var answers: [IPNetwork] = []
            for (i, resolver) in nodeResolvers.enumerated() where answers.isEmpty && !silent.contains(i) {
                if let a = resolve(server, resolver) { answers = a } else { silent.insert(i) }
            }
            guard !answers.isEmpty else { throw .unresolved(node: node) }
            guard !answers.contains(where: fakeIPRange.contains) else { throw .fakeAnswer(node: node) }
            for a in answers { try add(a) }
        }
        for a in upstreamAddresses { try add(a) }
        return table
    }

    /// 字母、数字、`-`、`_`、`.`，字母或数字开头。会原样交给 root 跑的 dig，`-`、`+` 开头会被当成选项
    static func isDomain(_ s: String) -> Bool {
        let alphanumeric = { (c: Unicode.Scalar) in c.isASCII && CharacterSet.alphanumerics.contains(c) }
        guard let first = s.unicodeScalars.first, alphanumeric(first) else { return false }
        return s.unicodeScalars.allSatisfy { alphanumeric($0) || "-_.".unicodeScalars.contains($0) }
    }
}

/// 拍 `<clash>` 表失败；按节点在配置里的序号（从 1 起）报，不报域名和地址
public enum AllowTableError: Error, Equatable {
    /// 域名节点多得不像真的订阅：每个要问两次 DNS，开启会拖很久，表也可能装不进 pf
    case tooManyNodes
    /// 表项超过留给它的名额：pf 装不下
    case tooManyEntries
    /// 节点写的是域名，配置里却没有能直接问的明文 UDP 上游（`proxy-server-nameserver`）
    case noResolver
    case unresolved(node: Int)
    case fakeAnswer(node: Int)
    case notADomain(node: Int)
}
