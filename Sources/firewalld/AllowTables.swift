import Darwin
import Foundation
import FirewallCore

/// 回答：开启时怎么拍放行表的快照——读 Clash Verge 目录里的两个文件、问 DNS、把两张表写进 root 目录（docs/firewall.md §4）。
/// 判定（读哪些字段、哪些网段算国内、答案算不算数）在 FirewallCore；不知道什么时候拍（只有开启命令调它）。
struct AllowTables {
    var clash: [IPNetwork]
    var cn: [IPNetwork]

    /// 读文件的上限：真实的配置约 200 KB、mmdb 约 9 MB，再大就不是它们（也免得构造过的大文件拖住开启命令）
    private static let maxConfigSize = 8 << 20, maxDatabaseSize = 64 << 20

    static func take(from clash: URL, _ sys: FirewallSystem) throws(SnapshotFailure) -> AllowTables {
        let yaml = try read("clash-verge.yaml", in: clash, limit: maxConfigSize)
        let database = try read("Country.mmdb", in: clash, limit: maxDatabaseSize)
        let config: ClashRuntimeConfig
        do { config = try ClashRuntimeConfig(yaml: String(decoding: yaml, as: UTF8.self)) } catch { throw .config(error) }
        let cn: [IPNetwork]
        do { cn = try CountryDatabase.networks(country: "CN", in: database) } catch { throw .database(error) }
        guard !cn.isEmpty else { throw .noCountryNetworks }
        guard CountryDatabase.isPlausible(cn) else { throw .implausibleCountryNetwork }
        do {
            let limit = CountryDatabase.maxTableEntries - cn.count
            return AllowTables(clash: try config.clashTable(limit: limit) { name, server in resolve(name, server, sys) }, cn: cn)
        } catch {
            throw .table(error)
        }
    }

    /// 两张表各写一个文件，root 0644，每行一段（pfctl 的表文件格式）
    func write(to directory: URL) throws {
        for (name, networks) in [(FirewallRules.clashTableFile, clash), (FirewallRules.cnTableFile, cn)] {
            try AtomicFile.write(Data(networks.map { "\($0)\n" }.joined().utf8), to: directory.appendingPathComponent(name), mode: 0o644)
        }
    }

    /// root 读用户可写的目录：不跟符号链接（可能指向只有 root 能读的文件、/dev/zero），只读普通文件（FIFO 读了就一直等），
    /// 大小在打开的同一个 fd 上量、按上限读，量完被换掉也读不到别的
    private static func read(_ name: String, in directory: URL, limit: Int) throws(SnapshotFailure) -> [UInt8] {
        let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw .unreadable(name) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw .unreadable(name) }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + count, $0.count - count) }
            guard n >= 0 else { throw .unreadable(name) } // 读到一半出错：截断的配置会少节点，不当成完整的
            if n == 0 { break }
            count += n
        }
        return Array(bytes.prefix(count))
    }

    /// 用系统的 dig 问一个明文 UDP 上游，A 和 AAAA 都问；两次都失败是 `nil`。
    /// `name` 已由 `clashTable` 验过是域名（不会被 dig 当成选项）
    private static func resolve(_ name: String, _ server: DNSServer, _ sys: FirewallSystem) -> [IPNetwork]? {
        let answers = ["A", "AAAA"].compactMap { type -> [IPNetwork]? in
            let out = sys.run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "-p", String(server.port), "@\(server.address.address)",
                                               "-t", type, "-q", name], nil)
            // +short 只列答案：地址，或者 CNAME 的目标（以点结尾，不是地址，跳过）
            return out.succeeded ? out.stdout.split(separator: "\n").compactMap { IPNetwork(String($0)) } : nil
        }
        return answers.isEmpty ? nil : answers.flatMap { $0 }
    }
}

/// 拍不了快照：开启被拒，状态不动
enum SnapshotFailure: Error, Equatable {
    /// Clash Verge 目录里的这个文件读不出来（或大得不像）
    case unreadable(String)
    case config(ClashConfigError)
    case database(CountryDatabaseError)
    /// 库读得出、却一段 CN 都没有（库换了样子）：放行了也等于 DIRECT 全不通
    case noCountryNetworks
    /// 国内段大得不像一个国家（库被改过）：放行了等于什么都不拦
    case implausibleCountryNetwork
    case table(AllowTableError)
}
