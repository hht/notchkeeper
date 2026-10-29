import Foundation
import GuardCore

/// 回答：从外面看，本机现在的出口 IPv4 是什么。
/// 同时问几个通用的 IP 回显服务，每个答案在边界解析成 `IPv4`；失败、非 200、解析不了的答案不猜也不补，
/// 只按类型计数，留给排查 unknown 用（计数里不带 IP）。
/// 只用第三方回显服务，不访问任何 Claude / Anthropic 域名（CLAUDE.md 硬规则）。
///
/// 局限：回显服务和别的 App 可能被 Clash 分到不同节点，这时报的不是那些 App 的出口 IP。
/// 所以出口 IP 不符只判 egressMismatch（琥珀色），见 docs/egress-guard.md。
public struct EgressProbe: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    public enum Failure: Error, Hashable, Sendable { case timeout, transport, badStatus, unparseable }

    public struct Sample: Sendable {
        /// 成功拿到的 IP；一个都没有就是空数组（判定里算未知）。
        public var ips: [IPv4] = []
        public var failures: [Failure: Int] = [:]

        public init(ips: [IPv4] = [], failures: [Failure: Int] = [:]) {
            self.ips = ips
            self.failures = failures
        }
    }

    public let endpoints: [URL]
    let fetch: Fetch

    public init(endpoints: [URL], fetch: @escaping Fetch) {
        self.endpoints = endpoints
        self.fetch = fetch
    }

    public static let live = EgressProbe(
        endpoints: ["https://api.ipify.org", "https://ipinfo.io/ip", "https://ifconfig.me/ip"].compactMap(URL.init(string:)),
        fetch: { url in
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 6)
            req.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent") // 这些服务按 UA 决定回纯文本还是网页
            let (data, resp) = try await session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    )

    private static let session = URLSession(configuration: .ephemeral)

    public func current() async -> Sample {
        await withTaskGroup(of: Result<IPv4, Failure>.self) { group in
            for url in endpoints {
                group.addTask { await ask(url) }
            }
            return await group.reduce(into: Sample()) { sample, result in
                switch result {
                case let .success(ip): sample.ips.append(ip)
                case let .failure(f): sample.failures[f, default: 0] += 1
                }
            }
        }
    }

    private func ask(_ url: URL) async -> Result<IPv4, Failure> {
        let data: Data, status: Int
        do { (data, status) = try await fetch(url) } catch let e as URLError where e.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.transport)
        }
        guard status == 200 else { return .failure(.badStatus) }
        guard let ip = IPv4(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(.unparseable)
        }
        return .success(ip)
    }
}
