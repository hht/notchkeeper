import Foundation
import Testing
@testable import NotchCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private typealias Queue = CardQueue<String>

private func notice(_ card: String, session: Int32? = nil, seconds: TimeInterval = 6) -> Queue.Notice {
    Queue.Notice(card: card, key: session.map { .session($0) }, seconds: seconds)
}

private let sound = Queue.Change(sound: true)
private let silent = Queue.Change()

/// docs/ui.md「卡片」1、3：一个先进先出队列，一次放一张，卡放出来那一刻才响
@Suite struct NoticeQueue {
    @Test func postedNoticeShowsAndSounds() {
        var q = Queue()
        #expect(q.post(notice("a"), now: t0) == sound)
        #expect(q.showing == .notice("a"))
    }

    @Test func noticeCollapsesAfterItsSeconds() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        #expect(q.deadline(now: t0) == at(6))
        #expect(q.tick(now: at(5.9)) == silent)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(6))
        #expect(q.showing == nil)
        #expect(q.deadline(now: at(6)) == nil)
    }

    @Test func laterNoticeWaitsAndSoundsWhenShown() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        #expect(q.post(notice("b"), now: at(1)) == silent)
        #expect(q.showing == .notice("a"))
        #expect(q.tick(now: at(6)) == sound)
        #expect(q.showing == .notice("b"))
        _ = q.tick(now: at(12))
        #expect(q.showing == nil)
    }

    @Test func dismissShowsNext() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(notice("b"), now: t0)
        #expect(q.dismiss(now: at(1)) == sound)
        #expect(q.showing == .notice("b"))
        #expect(q.deadline(now: at(1)) == at(7))
    }

    /// 鼠标停在卡上暂停，移开从剩下的时间继续
    @Test func hoverPausesCountdown() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        q.pause(now: at(2))
        #expect(q.deadline(now: at(10)) == nil)
        _ = q.tick(now: at(10))
        #expect(q.showing == .notice("a"))
        q.resume(now: at(10))
        _ = q.tick(now: at(13.9))
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(14))
        #expect(q.showing == nil)
    }
}

/// docs/ui.md「卡片」2：还没放的、同一个会话的旧卡被它后来的卡原地替换
@Suite struct SameSessionKeepsLatest {
    @Test func waitingNoticeIsReplacedInPlace() {
        var q = Queue()
        _ = q.post(notice("a", session: 1), now: t0)
        _ = q.post(notice("b", session: 2), now: t0)
        _ = q.post(notice("d", session: 3), now: t0)
        _ = q.post(notice("c", session: 2), now: t0)
        var shown: [Queue.Showing?] = [q.showing]
        for s in [6.0, 12, 18] {
            _ = q.tick(now: at(s))
            shown.append(q.showing)
        }
        #expect(shown == [.notice("a"), .notice("c"), .notice("d"), nil])
    }

    @Test func showingNoticeIsNotReplaced() {
        var q = Queue()
        _ = q.post(notice("a", session: 1), now: t0)
        _ = q.post(notice("b", session: 1), now: t0)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(6))
        #expect(q.showing == .notice("b"))
    }

    @Test func noticesWithoutKeyAreNeverReplaced() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(notice("b"), now: t0)
        _ = q.post(notice("c"), now: t0)
        _ = q.tick(now: at(6))
        #expect(q.showing == .notice("b"))
    }
}

/// docs/ui.md「卡片」4、5 和红卡那一层
@Suite struct AlertLayer {
    /// 违规开始：正在放的卡回到队首，红卡先放满一次停留，再接着放队列（不再响），放完回到红卡
    @Test func violationPreemptsAndInterruptedNoticeReplaysSilently() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        #expect(q.raiseAlert(persistent: true, sound: true, seconds: 6, now: at(1)) == sound)
        #expect(q.showing == .alert(persistent: true))
        #expect(q.tick(now: at(7)) == silent)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(13))
        #expect(q.showing == .alert(persistent: true))
        #expect(q.deadline(now: at(13)) == nil)
        _ = q.tick(now: at(100))
        #expect(q.showing == .alert(persistent: true))
    }

    @Test func noticeWaitsDuringAlertsFirstShowing() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: t0)
        #expect(q.post(notice("a"), now: at(1)) == silent)
        #expect(q.showing == .alert(persistent: true))
        #expect(q.tick(now: at(6)) == sound)
        #expect(q.showing == .notice("a"))
    }

    @Test func noticeCoversHeldAlertAfterItsFirstShowing() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        #expect(q.showing == .alert(persistent: true))
        #expect(q.post(notice("a"), now: at(20)) == sound)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(26))
        #expect(q.showing == .alert(persistent: true))
    }

    /// 不常驻的红卡放满一次停留就收起，算用户关掉了这一次
    @Test func nonPersistentAlertTimesOutAsDismissed() {
        var q = Queue()
        _ = q.raiseAlert(persistent: false, sound: true, seconds: 6, now: t0)
        _ = q.post(notice("a"), now: at(1))
        #expect(q.tick(now: at(6)) == Queue.Change(sound: true, alertDismissed: true))
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(12))
        #expect(q.showing == nil)
    }

    @Test func dismissingAlertReportsIt() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: t0)
        #expect(q.dismiss(now: at(1)) == Queue.Change(alertDismissed: true))
        #expect(q.showing == nil)
    }

    /// 回到 healthy（或别处记下关掉了）：红卡撤掉；盖在上面的卡放完不再回到红卡
    @Test func clearedAlertDoesNotComeBack() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        _ = q.post(notice("a"), now: at(10))
        #expect(q.clearAlert(now: at(11)) == silent)
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(16))
        #expect(q.showing == nil)
    }

    @Test func clearingShownAlertShowsNext() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: t0)
        _ = q.post(notice("a"), now: at(1))
        #expect(q.clearAlert(now: at(2)) == sound)
        #expect(q.showing == .notice("a"))
    }

    /// 红卡已经挂着：不重弹、不重响
    @Test func raisingHeldAlertAgainChangesNothing() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        _ = q.post(notice("a"), now: at(10))
        #expect(q.raiseAlert(persistent: true, sound: true, seconds: 6, now: at(11)) == silent)
        #expect(q.showing == .notice("a"))
    }

    /// 守卫不响应时保留的红卡不响 Basso（docs/egress-guard.md）
    @Test func silentAlert() {
        var q = Queue()
        #expect(q.raiseAlert(persistent: true, sound: false, seconds: 6, now: t0) == silent)
        #expect(q.showing == .alert(persistent: true))
    }

    /// 恢复卡说的是上一次违规：新违规一开始就作废，不论排着还是正在放
    @Test(arguments: [false, true])
    func newViolationDropsRecoveredCard(_ persistent: Bool) {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(Queue.Notice(card: "recovered", key: .recovered, seconds: 4), now: t0)
        _ = q.raiseAlert(persistent: persistent, sound: true, seconds: 6, now: at(1))
        _ = q.tick(now: at(7))
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(13))
        #expect(q.showing == (persistent ? .alert(persistent: true) : nil))
    }

    @Test func newViolationDropsShowingRecoveredCard() {
        var q = Queue()
        _ = q.post(Queue.Notice(card: "recovered", key: .recovered, seconds: 4), now: t0)
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: at(1))
        _ = q.tick(now: at(7))
        #expect(q.showing == .alert(persistent: true))
    }

    /// 悬停暂停中的卡被违规打断，重放时从完整时长重新算
    @Test func interruptedPausedNoticeReplaysFullLength() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        q.pause(now: at(5))
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: at(10))
        _ = q.tick(now: at(16))
        #expect(q.showing == .notice("a"))
        #expect(q.deadline(now: at(16)) == at(22))
    }
}

@Suite struct QueueEdges {
    @Test func waitingRecoveredCardIsReplaced() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(Queue.Notice(card: "r1", key: .recovered, seconds: 4), now: t0)
        _ = q.post(Queue.Notice(card: "r2", key: .recovered, seconds: 4), now: t0)
        _ = q.tick(now: at(6))
        #expect(q.showing == .notice("r2"))
        _ = q.tick(now: at(10))
        #expect(q.showing == nil)
    }

    @Test func dismissWithNothingShownChangesNothing() {
        var q = Queue()
        #expect(q.dismiss(now: t0) == silent)
        #expect(q.showing == nil)
    }
}
