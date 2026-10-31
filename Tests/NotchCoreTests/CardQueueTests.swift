import Foundation
import Testing
@testable import NotchCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

private typealias Queue = CardQueue<String>

private func notice(_ card: String, session: Int32? = nil, seconds: TimeInterval = 6, lapses: Bool = false) -> Queue.Notice {
    Queue.Notice(card: card, key: session.map { .session($0) }, seconds: seconds, lapses: lapses)
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
        _ = q.setHovering(true, now: at(2))
        #expect(q.deadline(now: at(10)) == nil)
        _ = q.tick(now: at(10))
        #expect(q.showing == .notice("a"))
        _ = q.setHovering(false, now: at(10))
        _ = q.tick(now: at(13.9))
        #expect(q.showing == .notice("a"))
        _ = q.tick(now: at(14))
        #expect(q.showing == nil)
    }

    /// 悬停按卡算：换上来的卡照常倒计时，鼠标移进它才停。否则点掉一张卡后鼠标不动，下一张就一直不收（docs/ui.md「卡片」）
    @Test func nextCardStartsUnhovered() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.post(notice("b"), now: t0)
        _ = q.setHovering(true, now: at(1))
        _ = q.dismiss(now: at(2))
        #expect(q.showing == .notice("b"))
        #expect(q.deadline(now: at(2)) == at(8))
    }

    @Test func cardAfterCollapseStartsUnhovered() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setHovering(true, now: at(1))
        _ = q.dismiss(now: at(2))
        _ = q.post(notice("b"), now: at(10))
        #expect(q.deadline(now: at(10)) == at(16))
    }

    @Test func alertStartsUnhovered() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setHovering(true, now: at(1))
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: at(2))
        #expect(q.deadline(now: at(2)) == at(8))
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
        _ = q.setHovering(true, now: at(5))
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: at(10))
        _ = q.setHovering(false, now: at(10))
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

/// docs/ui.md「卡片」2：介入卡说的是此刻的状态，过期就撤，正在放也一样
@Suite struct LapsingNotices {
    @Test func laterCardOfSameSessionReplacesShowingLapsingNotice() {
        var q = Queue()
        _ = q.post(notice("approval", session: 1, lapses: true), now: t0)
        #expect(q.post(notice("done", session: 1), now: at(1)) == sound)
        #expect(q.showing == .notice("done"))
        #expect(q.deadline(now: at(1)) == at(7))
    }

    @Test func withdrawRemovesWaitingAndShowingLapsingNotices() {
        var q = Queue()
        _ = q.post(notice("x", session: 2), now: t0)
        _ = q.post(notice("approval", session: 1, lapses: true), now: t0)
        #expect(q.withdraw(.session(1), now: at(1)) == silent)
        _ = q.tick(now: at(6))
        #expect(q.showing == nil)

        _ = q.post(notice("question", session: 1, lapses: true), now: at(10))
        _ = q.post(notice("y", session: 3), now: at(10))
        #expect(q.withdraw(.session(1), now: at(11)) == sound)
        #expect(q.showing == .notice("y"))
    }

    /// 完成卡说的是已经发生的事，不撤
    @Test func withdrawKeepsNonLapsingNotices() {
        var q = Queue()
        _ = q.post(notice("done", session: 1), now: t0)
        _ = q.withdraw(.session(1), now: at(1))
        #expect(q.showing == .notice("done"))
    }

    @Test func withdrawingNoticeOverHeldAlertReturnsToAlert() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        _ = q.post(notice("approval", session: 1, lapses: true), now: at(10))
        _ = q.withdraw(.session(1), now: at(11))
        #expect(q.showing == .alert(persistent: true))
    }
}

/// docs/ui.md「卡片」8：熄屏或锁屏时台面上的卡停住，新来的卡不放、不响，回来接着放
@Suite struct ScreenAway {
    @Test func awayFreezesShowingNoticeAndHoldsNewOnes() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setAway(true, now: at(2))
        _ = q.tick(now: at(100))
        #expect(q.showing == .notice("a"))
        #expect(q.post(notice("b"), now: at(50)) == silent)
        #expect(q.setAway(false, now: at(100)) == silent)
        #expect(q.deadline(now: at(100)) == at(104))
        #expect(q.tick(now: at(104)) == sound)
        #expect(q.showing == .notice("b"))
    }

    @Test func noticePostedWhileAwayShowsAndSoundsOnReturn() {
        var q = Queue()
        _ = q.setAway(true, now: t0)
        #expect(q.post(notice("a"), now: at(1)) == silent)
        #expect(q.showing == nil)
        #expect(q.setAway(false, now: at(10)) == sound)
        #expect(q.showing == .notice("a"))
        #expect(q.deadline(now: at(10)) == at(16))
    }

    /// 红卡照样挂上（状态要对），但 Basso 等回来再响；红卡的第一次停留也从回来起算
    @Test func alertRaisedWhileAwaySoundsOnReturn() {
        var q = Queue()
        _ = q.setAway(true, now: t0)
        #expect(q.raiseAlert(persistent: true, sound: true, seconds: 6, now: at(1)) == silent)
        #expect(q.showing == .alert(persistent: true))
        #expect(q.setAway(false, now: at(30)) == sound)
        #expect(q.deadline(now: at(30)) == at(36))
    }

    /// 违规在离开期间已经恢复：回来不再补响
    @Test func alertClearedWhileAwayNeverSounds() {
        var q = Queue()
        _ = q.setAway(true, now: t0)
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: at(1))
        _ = q.clearAlert(now: at(2))
        #expect(q.setAway(false, now: at(30)) == silent)
        #expect(q.showing == nil)
    }

    @Test func hoveringAndAwayPauseIndependently() {
        var q = Queue()
        _ = q.post(notice("a"), now: t0)
        _ = q.setHovering(true, now: at(1))
        _ = q.setAway(true, now: at(2))
        _ = q.setAway(false, now: at(10))
        #expect(q.deadline(now: at(10)) == nil)
        _ = q.setHovering(false, now: at(10))
        #expect(q.deadline(now: at(10)) == at(15))
    }

    /// 常驻红卡放完第一次后锁屏，锁屏期间来的卡解锁后马上盖上去、响
    @Test func noticePostedOverHeldAlertWhileAwayShowsOnReturn() {
        var q = Queue()
        _ = q.raiseAlert(persistent: true, sound: true, seconds: 6, now: t0)
        _ = q.tick(now: at(6))
        _ = q.setAway(true, now: at(10))
        _ = q.post(notice("a"), now: at(11))
        #expect(q.showing == .alert(persistent: true))
        #expect(q.setAway(false, now: at(20)) == sound)
        #expect(q.showing == .notice("a"))
        #expect(q.deadline(now: at(20)) == at(26))
    }
}

