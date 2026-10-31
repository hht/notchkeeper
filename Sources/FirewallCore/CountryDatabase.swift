/// 回答：mihomo 的 GEOIP 库（`Country.mmdb`）里，哪些网段算某个国家。照 mihomo 判 `GEOIP,CN` 的办法：GeoLite2 类型的库，
/// 记录里 `country.iso_code` 转小写后等于规则里的国家。相邻的同国网段合并成一段。
/// 只认 GeoLite2 的记录样子；不知道文件在哪。外部文件，越界、格式不对都报错，不崩溃。
/// @see https://maxmind.github.io/MaxMind-DB/
/// @see https://github.com/MetaCubeX/mihomo/blob/Meta/component/mmdb/reader.go
public enum CountryDatabase {
    /// 两张放行表合计最多几项。pf 的表项是全系统共用的（XNU 默认上限 20 万，推断），真库国内段 8928 段，留一个数量级的余量
    public static let maxTableEntries = 100_000

    /// 合并之后超过 `limit` 段就报错：走到一半就停，内存和耗时也一起封顶
    public static func networks(country: String, in bytes: [UInt8], limit: Int = maxTableEntries) throws(CountryDatabaseError) -> [IPNetwork] {
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        guard let markerStart = lastIndex(of: marker, in: bytes) else { throw .malformed }
        let metadata = Decoder(bytes: bytes, base: markerStart + marker.count, end: bytes.count)
        let field = { (key: String) throws(CountryDatabaseError) -> Int? in try metadata.field(key, inMapAt: 0) }
        // 外部数据：先和文件大小比，再参与乘法，免得溢出
        guard let nodeCount = try metadata.uint(at: field("node_count")), let recordSize = try metadata.uint(at: field("record_size")),
              let ipVersion = try metadata.uint(at: field("ip_version")), [24, 28, 32].contains(recordSize), [4, 6].contains(ipVersion),
              nodeCount <= UInt64(bytes.count)
        else { throw .malformed }
        if let type = try metadata.string(at: field("database_type")), ["sing-geoip", "Meta-geoip0"].contains(type) {
            throw .unsupportedType(type)
        }
        let treeSize = Int(recordSize) * 2 / 8 * Int(nodeCount)
        guard treeSize + 16 <= markerStart else { throw .malformed }
        let walker = Walker(bytes: bytes, nodeCount: Int(nodeCount), recordSize: Int(recordSize),
                            data: Decoder(bytes: bytes, base: treeSize + 16, end: markerStart), country: country.lowercased(),
                            limit: limit)
        return try walker.networks(ipVersion: Int(ipVersion))
    }

    /// 放行表的国内段像不像一个国家：合起来不超过 IPv4 地址空间的 1/8、IPv6 地址空间的 2^-14。按总量算：错开的小段合并不起来，
    /// 只看前缀挡不住。真库（10-31）IPv4 覆盖 8.26%，IPv6 约 2^-17.4；中国已分配的 IPv6 约 2^-15.9（推断），收全了的库也要能过。库被改成大半个互联网都算 CN 时，正式规则等于什么都不拦、核对却全过
    public static func isPlausible(_ networks: [IPNetwork]) -> Bool {
        // 用 Double 求和不会溢出（构造过的库段数可以很多）；2 的整数次幂在 Double 里是精确的
        let share = { (family: Int) in
            networks.filter { $0.bytes.count == family }.reduce(0.0) { $0 + Double(sign: .plus, exponent: -$1.prefix, significand: 1) }
        }
        return share(4) <= 0x1p-3 && share(16) <= 0x1p-14
    }

    private static func lastIndex(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        return stride(from: bytes.count - needle.count, through: 0, by: -1).first { i in
            needle.indices.allSatisfy { bytes[i + $0] == needle[$0] }
        }
    }
}

public enum CountryDatabaseError: Error, Equatable {
    /// 不是 mmdb，或者截断、越界
    case malformed
    /// mihomo 认得、这里不支持的库
    case unsupportedType(String)
    /// 国内段超过上限：pf 装不下
    case tooManyNetworks
}

/// 走一遍搜索树
private final class Walker {
    let bytes: [UInt8]
    let nodeCount: Int
    let recordSize: Int
    let data: Decoder
    let country: String
    let limit: Int
    /// 数据区偏移 → 是不是这个国家；GeoLite2 里大量网段共用同一份记录
    var verdicts: [Int: Bool] = [:]
    /// IPv6 库里 IPv4 子树的根（`::/96`），别处再指到它是别名（`::ffff:0:0/96`、`2002::/16`），不重复走
    var ipv4Root: Int?
    /// 走过的节点。合法的树里除了上面的别名，每个节点只有一个父节点；再走到就是构造过的库（不拦的话按 2^深度 走不完）
    var visited: [Bool]

    init(bytes: [UInt8], nodeCount: Int, recordSize: Int, data: Decoder, country: String, limit: Int) {
        (self.bytes, self.nodeCount, self.recordSize, self.data, self.country, self.limit) = (bytes, nodeCount, recordSize, data, country, limit)
        visited = [Bool](repeating: false, count: nodeCount)
    }

    func networks(ipVersion: Int) throws(CountryDatabaseError) -> [IPNetwork] {
        guard ipVersion == 6 else { return try walk(0, path: [UInt8](repeating: 0, count: 4), depth: 0).networks }
        var node = 0
        for _ in 0..<96 {
            guard node < nodeCount else { break }
            node = try record(node, 0)
        }
        if node < nodeCount { ipv4Root = node }
        return try walk(0, path: [UInt8](repeating: 0, count: 16), depth: 0).networks
    }

    /// 子树里属于这个国家的网段；`whole` 是整个子树都是（父节点据此把两半合成一段）
    private func walk(_ node: Int, path: [UInt8], depth: Int) throws(CountryDatabaseError) -> (networks: [IPNetwork], whole: Bool) {
        if node == ipv4Root, path.count == 16 {
            // 只在 ::/96 那一处按 IPv4 走；别名处跳过
            guard depth == 96, path.allSatisfy({ $0 == 0 }) else { return ([], false) }
            // 不往上报 whole：IPv4 段不能和旁边的 IPv6 段合成一段
            return (try walk(node, path: [0, 0, 0, 0], depth: 0).networks, false)
        }
        guard depth < path.count * 8, !visited[node] else { throw .malformed }
        visited[node] = true
        var halves: [(networks: [IPNetwork], whole: Bool)] = []
        for bit in 0...1 {
            var p = path
            if bit == 1 { p[depth / 8] |= 0x80 >> UInt8(depth % 8) }
            let child = try record(node, bit)
            if child < nodeCount {
                halves.append(try walk(child, path: p, depth: depth + 1))
            } else if child == nodeCount {
                halves.append(([], false))
            } else {
                let matches = try verdict(child - nodeCount - 16)
                halves.append((matches ? [IPNetwork(bytes: p, prefix: depth + 1)!] : [], matches))
            }
        }
        if halves[0].whole, halves[1].whole { return ([IPNetwork(bytes: path, prefix: depth)!], true) }
        // 每个子树合并后都不超过上限，拼起来最多两倍：数组不会大到拖住内存
        guard halves[0].networks.count + halves[1].networks.count <= limit else { throw .tooManyNetworks }
        return (halves[0].networks + halves[1].networks, false)
    }

    private func verdict(_ offset: Int) throws(CountryDatabaseError) -> Bool {
        if let v = verdicts[offset] { return v }
        guard try data.isMap(at: offset) else { throw .malformed }
        let countryMap = try data.field("country", inMapAt: offset)
        let code = try countryMap.flatMap { m throws(CountryDatabaseError) in try data.string(at: data.field("iso_code", inMapAt: m)) }
        let v = code?.lowercased() == country
        verdicts[offset] = v
        return v
    }

    /// 节点 `node` 的左（0）或右（1）记录
    private func record(_ node: Int, _ side: Int) throws(CountryDatabaseError) -> Int {
        let width = recordSize * 2 / 8
        let start = node * width
        guard start + width <= bytes.count else { throw .malformed }
        let b = { (i: Int) in Int(self.bytes[start + i]) }
        switch (recordSize, side) {
        case (24, 0): return b(0) << 16 | b(1) << 8 | b(2)
        case (24, _): return b(3) << 16 | b(4) << 8 | b(5)
        case (28, 0): return (b(3) & 0xF0) << 20 | b(0) << 16 | b(1) << 8 | b(2)
        case (28, _): return (b(3) & 0x0F) << 24 | b(4) << 16 | b(5) << 8 | b(6)
        case (_, 0): return b(0) << 24 | b(1) << 16 | b(2) << 8 | b(3)
        default: return b(4) << 24 | b(5) << 16 | b(6) << 8 | b(7)
        }
    }
}

/// 解数据区，`base` 是数据区起点，指针相对它。只按键查、只解字符串和无符号整数，别的值跳过：跳过时不跟指针，
/// 指针不许指向指针（规范如此）。很多记录指向同一个大 map、很多键指向同一个大字符串时，工作量还是会相乘，
/// 所以读值头的次数加上解出的字符串字节数有总上限 `budget`
private final class Decoder {
    let bytes: [UInt8]
    let base: Int
    /// 这一区的终点：数据区止于元数据标记，元数据止于文件尾
    let end: Int
    /// 还能读多少个值头、解多少字节字符串。给文件的字节数（加一点余量，查元数据要把几个短键名扫好几遍）：
    /// 合法的库每个值至少一个字节，记录又按偏移缓存，用不到这么多
    private var budget: Int

    init(bytes: [UInt8], base: Int, end: Int) {
        (self.bytes, self.base, self.end, budget) = (bytes, base, end, bytes.count + 4096)
    }

    /// 偏移处一个值的头：类型、大小、内容从哪开始。指针的「大小」是它指向的偏移
    private func header(at offset: Int) throws(CountryDatabaseError) -> (type: Int, size: Int, body: Int) {
        budget -= 1
        guard budget >= 0 else { throw .malformed }
        var i = offset
        let byte = { () throws(CountryDatabaseError) -> Int in
            guard i >= 0, self.base + i < self.end else { throw .malformed }
            defer { i += 1 }
            return Int(self.bytes[self.base + i])
        }
        let control = try byte()
        var type = control >> 5
        if type == 1 {
            let ss = control >> 3 & 0x3, vvv = control & 0x7
            let target = switch ss {
            case 0: vvv << 8 | (try byte())
            case 1: (vvv << 16 | (try byte()) << 8 | (try byte())) + 2048
            case 2: (vvv << 24 | (try byte()) << 16 | (try byte()) << 8 | (try byte())) + 526_336
            default: (try byte()) << 24 | (try byte()) << 16 | (try byte()) << 8 | (try byte())
            }
            return (1, target, i)
        }
        if type == 0 { type = 7 + (try byte()) }
        var size = control & 0x1F
        switch size {
        case 29: size = 29 + (try byte())
        case 30: size = 285 + ((try byte()) << 8 | (try byte()))
        case 31: size = 65_821 + ((try byte()) << 16 | (try byte()) << 8 | (try byte()))
        default: break
        }
        return (type, size, i)
    }

    /// 顺着指针走到真正的值（只走一跳）
    private func resolve(_ offset: Int) throws(CountryDatabaseError) -> (type: Int, size: Int, body: Int) {
        let h = try header(at: offset)
        guard h.type == 1 else { return h }
        let target = try header(at: h.size)
        guard target.type != 1 else { throw .malformed }
        return target
    }

    /// 跳过偏移处的值，返回它后面的偏移。指针只跳过自己，不跟过去
    private func skip(_ offset: Int, depth: Int = 0) throws(CountryDatabaseError) -> Int {
        guard depth < 32 else { throw .malformed }
        let h = try header(at: offset)
        var i = h.body
        switch h.type {
        case 1: return i
        case 7: for _ in 0..<(2 * h.size) { i = try skip(i, depth: depth + 1) }
        case 11: for _ in 0..<h.size { i = try skip(i, depth: depth + 1) }
        case 3: i += 8
        case 15: i += 4
        case 14: break
        case 2, 4, 5, 6, 8, 9, 10: i += h.size
        default: throw .malformed
        }
        guard base + i <= end else { throw .malformed }
        return i
    }

    func isMap(at offset: Int) throws(CountryDatabaseError) -> Bool { try resolve(offset).type == 7 }

    /// 偏移处的 map 里键 `key` 的值从哪开始；不是 map 或没有这个键是 `nil`
    func field(_ key: String, inMapAt offset: Int) throws(CountryDatabaseError) -> Int? {
        let map = try resolve(offset)
        guard map.type == 7 else { return nil }
        var i = map.body
        let wanted = Array(key.utf8)
        for _ in 0..<map.size {
            let k = try resolve(i)
            let value = try skip(i)
            // 先比长度再逐字节比，不解成 String：很多键可以指向同一个大字符串，长度对不上就一步跳过
            if k.type == 2, k.size == wanted.count, k.body >= 0, base + k.body + k.size <= end,
               bytes[(base + k.body)..<(base + k.body + k.size)].elementsEqual(wanted) { return value }
            i = try skip(value)
        }
        return nil
    }

    func string(at offset: Int?) throws(CountryDatabaseError) -> String? {
        guard let offset else { return nil }
        let h = try resolve(offset)
        guard h.type == 2 else { return nil }
        guard h.body >= 0, base + h.body + h.size <= end else { throw .malformed }
        // 按字节扣额度：很多记录的值可以指向同一个大字符串，只按值头次数算挡不住，处理的总字节数就不超过文件大小
        budget -= h.size
        guard budget >= 0 else { throw .malformed }
        return String(decoding: bytes[(base + h.body)..<(base + h.body + h.size)], as: UTF8.self)
    }

    func uint(at offset: Int?) throws(CountryDatabaseError) -> UInt64? {
        guard let offset else { return nil }
        let h = try resolve(offset)
        guard [5, 6, 9, 10].contains(h.type), h.size <= 8 else { return nil }
        guard h.body >= 0, base + h.body + h.size <= end else { throw .malformed }
        return bytes[(base + h.body)..<(base + h.body + h.size)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
