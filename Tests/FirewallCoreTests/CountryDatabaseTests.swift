import Testing
@testable import FirewallCore

/// MaxMind DB 格式：搜索树 + 16 字节 0 + 数据区 + 元数据标记 + 元数据。
/// @see https://maxmind.github.io/MaxMind-DB/
@Suite struct CountryNetworks {
    @Test func collectsTheCountrysNetworksAndMergesNeighbours() throws {
        let db = MMDB(ipVersion: 6)
        let cnA = db.record(country: "CN")
        let cnB = db.record(countryPointer: cnA) // 同是 CN、数据不同（GeoLite2 按城市等细节拆开），相邻就合并
        let us = db.record(country: "US")
        db.insert("::198.51.100.0/121", cnA)
        db.insert("::198.51.100.128/121", cnB)
        db.insert("::203.0.113.0/120", us)
        db.insert("2001:db8::/32", cnA)
        // IPv4 子树在 IPv6 库里还挂在 ::ffff:0:0/96 下（别名），只走一遍、按 IPv4 写
        db.alias("::ffff:0:0/96", to: "::/96")
        #expect(try CountryDatabase.networks(country: "CN", in: db.bytes())
            == ["198.51.100.0/24", "2001:db8::/32"].map { IPNetwork($0)! })
    }

    @Test func readsAnIPv4OnlyDatabase() throws {
        let db = MMDB(ipVersion: 4)
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        db.insert("203.0.113.0/24", db.record(country: "US"))
        #expect(try CountryDatabase.networks(country: "CN", in: db.bytes()) == [IPNetwork("198.51.100.0/24")!])
    }

    /// mihomo 按 `country.iso_code` 转小写和规则里的国家比，大小写不敏感
    @Test func matchesTheCodeCaseInsensitively() throws {
        let db = MMDB(ipVersion: 4)
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        #expect(try CountryDatabase.networks(country: "cn", in: db.bytes()) == [IPNetwork("198.51.100.0/24")!])
    }

    @Test(arguments: [[UInt8](), [UInt8](repeating: 0, count: 64), Array("no marker here".utf8)])
    func rejectsWhatIsNotAnMMDB(_ bytes: [UInt8]) {
        #expect(throws: CountryDatabaseError.self) { try CountryDatabase.networks(country: "CN", in: bytes) }
    }

    /// 截断的文件：树里的记录指到数据区外，报错，不越界
    @Test func rejectsATruncatedDataSection() throws {
        let db = MMDB(ipVersion: 4)
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        db.truncateData = true
        #expect(throws: CountryDatabaseError.self) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// 构造过的库：每个节点的两个子节点都指向下一个节点。不去重就要走 2^40 条路，开启命令永远不返回
    @Test func rejectsATreeThatRevisitsANode() {
        let db = MMDB(ipVersion: 4)
        let count = 40
        db.rawTree = (count, (0..<count).flatMap { n -> [UInt8] in
            let next = n + 1 // 最后一个指到 node_count：没有数据
            return [0, 0, UInt8(next), 0, 0, UInt8(next)]
        })
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// 规范不许指针指向指针；允许的话一个记录能套出指数级的解码量
    @Test func rejectsPointersToPointers() {
        let db = MMDB(ipVersion: 4)
        let cn = db.record(country: "CN")
        let hop = db.raw([UInt8(1 << 5), UInt8(cn)])            // 指向 cn 记录的指针
        let record = db.raw([UInt8(7 << 5 | 1)] + [UInt8(2 << 5 | 7)] + Array("country".utf8) + [UInt8(1 << 5), UInt8(hop)])
        db.insert("198.51.100.0/24", record)
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// 构造过的库：很多叶子各指向一个不同的指针，指针都指向同一个大 map（没有 country 键）。每个叶子都扫一遍它，
    /// 耗时是叶子数乘条目数，9 MB 的文件能跑几个小时。解码总量有上限，超了就报错
    @Test func rejectsADatabaseThatMakesLookupsMultiply() {
        let db = MMDB(ipVersion: 4)
        let entries = 20_000
        // map，大小 285 + 后两字节；每个值是布尔 false（扩展类型 14：控制字节 0，扩展字节 14 - 7）
        var big: [UInt8] = [UInt8(7 << 5 | 30), UInt8((entries - 285) >> 8), UInt8((entries - 285) & 0xFF)]
        for i in 0..<entries {
            let key = Array(String(format: "k%05d", i).utf8)
            big += [UInt8(2 << 5 | key.count)] + key + [0x00, 7]
        }
        let target = db.raw(big)
        for octet in 0..<256 {
            db.insert("\(octet).0.0.0/8", db.raw([UInt8(1 << 5 | target >> 8), UInt8(target & 0xFF)])) // 各自一个指向大 map 的指针
        }
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// 构造过的库：很多条记录的 iso_code 都指向同一个大字符串，每条记录都要把它解一遍。额度只按值头次数算挡不住，
    /// 按字节扣，处理的总字节数就不超过文件大小（真库的值只有几个字节）。键名逐字节比、不解字符串，同样的手法用在键上本来就拖不住
    @Test func rejectsRecordsThatAllPointAtOneHugeString() {
        let db = MMDB(ipVersion: 4)
        let size = 20_000
        let big = db.raw([UInt8(2 << 5 | 30), UInt8((size - 285) >> 8), UInt8((size - 285) & 0xFF)]
            + [UInt8](repeating: UInt8(ascii: "x"), count: size))
        for octet in 0..<60 {
            let record = db.raw([UInt8(7 << 5 | 1), UInt8(2 << 5 | 7)] + Array("country".utf8)
                + [UInt8(7 << 5 | 1), UInt8(2 << 5 | 8)] + Array("iso_code".utf8) + [UInt8(1 << 5 | big >> 8), UInt8(big & 0xFF)])
            db.insert("\(octet).0.0.0/8", record)
        }
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// 段数有上限（pf 的表项是全系统共用的，也给内存和耗时封顶）：合并之后还超过就报错，走到一半就停
    @Test func rejectsTooManyNetworks() throws {
        let db = MMDB(ipVersion: 4)
        for third in [0, 2, 4] { db.insert("198.51.\(third).0/24", db.record(country: "CN")) } // 不相邻，合并不起来
        #expect(try CountryDatabase.networks(country: "CN", in: db.bytes(), limit: 3).count == 3)
        #expect(throws: CountryDatabaseError.tooManyNetworks) { try CountryDatabase.networks(country: "CN", in: db.bytes(), limit: 2) }
    }

    /// node_count 是外部数据：大到装不进 Int、乘起来溢出，都报错而不是崩
    @Test func rejectsAHugeNodeCount() {
        let db = MMDB(ipVersion: 4)
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        db.nodeCountOverride = [0x08, 0x02] + [UInt8](repeating: 0xFF, count: 8) // uint64（扩展类型 9）的最大值
        #expect(throws: CountryDatabaseError.malformed) { try CountryDatabase.networks(country: "CN", in: db.bytes()) }
    }

    /// mihomo 认的另两种库（sing-geoip、Meta-geoip0）记录不是 GeoLite2 的样子，这里不支持
    @Test func rejectsOtherMihomoDatabaseTypes() throws {
        let db = MMDB(ipVersion: 4)
        db.databaseType = "sing-geoip"
        db.insert("198.51.100.0/24", db.record(country: "CN"))
        #expect(throws: CountryDatabaseError.unsupportedType("sing-geoip")) {
            try CountryDatabase.networks(country: "CN", in: db.bytes())
        }
    }
}

/// 放行表的国内段像不像一个国家：真库（Clash Verge Rev 自带 mihomo v1.19.21 时目录里的 Country.mmdb）IPv4 覆盖 8.26%、最短 /10，IPv6 最短 /20
@Suite struct CountryPlausibility {
    @Test func acceptsARealisticCountry() {
        #expect(CountryDatabase.isPlausible(["1.0.1.0/24", "36.0.0.0/10", "240e::/20"].map { IPNetwork($0)! }))
    }

    /// 被改成大半个互联网都算 CN，正式规则就等于什么都不拦：一个大段，或者拼出来的很多段，都不行
    @Test func rejectsTooMuchOfTheInternet() {
        #expect(!CountryDatabase.isPlausible([IPNetwork("0.0.0.0/1")!]))
        #expect(!CountryDatabase.isPlausible((0..<33).map { IPNetwork("\($0).0.0.0/8")! }))
        #expect(CountryDatabase.isPlausible((0..<32).map { IPNetwork("\($0).0.0.0/8")! }))
        #expect(!CountryDatabase.isPlausible([IPNetwork("2000::/13")!]))
        // 错开的 /16 合并不起来，每段前缀都不短，合起来却很大：按总量算
        #expect(!CountryDatabase.isPlausible(stride(from: 0, to: 10, by: 2).map { IPNetwork("24\(String($0, radix: 16))0::/16")! }))
        #expect(CountryDatabase.isPlausible([IPNetwork("2400::/16")!]))
        // IPv6 上限 2^-14：中国已分配的 IPv6 约 2^-15.9（推断），收全了的库也要能过
        #expect(CountryDatabase.isPlausible(stride(from: 0, to: 6, by: 2).map { IPNetwork("24\(String($0, radix: 16))0::/16")! }))
    }
}

/// 测试用的最小 mmdb 写入器：24 位记录，数据区只写这里用到的 map、字符串、指针、uint
private final class MMDB {
    let ipVersion: Int
    var databaseType = "GeoLite2-Country"
    var truncateData = false
    /// 直接给搜索树的字节和节点数，不用 `insert` 建
    var rawTree: (count: Int, bytes: [UInt8])?
    /// 元数据里 node_count 的值，编码好的
    var nodeCountOverride: [UInt8]?
    private var data: [UInt8] = []
    /// 二叉树，节点 0 是根；`.data` 存数据区偏移
    private enum Child { case empty, node(Int), data(Int) }
    private var nodes: [[Child]] = [[.empty, .empty]]

    init(ipVersion: Int) { self.ipVersion = ipVersion }

    /// `{"country": {"iso_code": code}}`，返回数据区偏移
    func record(country code: String) -> Int {
        let offset = data.count
        data += map(1) + string("country")
        data += map(1) + string("iso_code") + string(code)
        return offset
    }

    /// `{"continent": {"code": "AS"}, "country": <指向 `other` 里 country 值的指针>}`
    func record(countryPointer other: Int) -> Int {
        let offset = data.count
        data += map(2) + string("continent") + map(1) + string("code") + string("AS")
        data += string("country")
        let target = other + map(1).count + string("country").count
        precondition(target < 2048)
        data += [UInt8(1 << 5 | (target >> 8)), UInt8(target & 0xFF)]
        return offset
    }

    func insert(_ network: String, _ offset: Int) { set(network, .data(offset)) }

    /// 原样追加到数据区，返回偏移
    func raw(_ bytes: [UInt8]) -> Int {
        defer { data += bytes }
        return data.count
    }

    func alias(_ network: String, to target: String) {
        guard case .node(let n) = walk(target) else { preconditionFailure("别名指向的得是节点") }
        set(network, .node(n))
    }

    func bytes() -> [UInt8] {
        let count = nodes.count
        let value = { (c: Child) -> Int in
            switch c {
            case .empty: count
            case .node(let n): n
            case .data(let o): count + 16 + o
            }
        }
        var out: [UInt8] = []
        for node in nodes {
            for child in node { let v = value(child); out += [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        }
        var nodeCount = count
        if let rawTree { (nodeCount, out) = rawTree }
        out += [UInt8](repeating: 0, count: 16)
        out += truncateData ? [] : data
        out += [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        out += map(4) + string("node_count") + (nodeCountOverride ?? uint32(nodeCount)) + string("record_size") + uint16(24)
            + string("ip_version") + uint16(ipVersion) + string("database_type") + string(databaseType)
        return out
    }

    private func bits(_ network: String) -> [Int] {
        let n = IPNetwork(network)!
        precondition(n.bytes.count == (ipVersion == 4 ? 4 : 16))
        return (0..<n.prefix).map { Int(n.bytes[$0 / 8] >> (7 - UInt8($0 % 8)) & 1) }
    }

    private func set(_ network: String, _ child: Child) {
        let path = bits(network)
        var node = 0
        for bit in path.dropLast() { node = descend(node, bit) }
        nodes[node][path.last!] = child
    }

    private func walk(_ network: String) -> Child {
        let path = bits(network)
        var node = 0
        for bit in path.dropLast() { node = descend(node, bit) }
        return nodes[node][path.last!]
    }

    private func descend(_ node: Int, _ bit: Int) -> Int {
        if case .node(let n) = nodes[node][bit] { return n }
        nodes.append([.empty, .empty])
        nodes[node][bit] = .node(nodes.count - 1)
        return nodes.count - 1
    }

    private func map(_ n: Int) -> [UInt8] { [UInt8(7 << 5 | n)] }
    private func string(_ s: String) -> [UInt8] { precondition(s.utf8.count < 29); return [UInt8(2 << 5 | s.utf8.count)] + Array(s.utf8) }
    private func uint16(_ v: Int) -> [UInt8] { [UInt8(5 << 5 | 2), UInt8(v >> 8), UInt8(v & 0xFF)] }
    private func uint32(_ v: Int) -> [UInt8] { [UInt8(6 << 5 | 4), UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
