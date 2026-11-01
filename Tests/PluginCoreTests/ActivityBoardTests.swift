import Foundation
import Testing
import NotchCore
@testable import PluginCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
private let source = Card.Source.plugin(id: "dl", name: "下载", symbol: "arrow.down.circle")

private func update(_ event: Message.Activity.Event = .update, id: String = "xcode", plugin: String = "dl", sent: TimeInterval = 0,
                    title: String = "下载中", value: String? = nil, outcome: Card.Outcome = .info, block: Card.Block? = nil,
                    alert: Bool = false, staleAt: Date? = nil) -> ActivityUpdate {
    ActivityUpdate(plugin: plugin, id: id, event: event, at: at(sent), staleAt: staleAt, alert: alert,
                   card: Card(source: .plugin(id: plugin, name: "下载", symbol: "arrow.down.circle"), title: title, value: value,
                              outcome: outcome, block: block))
}

/// 活动在面板里插件那一段占一行（照 ActivityKit）：start / update 原地刷新，end 撤掉；时间戳取新
@Suite struct ActivityRows {
    @Test func startAddsRow() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        #expect(board.rows(for: "dl") == [PanelRow(id: "dl:xcode", icon: .symbol("arrow.down.circle"), title: "下载中", indicator: .working,
                                                   trailing: .since(at(1)))])
    }

    @Test func updateRefreshesInPlaceAndKeepsStart() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        _ = board.apply(update(sent: 5, title: "快好了", value: "剩 1 分"), now: at(5))
        let rows = board.rows(for: "dl")
        #expect(rows.count == 1 && rows[0].title == "快好了" && rows[0].trailing == .value("剩 1 分"))
    }

    /// 乱序到的旧消息不覆盖新的
    @Test func olderIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(sent: 5, title: "新"), now: at(5))
        #expect(board.apply(update(sent: 4, title: "旧"), now: at(6)) == nil)
        #expect(board.apply(update(sent: 5, title: "同一刻"), now: at(6)) == nil)
        #expect(board.rows(for: "dl").map(\.title) == ["新"])
    }

    /// 没见过 start（App 晚开、start 过期了）也认：update 当开始
    @Test func updateWithoutStartCreates() {
        var board = ActivityBoard()
        _ = board.apply(update(sent: 3), now: at(3))
        #expect(board.rows(for: "dl").first?.trailing == .since(at(3)))
    }

    @Test func endRemovesAndLaterOldUpdateIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        #expect(board.apply(update(.end, sent: 9), now: at(9)) != nil)
        #expect(board.rows(for: "dl").isEmpty)
        #expect(board.apply(update(sent: 8), now: at(10)) == nil)
        #expect(board.rows(for: "dl").isEmpty)
        // 之后新开一次同名的算新的
        _ = board.apply(update(.start, sent: 20), now: at(20))
        #expect(board.rows(for: "dl").count == 1)
    }

    @Test func indicators() {
        var board = ActivityBoard()
        _ = board.apply(update(id: "a", block: .progress(0.4, label: nil)), now: t0)
        _ = board.apply(update(id: "b", sent: 1, outcome: .attention), now: at(1))
        #expect(board.rows(for: "dl").map(\.indicator) == [.progress(0.4), .attention])
    }

    /// 按开始先后排，更新了也不挪位置（同会话行）
    @Test func orderedByStart() {
        var board = ActivityBoard()
        _ = board.apply(update(id: "a", sent: 1), now: at(1))
        _ = board.apply(update(id: "b", sent: 2), now: at(2))
        _ = board.apply(update(id: "a", sent: 3, title: "a2"), now: at(3))
        #expect(board.rows(for: "dl").map(\.id) == ["dl:a", "dl:b"])
    }

    /// 每个插件至多 5 个：再开就丢最久没更新的
    @Test func capPerPlugin() {
        var board = ActivityBoard()
        for i in 0..<6 { _ = board.apply(update(id: "a\(i)", sent: Double(i)), now: at(Double(i))) }
        _ = board.apply(update(id: "x", plugin: "other", sent: 6), now: at(6))
        #expect(board.rows(for: "dl").map(\.id) == (1..<6).map { "dl:a\($0)" })
        #expect(board.rows(for: "other").count == 1)
    }

    @Test func removePlugin() {
        var board = ActivityBoard()
        _ = board.apply(update(), now: t0)
        board.remove(plugin: "dl")
        #expect(board.rows(for: "dl").isEmpty)
    }
}

/// 插件的紧急程度是它开着的活动里最急的那个；没有活动是平静
@Suite struct ActivityUrgencies {
    @Test func urgencies() {
        var board = ActivityBoard()
        #expect(board.urgency(for: "dl") == .calm)
        _ = board.apply(update(id: "a"), now: t0)
        #expect(board.urgency(for: "dl") == .active)
        _ = board.apply(update(id: "b", sent: 1, outcome: .attention), now: at(1))
        #expect(board.urgency(for: "dl") == .attention)
    }
}

/// 活动最长 8 小时（照 ActivityKit），写了 staleAt 就到那时；过期的行撤掉。App 按 `deadline` 到点调 `expire`
@Suite struct ActivityExpiry {
    @Test func expiresAtStaleAtOrMaxAge() {
        var board = ActivityBoard()
        _ = board.apply(update(id: "a", staleAt: at(60)), now: t0)
        _ = board.apply(update(id: "b", sent: 1), now: at(1))
        #expect(board.deadline == at(60))
        board.expire(now: at(59))
        #expect(board.rows(for: "dl").count == 2)
        board.expire(now: at(60))
        #expect(board.rows(for: "dl").map(\.id) == ["dl:b"])
        #expect(board.deadline == at(1 + 8 * 3600))
    }

    /// 更新不续命：8 小时从开始算（照 ActivityKit）
    @Test func updatesDoNotExtendMaxAge() {
        var board = ActivityBoard()
        _ = board.apply(update(.start), now: t0)
        _ = board.apply(update(sent: 3600), now: at(3600))
        #expect(board.deadline == at(8 * 3600))
    }
}

/// 弹卡：alert 时交给 App 弹；同一个活动的卡 id 不变，App 认出是同一张，原地刷新
@Suite struct ActivityCards {
    @Test func cardKeepsIDAcrossUpdates() {
        var board = ActivityBoard()
        let a = board.apply(update(.start, alert: true), now: t0)
        let b = board.apply(update(sent: 1, title: "快好了"), now: at(1))
        #expect(a?.alert == true && b?.alert == false)
        #expect(a?.card.id == b?.card.id && b?.card.title == "快好了")
        #expect(a?.key == .activity(plugin: "dl", id: "xcode"))
    }

    /// 结束时的卡也沿用这个 id：排着或正在放的那张换成结局
    @Test func endCardKeepsID() {
        var board = ActivityBoard()
        let a = board.apply(update(.start, alert: true), now: t0)
        let end = board.apply(update(.end, sent: 1, title: "下好了", outcome: .done, alert: true), now: at(1))
        #expect(end?.card.id == a?.card.id && end?.card.outcome == .done && end?.alert == true)
    }
}

/// 时间戳一样时按步骤先后：start < update < end。脚本 start 后不到一秒就 end，end 也要撤掉那一行；同一刻的重复消息照旧不算
@Suite struct ActivitySameInstant {
    @Test func endInSameInstantRemoves() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        _ = board.apply(update(sent: 1, title: "快好了"), now: at(1))
        #expect(board.rows(for: "dl").first?.title == "快好了")
        #expect(board.apply(update(.end, sent: 1), now: at(1)) != nil)
        #expect(board.rows(for: "dl").isEmpty)
    }

    @Test func startAfterEndInSameInstantIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(.end, sent: 1), now: at(1))
        #expect(board.apply(update(.start, sent: 1), now: at(1)) == nil)
        #expect(board.rows(for: "dl").isEmpty)
    }

    /// 同一刻开始的两个活动按 id 排，不随字典遍历顺序跳
    @Test func sameStartOrderedByID() {
        var board = ActivityBoard()
        for id in ["c", "a", "b"] { _ = board.apply(update(id: id, sent: 1), now: at(1)) }
        #expect(board.rows(for: "dl").map(\.id) == ["dl:a", "dl:b", "dl:c"])
    }
}

/// 新来的活动比开着的 5 个都旧、一进来就被挤掉：不弹卡（面板里也没有它那一行）
@Suite struct ActivityDroppedOnArrival {
    @Test func noCardWhenSelfDropped() {
        var board = ActivityBoard()
        for i in 0..<5 { _ = board.apply(update(id: "a\(i)", sent: Double(10 + i)), now: at(20)) }
        #expect(board.apply(update(id: "old", sent: 1, alert: true), now: at(20)) == nil)
        #expect(!board.rows(for: "dl").contains { $0.id == "dl:old" })
    }

    /// 卡的过期时刻跟着那一行：写了 staleAt 就到那时
    @Test func cardCarriesStaleAt() {
        var board = ActivityBoard()
        #expect(board.apply(update(alert: true, staleAt: at(30)), now: t0)?.staleAt == at(30))
    }
}

/// 结束了的活动（end、到 8 小时或 staleAt、被挤掉）不再收 update，只有新的 start 能重开（照 ActivityKit）
@Suite struct EndedActivity {
    @Test func updateAfterEndIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(.start, sent: 1), now: at(1))
        _ = board.apply(update(.end, sent: 2), now: at(2))
        #expect(board.apply(update(sent: 3), now: at(3)) == nil)
        #expect(board.rows(for: "dl").isEmpty)
    }

    @Test func updateAfterMaxAgeIgnored() {
        var board = ActivityBoard()
        _ = board.apply(update(.start), now: t0)
        board.expire(now: at(8 * 3600))
        #expect(board.apply(update(sent: 8 * 3600 + 60), now: at(8 * 3600 + 60)) == nil)
        #expect(board.rows(for: "dl").isEmpty)
        _ = board.apply(update(.start, sent: 8 * 3600 + 120), now: at(8 * 3600 + 120))
        #expect(board.rows(for: "dl").count == 1)
    }

    @Test func updateAfterDroppedIgnored() {
        var board = ActivityBoard()
        for i in 0..<6 { _ = board.apply(update(id: "a\(i)", sent: Double(i)), now: at(Double(i))) }
        #expect(board.apply(update(id: "a0", sent: 10), now: at(10)) == nil)
    }
}
