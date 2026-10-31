import Foundation
import Testing
import GuardCore
import MascotCore
@testable import NotchCore

let violatedAt = Date(timeIntervalSince1970: 1_000)

/// 从「文件不存在」开始，改出想要的那一份
func display(_ verdict: Verdict, _ reason: GuardDisplay.Reason = .fresh, unknown: UnknownReason? = nil,
             last: Verdict? = nil, since: Date = violatedAt) -> GuardDisplay {
    var d = GuardStateReader.display(data: nil, now: Date())
    d.verdict = verdict
    d.reason = reason
    d.unknownReason = unknown
    d.lastVerdict = last ?? (reason == .fresh ? verdict : nil)
    d.violatedSince = d.lastVerdict == .violated ? since : nil
    return d
}

/// docs/egress-guard.md「怎么画」、docs/mascot.md §2：守卫读数画成什么、要不要红卡
@Suite struct GuardPresentationTests {
    @Test(arguments: [
        (display(.healthy), GuardPresentation.Status.healthy, GuardPresentation.Tone.healthy, Look.idle),
        (display(.egressMismatch), .mismatch, .mismatch, .mismatch),
        (display(.unknown, unknown: .offline), .offline, .unknown, .offline),
        // 探针没结果不改造型，只让右耳显示灰环
        (display(.unknown, unknown: .probeFailed), .probeFailed, .unknown, .idle),
        (display(.unknown, .missing), .unresponsive, .unknown, .stale),
        (display(.unknown, .unreadable), .unresponsive, .unknown, .stale),
        (display(.unknown, .stale, last: .healthy), .unresponsive, .unknown, .stale),
        (display(.violated), .violated, .violated, .danger),
        // 守卫没响应但上次是 violated：红卡保留，和违规一样画
        (display(.unknown, .stale, last: .violated), .violated, .violated, .danger),
        (display(.unknown, .clockSkew, last: .violated), .violated, .violated, .danger),
    ])
    func status(_ d: GuardDisplay, _ status: GuardPresentation.Status, _ tone: GuardPresentation.Tone, _ look: Look) {
        let p = GuardPresentation(d, dismissedViolationSince: nil)
        #expect(p.status == status && p.tone == tone && p.look == look)
    }

    @Test func alertOnlyWhileViolationHolds() {
        #expect(GuardPresentation(display(.violated), dismissedViolationSince: nil).alert == .violated)
        // 守卫不响应时保留的红卡换副标题、不响 Basso
        let held = GuardPresentation(display(.unknown, .stale, last: .violated), dismissedViolationSince: nil)
        #expect(held.alert == .unresponsive && !held.alert!.sounds)
        #expect(GuardPresentation.Alert.violated.sounds)
        for d in [display(.healthy), display(.egressMismatch), display(.unknown, unknown: .offline), display(.unknown, .missing),
                  display(.unknown, .stale, last: .healthy)] {
            #expect(GuardPresentation(d, dismissedViolationSince: nil).alert == nil)
        }
    }

    /// 用户关掉的是哪一次：同一次不再要红卡，Pip 仍是危险；违规仍在画红点，守卫不响应画灰环
    @Test func dismissedViolation() {
        let dv = GuardPresentation(display(.violated), dismissedViolationSince: .some(violatedAt))
        #expect(dv.alert == nil && dv.status == .violated && dv.tone == .violated && dv.look == .danger && dv.holdsViolation)
        let ds = GuardPresentation(display(.unknown, .stale, last: .violated), dismissedViolationSince: .some(violatedAt))
        #expect(ds.alert == nil && ds.status == .violationUnconfirmed && ds.tone == .unknown && ds.look == .danger && ds.holdsViolation)
        // 新的一次违规照样要红卡
        let next = GuardPresentation(display(.violated, since: violatedAt + 60), dismissedViolationSince: .some(violatedAt))
        #expect(next.alert == .violated)
        // 旧 guardd 没写 violatedSince：关掉记 nil 也算
        var noSince = display(.violated)
        noSince.violatedSince = nil
        #expect(GuardPresentation(noSince, dismissedViolationSince: .some(nil)).alert == nil)
    }

    @Test func holdsViolationOnlyForViolation() {
        for d in [display(.healthy), display(.egressMismatch), display(.unknown, unknown: .offline), display(.unknown, .stale, last: .healthy)] {
            #expect(!GuardPresentation(d, dismissedViolationSince: nil).holdsViolation)
        }
    }
}
