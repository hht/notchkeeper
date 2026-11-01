import Foundation
import GuardCore

/// 回答：用户在 App 里设置的出口 IP 允许列表现在是什么。
/// 读 App 写的 `config.json`（格式归 Sources/Notchkeeper/Config.swift 的 `NKConfig`），只解 `allowlist` 一个键，
/// 其余键忽略。每轮重读，App 设置页改了下一轮就生效，不用重启 guardd。
/// 读不到（文件不存在、解不开、缺 `allowlist` 键）就退回默认值，默认值是空集合：源码里不写任何真实出口 IP。
/// 允许列表为空时 GuardCore 对出口 IP 的判断是 nil，verdict 最多到 unknown，绝不因此 violated；
/// 路由不走 utun 照样 violated，这一条不依赖允许列表。真实地址只存在用户的 config.json 里。
enum AllowlistFile {
    static let defaults: Set<IPv4> = []

    static let url = GuardPaths.configFile

    enum Problem: Equatable {
        case missing, unreadable, invalidEntries(Int)

        /// 日志里的一行；不带 IP。
        var message: String {
            switch self {
            case .missing: "没有 config.json，允许列表为空，出口 IP 一律算未知"
            case .unreadable: "config.json 读不出 allowlist，允许列表为空，出口 IP 一律算未知"
            case let .invalidEntries(n): "config.json 的 allowlist 里有 \(n) 条不是合法 IPv4，已忽略"
            }
        }
    }

    struct Loaded: Equatable {
        var allowlist: Set<IPv4>
        var problem: Problem?
    }

    static func read(_ url: URL = url) -> Loaded {
        do {
            return parse(try Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return parse(nil)
        } catch {
            return Loaded(allowlist: defaults, problem: .unreadable)
        }
    }

    /// `nil` 表示文件不存在。缺 `allowlist` 键时用默认值（空集合），不算问题。
    static func parse(_ data: Data?) -> Loaded {
        guard let data else { return Loaded(allowlist: defaults, problem: .missing) }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            return Loaded(allowlist: defaults, problem: .unreadable)
        }
        guard let entries = file.allowlist else { return Loaded(allowlist: defaults, problem: nil) }
        let ips = entries.compactMap(IPv4.init)
        return Loaded(allowlist: Set(ips), problem: ips.count == entries.count ? nil : .invalidEntries(entries.count - ips.count))
    }

    private struct File: Decodable {
        var allowlist: [String]?
    }
}
