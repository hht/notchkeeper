import Foundation
import Testing
@testable import GuardCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

/// 默认参数：guardd 5 秒一轮，事件合并 100ms，兜底 30 秒
/// Date 是浮点秒，加法顺序不同会差一个 ULP
private func near(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 1e-6 }

private func schedule() -> GuardReadSchedule { GuardReadSchedule(now: t0) }

@Suite struct GuardReadScheduling {
    @Test func firstReadIsDueImmediately() {
        #expect(schedule().isReadDue(at: t0))
    }

    @Test func directoryEventReadsAfterDebounce() {
        var s = schedule()
        s.didRead(checkedAt: at(0), at: t0)
        s.directoryChanged(at: at(1))
        #expect(!s.isReadDue(at: at(1.05)))
        #expect(s.isReadDue(at: at(1.101)))
        #expect(near(s.nextReadAt, at(1.1)))
    }

    /// guardd 的 temp 写 + rename、同目录 config.json 一起改：100ms 内的事件只读一次，且以第一个事件起算，
    /// 持续不断的事件也不会把读推迟到无限远
    @Test func rapidEventsCoalesceIntoOneRead() {
        var s = schedule()
        s.didRead(checkedAt: at(0), at: t0)
        s.directoryChanged(at: at(1))
        s.directoryChanged(at: at(1.03))
        s.directoryChanged(at: at(1.08))
        #expect(near(s.nextReadAt, at(1.1)))
        s.didRead(checkedAt: at(1), at: at(1.1))
        #expect(!s.isReadDue(at: at(1.2)))
    }

    /// guardd 停了就不再写文件：没有事件也要在 checkedAt + 3 个间隔后重读一次，让 reader 报 stale
    @Test func staleDeadlineRequestsReadWithoutEvents() {
        var s = schedule()
        s.didRead(checkedAt: at(0), at: at(0.2))
        #expect(!s.isReadDue(at: at(15)))
        #expect(s.isReadDue(at: at(15.101)))
        // 到点读出来的就是 stale，红卡靠 lastVerdict 保留
        #expect(GuardStateReader.display(data: violatedFile(checkedAt: at(0)), now: s.nextReadAt).reason == .stale)
        #expect(GuardStateReader.display(data: violatedFile(checkedAt: at(0)), now: s.nextReadAt).lastVerdict == .violated)
    }

    @Test func eachReadRearmsStaleDeadline() {
        var s = schedule()
        s.didRead(checkedAt: at(0), at: at(0.1))
        s.didRead(checkedAt: at(5), at: at(5.1))
        #expect(!s.isReadDue(at: at(15.15)))
        #expect(s.isReadDue(at: at(20.101)))
    }

    /// 已经过期的文件不再挂过期定时器（再读也还是 stale），只剩兜底
    @Test func alreadyStaleFileFallsBackToFallbackTick() {
        var s = schedule()
        s.didRead(checkedAt: at(-100), at: t0)
        #expect(near(s.nextReadAt, at(30)))
    }

    @Test func missingFileReliesOnFallbackTick() {
        var s = schedule()
        s.didRead(checkedAt: nil, at: t0)
        #expect(!s.isReadDue(at: at(29.9)))
        #expect(s.isReadDue(at: at(30.001)))
    }

    /// 没事件、文件也没给过期时间（比如时钟跳到未来很远）时，30 秒兜底照样读
    @Test func fallbackTickEvery30Seconds() {
        var s = schedule()
        s.didRead(checkedAt: at(3600), at: t0)
        #expect(near(s.nextReadAt, at(30)))
        s.didRead(checkedAt: at(3600), at: at(30))
        #expect(near(s.nextReadAt, at(60)))
    }

    @Test func intervalAndDurationsAreInjectable() {
        var s = GuardReadSchedule(interval: .seconds(10), debounce: .milliseconds(500), fallbackInterval: .seconds(60), now: t0)
        s.didRead(checkedAt: at(0), at: t0)
        #expect(near(s.nextReadAt, at(30.1))) // 3 × 10s + 余量
        s.directoryChanged(at: at(1))
        #expect(near(s.nextReadAt, at(1.5)))
    }
}

private func violatedFile(checkedAt: Date) -> Data {
    let s = GuardState(verdict: .violated, observation: Observation(clashRunning: true, routeInterface: "utun1024", egressIPs: []),
                       allowlist: [], egressFailures: [:], networkPath: nil, violatedSince: checkedAt, checkedAt: checkedAt)
    return try! s.encoded()
}
