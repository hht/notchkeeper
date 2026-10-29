import Foundation
import Testing
import GuardCore
import MascotCore
@testable import Notchkeeper

private let since = Date(timeIntervalSince1970: 1_000)

/// 从「文件不存在」开始，改出想要的那一份
private func display(_ verdict: Verdict, _ reason: GuardDisplay.Reason = .fresh, unknown: UnknownReason? = nil,
                     last: Verdict? = nil) -> GuardDisplay {
    var d = GuardStateReader.display(data: nil, now: Date())
    d.verdict = verdict
    d.reason = reason
    d.unknownReason = unknown
    d.lastVerdict = last ?? (reason == .fresh ? verdict : nil)
    d.violatedSince = d.lastVerdict == .violated ? since : nil
    return d
}

/// docs/mascot.md §2：守卫状态画成哪个造型；探针没结果不改造型，只让右耳显示灰环
@Suite struct GuardLookTests {
    @Test(arguments: [
        (display(.healthy), Look.idle, false),
        (display(.egressMismatch), .mismatch, false),
        (display(.unknown, unknown: .offline), .offline, false),
        (display(.unknown, unknown: .probeFailed), .idle, true),
        (display(.unknown, .missing), .stale, false),
        (display(.unknown, .unreadable), .stale, false),
        (display(.unknown, .stale, last: .healthy), .stale, false),
        (display(.violated), .danger, false),
        // 守卫没响应但上次是 violated：和红卡保留的规则一致
        (display(.unknown, .stale, last: .violated), .danger, false),
        (display(.unknown, .clockSkew, last: .violated), .danger, false),
    ])
    func look(_ d: GuardDisplay, _ look: Look, _ probeFailed: Bool) {
        let p = GuardPresentation(d, dismissedViolationSince: nil)
        #expect(p.look == look && p.probeFailed == probeFailed)
    }

    /// 用户关掉红卡只是不再弹卡，违规还在，盾盾仍是危险
    @Test func dismissedViolationStaysDanger() {
        for d in [display(.violated), display(.unknown, .stale, last: .violated)] {
            #expect(GuardPresentation(d, dismissedViolationSince: .some(since)).look == .danger)
        }
    }
}
