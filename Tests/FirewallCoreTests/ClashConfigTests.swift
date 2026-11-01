import Testing
@testable import FirewallCore

/// 照本机 Clash Verge 写出的 clash-verge.yaml 的样子（mihomo v1.19.21）：块状 YAML、列表和父键同一缩进、值可能带单引号。
/// 地址换成文档用的 198.51.100.x 和 example 域名
private let runtimeConfig = """
mode: rule
mixed-port: 7897
secret: set-your-secret
dns:
  enable: true
  listen: 127.0.0.1:7874
  nameserver:
  - 198.51.100.53
  - tls://198.51.100.54
  - https://doh.example/dns-query
  - '198.51.100.55:5353'
  - https://[2001:db8::53]/dns-query
  proxy-server-nameserver:
  - udp://127.0.0.1:7874
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
  - '*.lan'
  enhanced-mode: fake-ip
tun:
  device: utun1024
  dns-hijack:
  - any:53
proxies:
- name: 'Traffic: 1.09 GB | 150 GB'
  server: node-a.example
  port: 10015
  type: ss
  plugin-opts:
    host: cdn.example
    server: not-a-node.example
- name: HK 01
  type: ss
  server: 'node-b.example'
  port: 10016
- name: HK 02
  server: node-a.example
  port: 10017
- name: Raw
  server: 198.51.100.7
  port: 443
proxy-groups:
- name: Proxies
  type: select
  proxies:
  - HK 01
rules:
- GEOIP,CN,DIRECT
- MATCH,Proxies
"""

@Suite struct ClashConfig {
    @Test func readsNodeServersInOrderWithoutDuplicates() throws {
        let c = try ClashRuntimeConfig(yaml: runtimeConfig)
        // plugin-opts 底下的 server 不是节点
        #expect(c.servers == ["node-a.example", "node-b.example", "198.51.100.7"])
    }

    @Test func readsTheResolverMihomoUsesForNodes() throws {
        #expect(try ClashRuntimeConfig(yaml: runtimeConfig).nodeResolvers == [DNSServer(address: IPNetwork("127.0.0.1")!, port: 7874)])
    }

    /// mihomo 直连的 DNS 上游里写成 IP 的那些；写成域名的（DoH 等）不在其列
    @Test func readsUpstreamsWrittenAsAddresses() throws {
        #expect(try ClashRuntimeConfig(yaml: runtimeConfig).upstreamAddresses
            == ["198.51.100.53", "198.51.100.54", "198.51.100.55", "2001:db8::53", "127.0.0.1"].map { IPNetwork($0)! })
    }

    @Test func readsTheFakeIPRange() throws {
        #expect(try ClashRuntimeConfig(yaml: runtimeConfig).fakeIPRange == IPNetwork("198.18.0.1/16"))
    }

    /// 没写 fake-ip-range 时 mihomo 用 198.18.0.1/16
    /// @see https://wiki.metacubex.one/config/dns/#fake-ip-range
    @Test func fakeIPRangeDefaultsToMihomos() throws {
        let yaml = runtimeConfig.replacingOccurrences(of: "  fake-ip-range: 198.18.0.1/16\n", with: "")
        #expect(try ClashRuntimeConfig(yaml: yaml).fakeIPRange == IPNetwork("198.18.0.1/16"))
    }

    /// 订阅没展开时节点不在这个文件里，放行表会漏掉它们
    @Test func refusesProxyProviders() {
        let yaml = runtimeConfig + "\nproxy-providers:\n  sub:\n    type: http\n"
        #expect(throws: ClashConfigError.proxyProviders) { try ClashRuntimeConfig(yaml: yaml) }
    }

    @Test func refusesNoNodes() {
        let yaml = runtimeConfig.replacingOccurrences(of: "proxies:\n- name: 'Traffic", with: "other:\n- name: 'Traffic")
        #expect(throws: ClashConfigError.noNodes) { try ClashRuntimeConfig(yaml: yaml) }
    }

    /// 写成一行的列表这里认不出来，宁可拒绝也不当成没有
    @Test func refusesInlineLists() {
        let yaml = runtimeConfig.replacingOccurrences(of: "  proxy-server-nameserver:\n  - udp://127.0.0.1:7874\n",
                                                      with: "  proxy-server-nameserver: [udp://127.0.0.1:7874]\n")
        #expect(throws: ClashConfigError.unsupported(line: 13)) { try ClashRuntimeConfig(yaml: yaml) }
    }
}

extension ClashConfig {
    /// 构造过的配置：节点很多时去重和建表不能是平方的（数组 contains），否则塞满上限的文件能把 root 的开启命令拖上几个小时
    @Test(.timeLimit(.minutes(1)))
    func manyNodesStayLinear() throws {
        let count = 200_000
        let nodes = (0..<count).map { "- name: n\($0)\n  server: 10.\($0 >> 16).\($0 >> 8 & 0xFF).\($0 & 0xFF)\n" }.joined()
        let config = try ClashRuntimeConfig(yaml: "dns:\n  proxy-server-nameserver:\n  - udp://127.0.0.1:7874\nproxies:\n" + nodes)
        #expect(config.servers.count == count)
        #expect(try config.clashTable(limit: .max) { _, _ in nil }.count == count + 1)
    }

    @Test func readsCRLFLikeLF() throws {
        let crlf = runtimeConfig.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try ClashRuntimeConfig(yaml: crlf) == ClashRuntimeConfig(yaml: runtimeConfig))
    }

    /// 写成一行的节点里的 server 读不出来，拒绝而不是当成没有
    @Test func refusesInlineNodes() {
        let yaml = runtimeConfig.replacingOccurrences(of: "- name: Raw\n  server: 198.51.100.7\n  port: 443\n",
                                                      with: "- {name: Raw, server: 198.51.100.7, port: 443}\n")
        #expect(throws: ClashConfigError.unsupported(line: 38)) { try ClashRuntimeConfig(yaml: yaml) }
    }

    /// 上游列表缩进得比键深：认不出，拒绝而不是漏掉上游
    @Test func refusesIndentedUpstreamLists() {
        let yaml = runtimeConfig.replacingOccurrences(of: "  - 198.51.100.53\n", with: "    - 198.51.100.53\n")
        #expect(throws: ClashConfigError.unsupported(line: 8)) { try ClashRuntimeConfig(yaml: yaml) }
    }

    /// WireGuard 节点的 server 写在 peers 列表里
    @Test func readsWireGuardPeers() throws {
        let yaml = runtimeConfig.replacingOccurrences(of: "- name: Raw\n  server: 198.51.100.7\n",
                                                      with: "- name: WG\n  type: wireguard\n  peers:\n  - server: 198.51.100.8\n    port: 51820\n- name: Raw\n  server: 198.51.100.7\n")
        #expect(try ClashRuntimeConfig(yaml: yaml).servers == ["node-a.example", "node-b.example", "198.51.100.8", "198.51.100.7"])
    }
}

@Suite struct IPNetworks {
    @Test(arguments: [("198.51.100.7", "198.51.100.7/32"), ("198.51.100.0/24", "198.51.100.0/24"),
                      ("2001:db8::53", "2001:db8::53/128"), ("2001:db8::/32", "2001:db8::/32")])
    func parsesAndPrints(_ text: String, _ printed: String) {
        #expect(IPNetwork(text)?.description == printed)
    }

    @Test(arguments: ["", "198.51.100", "198.51.100.7/33", "2001:db8::/129", "node.example", "198.51.100.7/", "198.51.100.7/-1"])
    func rejects(_ text: String) {
        #expect(IPNetwork(text) == nil)
    }

    @Test func containment() throws {
        let range = try #require(IPNetwork("198.18.0.1/15"))
        #expect(range.contains(try #require(IPNetwork("198.19.255.255"))))
        #expect(!range.contains(try #require(IPNetwork("198.20.0.0"))))
        #expect(!range.contains(try #require(IPNetwork("::ffff:198.18.0.1"))))
    }
}

/// `<clash>` 表：节点（域名向 mihomo 查节点用的上游查）加写成 IP 的 DNS 上游
@Suite struct ClashTable {
    private let config = try! ClashRuntimeConfig(yaml: runtimeConfig)
    private let resolver = DNSServer(address: IPNetwork("127.0.0.1")!, port: 7874)

    @Test func resolvesNodeDomainsAndAddsUpstreams() throws {
        var asked: [String] = []
        let table = try config.clashTable { name, server in
            #expect(server == resolver)
            asked.append(name)
            return ["node-a.example": ["198.51.100.1", "2001:db8::1"], "node-b.example": ["198.51.100.2"]][name]?.map { IPNetwork($0)! }
        }
        #expect(asked == ["node-a.example", "node-b.example"])
        #expect(table == ["198.51.100.1", "2001:db8::1", "198.51.100.2", "198.51.100.7",
                          "198.51.100.53", "198.51.100.54", "198.51.100.55", "2001:db8::53", "127.0.0.1"].map { IPNetwork($0)! })
    }

    /// 查回来是 fake-ip：mihomo 拿它当真地址连不出去，放行它也没用，节点等于漏了
    @Test func refusesFakeIPAnswers() {
        #expect(throws: AllowTableError.fakeAnswer(node: 2)) {
            try config.clashTable { name, _ in [IPNetwork(name == "node-b.example" ? "198.18.0.9" : "198.51.100.1")!] }
        }
    }

    @Test func refusesNodesThatDoNotResolve() {
        #expect(throws: AllowTableError.unresolved(node: 1)) { try config.clashTable { _, _ in nil } }
        #expect(throws: AllowTableError.unresolved(node: 1)) { try config.clashTable { _, _ in [] } }
    }

    @Test func refusesDomainNodesWithoutAResolver() throws {
        let yaml = runtimeConfig.replacingOccurrences(of: "  - udp://127.0.0.1:7874\n", with: "  - https://doh.example/dns-query\n")
        #expect(throws: AllowTableError.noResolver) { try ClashRuntimeConfig(yaml: yaml).clashTable { _, _ in nil } }
    }

    /// 域名节点太多：每个要问两次 dig，构造过的配置能把开启拖上几小时，拍出的表还可能超过 pf 的表项上限。拒绝
    @Test func refusesTooManyDomainNodes() throws {
        let nodes = (0...ClashRuntimeConfig.maxDomainNodes).map { "- name: n\($0)\n  server: n\($0).example\n" }.joined()
        let config = try ClashRuntimeConfig(yaml: "dns:\n  proxy-server-nameserver:\n  - udp://127.0.0.1:7874\nproxies:\n" + nodes)
        var asked = 0
        #expect(throws: AllowTableError.tooManyNodes) { try config.clashTable { _, _ in asked += 1; return [IPNetwork("198.51.100.1")!] } }
        #expect(asked == 0)
    }

    /// 表项有上限：留给 `<clash>` 的名额不够就报错
    @Test func refusesATableOverItsLimit() throws {
        let config = try ClashRuntimeConfig(yaml: runtimeConfig)
        let resolve = { (_: String, _: DNSServer) in [IPNetwork("198.51.100.1")!] }
        #expect(try config.clashTable(limit: 7, resolve: resolve).count == 7)
        #expect(throws: AllowTableError.tooManyEntries) { try config.clashTable(limit: 6, resolve: resolve) }
    }

    /// 上游失败一次就不再问：它没起来时，每个节点都空等一遍超时，开启会一声不响地跑很久
    @Test func stopsAskingAResolverThatFailed() throws {
        let yaml = runtimeConfig.replacingOccurrences(of: "  - udp://127.0.0.1:7874\n", with: "  - udp://127.0.0.1:7874\n  - 198.51.100.53\n")
        let config = try ClashRuntimeConfig(yaml: yaml)
        var asked: [Int] = []
        let table = try config.clashTable { _, server in
            asked.append(server.port)
            return server.port == 7874 ? nil : [IPNetwork("198.51.100.1")!]
        }
        #expect(asked == [7874, 53, 53])
        #expect(table.first == IPNetwork("198.51.100.1"))
    }

    /// 域名原样当参数交给 root 跑的 dig：长得不像域名（比如 `-` `+` 开头会被当成选项）就不查
    @Test(arguments: ["-f/etc/passwd", "+tcp", "a b.example", "node.example;", ""])
    func refusesNamesThatAreNotDomains(_ name: String) throws {
        let yaml = runtimeConfig.replacingOccurrences(of: "  server: 'node-b.example'\n", with: "  server: '\(name)'\n")
        #expect(throws: (any Error).self) { try ClashRuntimeConfig(yaml: yaml).clashTable { _, _ in [IPNetwork("198.51.100.1")!] } }
    }
}
