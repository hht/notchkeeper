import Darwin

/// 回答：一个 IPv4 或 IPv6 网段（单个地址是满前缀的网段），放进放行表的就是它。
/// 不知道它从哪来（Clash 配置、DNS 答案、mmdb）。
public struct IPNetwork: Hashable, Sendable, CustomStringConvertible {
    /// 4 或 16 字节，网络字节序；不清主机位，照写的样子留着
    public let bytes: [UInt8]
    public let prefix: Int

    public init?(bytes: [UInt8], prefix: Int) {
        guard bytes.count == 4 || bytes.count == 16, (0...bytes.count * 8).contains(prefix) else { return nil }
        (self.bytes, self.prefix) = (bytes, prefix)
    }

    /// `198.51.100.7`、`198.51.100.0/24`、`2001:db8::/32`；别的返回 `nil`
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let address = String(parts[0])
        var v4 = in_addr(), v6 = in6_addr()
        let bytes: [UInt8]
        if inet_pton(AF_INET, address, &v4) == 1 {
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, address, &v6) == 1 {
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
        var prefix = bytes.count * 8
        if parts.count == 2 {
            guard let p = Int(parts[1]), parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber) else { return nil }
            prefix = p
        }
        self.init(bytes: bytes, prefix: prefix)
    }

    /// `other` 整个落在本网段里（同一族）
    public func contains(_ other: IPNetwork) -> Bool {
        guard other.bytes.count == bytes.count, other.prefix >= prefix else { return false }
        for bit in 0..<prefix where (bytes[bit / 8] ^ other.bytes[bit / 8]) & (0x80 >> UInt8(bit % 8)) != 0 {
            return false
        }
        return true
    }

    /// `地址/前缀`，pfctl 的表文件认这个写法
    public var description: String { "\(address)/\(prefix)" }

    /// 不带前缀的地址
    public var address: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = bytes.count == 4 ? AF_INET : AF_INET6
        let printed = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        guard printed != nil else { preconditionFailure("4 或 16 字节总能打印") }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
