import Foundation
import NotchCore

/// 活动的一步，`InboxGate` 收下的
public struct ActivityUpdate: Sendable {
    public var plugin: String
    public var id: String
    public var event: Message.Activity.Event
    public var at: Date
    public var staleAt: Date?
    /// 要弹卡（已过限流）
    public var alert: Bool
    /// 这一刻的内容：面板那一行和弹的卡都从它来
    public var card: Card
}

/// 回答：外部插件此刻开着哪些活动、面板里各画成哪一行、插件多急、哪张卡要弹或原地刷新。
/// 照 ActivityKit：start / update / end，时间戳取新（乱序到的旧消息不覆盖新的），最长 8 小时，`staleAt` 到了撤掉。
/// 纯状态机：喂收下的 `ActivityUpdate` 和当前时间；不读目录、不起定时器（App 按 `deadline` 到点调 `expire`）
/// @see https://developer.apple.com/documentation/activitykit/activity
public struct ActivityBoard: Sendable {
    /// ActivityKit：一个活动最多开 8 小时，从开始算
    /// @see https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
    public static let maxAge: TimeInterval = 8 * 3600
    /// 每个插件至多开着这么多：面板一段最多露 5 行，再多是写错了的脚本
    public static let maxPerPlugin = 5

    /// 要弹或要刷新的卡：App 先试原地刷新（`CardQueue.update`），找不到且 `alert` 才弹
    public struct CardChange: Equatable, Sendable {
        public var card: Card
        public var key: CardQueue<Card>.Key
        public var alert: Bool
        /// 消息自己写的过期时刻：卡排到那时还没放就不放
        public var staleAt: Date?
    }

    /// 一个活动最近的一步：比它新才收。时间戳一样时按步骤先后（start < update < end）：脚本不到一秒就 end 的，end 也要撤掉那一行
    private struct Step: Comparable, Sendable {
        var at: Date
        var order: Int

        /// 活动结束的那一刻：结束了的只有比它新的 start 能重开
        static func end(at: Date) -> Step { Step(at: at, order: 2) }

        private init(at: Date, order: Int) {
            self.at = at
            self.order = order
        }

        init(_ u: ActivityUpdate) {
            at = u.at
            order = switch u.event {
            case .start: 0
            case .update: 1
            case .end: 2
            }
        }

        static func < (a: Step, b: Step) -> Bool { (a.at, a.order) < (b.at, b.order) }
    }

    private struct Live: Sendable {
        var started: Date
        var last: Step
        var expires: Date
        var cardID: UUID
        var card: Card
    }

    private var live: [CardQueue<Card>.Key: Live] = [:]
    /// 结束了的活动（end、过期、被挤掉）→ 结束那一步：之后只有比它新的 start 能重开，update 和 end 不收（照 ActivityKit）。
    /// 只记 `maxAge`，再旧的 `InboxGate` 已经不收
    private var ended: [CardQueue<Card>.Key: Step] = [:]

    public init() {}

    /// 返回要弹或要刷新的卡；旧消息（不比这个活动最近一步新）不变，返回 nil
    public mutating func apply(_ u: ActivityUpdate, now: Date) -> CardChange? {
        let key = CardQueue<Card>.Key.activity(plugin: u.plugin, id: u.id)
        ended = ended.filter { now.timeIntervalSince($0.value.at) < Self.maxAge }
        let step = Step(u)
        if let last = live[key]?.last {
            guard step > last else { return nil }
        } else if let end = ended[key] {
            guard u.event == .start, step > end else { return nil }
        }
        let old = live[key]
        let cardID = old?.cardID ?? UUID()
        let card = Self.card(u.card, id: cardID)
        switch u.event {
        case .end:
            live[key] = nil
            ended[key] = step
        case .start, .update:
            // 没见过 start（App 晚开、start 过期了）的 update 当开始；start 重新计时。结束了的已在上面拦下
            let started = u.event == .start || old == nil ? u.at : old!.started
            live[key] = Live(started: started, last: step,
                             expires: min(u.staleAt ?? .distantFuture, started.addingTimeInterval(Self.maxAge)), cardID: cardID, card: card)
            dropOldest(u.plugin)
            // 比开着的都旧、一进来就被挤掉的：面板里没有它，也不弹卡
            guard live[key] != nil else { return nil }
        }
        return CardChange(card: card, key: key, alert: u.alert, staleAt: u.staleAt)
    }

    /// 到点了：撤掉过期的行
    public mutating func expire(now: Date) {
        for (key, l) in live where now >= l.expires {
            live[key] = nil
            ended[key] = .end(at: now)
        }
    }

    /// 最早的那个活动过期的时刻；没有活动是 nil
    public var deadline: Date? { live.values.map(\.expires).min() }

    /// 设置里关掉了这个插件
    public mutating func remove(plugin: String) {
        live = live.filter { $0.key.plugin != plugin }
    }

    /// 按开始先后排，同一刻开始的按 id 排；更新了也不挪位置（同会话行）
    public func rows(for plugin: String) -> [PanelRow] {
        live.compactMap { key, l -> (id: String, live: Live)? in
            guard case .activity(plugin, let id) = key else { return nil }
            return (id, l)
        }
        .sorted { ($0.live.started, $0.id) < ($1.live.started, $1.id) }
        .map { id, l in
            let c = l.card
            let symbol = if case .plugin(_, _, let s) = c.source { s } else { preconditionFailure("活动只来自外部插件") }
            let indicator: PanelRow.Indicator = if c.outcome == .attention {
                .attention
            } else if case .progress(let p, _)? = c.block {
                .progress(p)
            } else {
                .working
            }
            return PanelRow(id: "\(plugin):\(id)", icon: .symbol(symbol), title: c.title, subtitle: c.subtitle, indicator: indicator,
                            trailing: c.value.map(PanelRow.Trailing.value) ?? .since(l.started), action: c.action)
        }
    }

    /// 开着的活动里最急的那个：要你看的是 attention，其余进行中；没有活动是平静
    public func urgency(for plugin: String) -> PluginStatus.Urgency {
        let mine = live.filter { $0.key.plugin == plugin }.values
        if mine.contains(where: { $0.card.outcome == .attention }) { return .attention }
        return mine.isEmpty ? .calm : .active
    }

    private mutating func dropOldest(_ plugin: String) {
        let mine = live.filter { $0.key.plugin == plugin }
        guard mine.count > Self.maxPerPlugin, let oldest = mine.min(by: { $0.value.last < $1.value.last }) else { return }
        live[oldest.key] = nil
        ended[oldest.key] = .end(at: oldest.value.last.at)
    }

    /// 同一个活动的卡每次新造，id 沿用第一张
    private static func card(_ c: Card, id: UUID) -> Card {
        Card(id: id, source: c.source, title: c.title, subtitle: c.subtitle, value: c.value, outcome: c.outcome, block: c.block,
             action: c.action, buttons: c.buttons)
    }
}
