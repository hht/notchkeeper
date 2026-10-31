import Foundation
import NotchCore

/// 回答：一条解析好的消息放不放上刘海、放成哪张卡、同哪组替换。
/// 没登记的、过期的、重发的、超了限流的丢掉（CLAUDE.md 硬规则「插件」）；设置里关没关由 App 在主线程判。纯状态机：插件表和当前时间由 App 喂，不读目录
public struct InboxGate: Sendable {
    public enum Rejection: Error, Equatable, Sendable {
        case unregistered, stale, duplicate, rateLimited
    }

    public struct Admitted: Sendable {
        public var card: Card
        public var key: CardQueue<Card>.Key?
        /// 排到这时还没放就不放（`CardQueue.Notice.staleAt`）
        public var staleAt: Date
    }

    /// 每个插件每 `window` 秒至多放 `limit` 张：一张卡停 6 秒左右，再多就把刘海占满了
    public static let limit = 6
    public static let window: TimeInterval = 60
    /// 消息发出这么久就不放：App 没开时攒下的、红卡挂着时排着的，回来再弹已经没用了。`staleAt` 只能提前，不能推后
    public static let lifetime: TimeInterval = 10 * 60

    /// 插件 id → 窗口内放过的时刻
    private var admitted: [String: [Date]] = [:]
    /// 放过的消息 id → 它过期的时刻：只记到那时，之后同 id 再来算新的一条
    private var seen: [UUID: Date] = [:]
    public init() {}

    /// 一张普通卡（`m.activity` 是 nil）
    public mutating func admit(_ m: Message, plugins: [String: Manifest], now: Date) throws(Rejection) -> Admitted {
        precondition(m.activity == nil, "活动走 admitActivity")
        let manifest = try registered(m, plugins)
        // 发出时刻在未来（钟不准或写错）按收到时刻算：不会永不过期，`seen` 也不会一直涨
        let staleAt = min(m.staleAt ?? .distantFuture, min(m.at, now).addingTimeInterval(Self.lifetime))
        guard now < staleAt else { throw .stale }
        seen = seen.filter { now < $0.value }
        guard seen[m.id] == nil else { throw .duplicate }
        guard takeSlot(m.plugin, now: now) else { throw .rateLimited }
        seen[m.id] = staleAt
        return Admitted(card: Self.card(m, manifest), key: m.group.map { .group(plugin: m.plugin, name: $0) }, staleAt: staleAt)
    }

    /// 活动的一步。不进限流、不去重（`ActivityBoard` 按时间戳取新，进度可能每秒一条）；只有 alert 占弹卡名额，超了只是不弹
    public mutating func admitActivity(_ m: Message, plugins: [String: Manifest], now: Date) throws(Rejection) -> ActivityUpdate {
        guard let activity = m.activity else { preconditionFailure("普通卡走 admit") }
        let manifest = try registered(m, plugins)
        guard now < min(m.at, now).addingTimeInterval(ActivityBoard.maxAge), now < m.staleAt ?? .distantFuture else { throw .stale }
        // 发出时刻在未来按收到时刻算：不然那一行永远不过期，之后真实时刻的 update、end 都算旧的
        return ActivityUpdate(plugin: m.plugin, id: activity.id, event: activity.event, at: min(m.at, now), staleAt: m.staleAt,
                              alert: activity.alert && takeSlot(m.plugin, now: now), card: Self.card(m, manifest))
    }

    private func registered(_ m: Message, _ plugins: [String: Manifest]) throws(Rejection) -> Manifest {
        guard let manifest = plugins[m.plugin] else { throw .unregistered }
        return manifest
    }

    /// 这个插件这一分钟还能不能弹一张；能就记上
    private mutating func takeSlot(_ plugin: String, now: Date) -> Bool {
        let recent = (admitted[plugin] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard recent.count < Self.limit else { return false }
        admitted[plugin] = recent + [now]
        return true
    }

    private static func card(_ m: Message, _ manifest: Manifest) -> Card {
        Card(source: .plugin(id: manifest.id, name: manifest.name, symbol: manifest.symbol), title: m.title, subtitle: m.subtitle,
             value: m.value, outcome: m.outcome, block: m.block, action: m.action.map(Self.action),
             buttons: m.buttons.map { Card.Button(title: $0.title, action: Self.action($0.action)) })
    }

    private static func action(_ a: Message.Action) -> Card.Action {
        switch a {
        case .open(let url): return .open(url)
        case .activate(let id): return .activate(bundleID: id)
        case .focusTerminal(let tty, let pid, let cwd): return .terminal(TerminalRef(pid: pid, identity: .tty(tty), cwd: cwd))
        }
    }
}
