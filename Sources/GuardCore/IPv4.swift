/// 回答：一个字符串是不是合法的点分十进制 IPv4 地址。
/// 外部数据（探针响应、允许列表）在边界解析成它，之后内部只比较值。
public struct IPv4: Hashable, Sendable, CustomStringConvertible {
    public let octets: [UInt8]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            // 只收 ASCII 数字，最多 3 位；"٣" 这类 Unicode 数字、"+1" 和前导零（"010"）都不算，
            // 免得允许列表里的条目被悄悄规范化成另一个地址
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part.count == 1 || part.first != "0",
                  let n = UInt8(part) else { return nil }
            octets.append(n)
        }
        self.octets = octets
    }

    public var description: String { octets.map(String.init).joined(separator: ".") }
}
