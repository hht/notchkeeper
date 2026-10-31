import Foundation
import Testing
import GuardCore
@testable import NotchCore

private let healthy = display(.healthy)
private let mismatch = display(.egressMismatch)
private let offline = display(.unknown, unknown: .offline)
private let missing = display(.unknown, .missing)
private let violated = display(.violated)
private let stale = display(.unknown, .stale, last: .violated)
private let skew = display(.unknown, .clockSkew, last: .violated)
private let laterViolation = display(.violated, since: violatedAt + 60)

/// 从文件不存在开始，依次读完，返回每一步的动作
private func run(_ reads: [GuardDisplay], autoAlert: Bool = true, on alert: inout ViolationAlert) -> [ViolationAlert.Action] {
    reads.map { alert.read($0, autoAlert: autoAlert) }
}
private func run(_ reads: [GuardDisplay], autoAlert: Bool = true) -> [ViolationAlert.Action] {
    var alert = ViolationAlert(missing)
    return run(reads, autoAlert: autoAlert, on: &alert)
}

/// docs/egress-guard.md、docs/ui.md「卡片」：红卡什么时候挂上、换副标题、撤掉，恢复了弹不弹恢复卡
@Suite struct ViolationAlertTests {
    @Test func violationRaisesOnceUntilHealthy() {
        #expect(run([violated, offline, violated, missing, violated, healthy])
                == [.raise(.violated), .none, .none, .none, .none, .clear(recovered: true)])
    }

    @Test func recoveredOnlyOnce() {
        #expect(run([violated, healthy, healthy, offline, healthy]) == [.raise(.violated), .clear(recovered: true), .none, .none, .none])
    }

    @Test func healthyWithoutAlertDoesNothing() {
        #expect(run([mismatch, healthy]) == [.none, .none])
        #expect(run([offline, healthy]) == [.none, .none])
        #expect(run([missing, healthy]) == [.none, .none])
    }

    /// 守卫不响应且上次是 violated：保留红卡、换副标题、不响
    @Test func unresponsiveHoldsAlert() {
        for r in [stale, skew] {
            #expect(run([r]) == [.raise(.unresponsive)])
            #expect(run([violated, r, violated]) == [.raise(.violated), .replaceDetail(.unresponsive), .replaceDetail(.violated)])
        }
    }

    @Test func dismissedViolationStaysQuiet() {
        var a = ViolationAlert(missing)
        #expect(a.read(violated, autoAlert: true) == .raise(.violated))
        a.dismiss()
        #expect(a.presentation.tone == .violated && a.presentation.alert == nil)
        #expect(run([violated, stale], on: &a) == [.none, .none])
        #expect(a.presentation.tone == .unknown)
        // 新的一次违规不经过 healthy 也再弹
        #expect(a.read(laterViolation, autoAlert: true) == .raise(.violated))
    }

    @Test func healthyAfterDismissRecoversAndForgets() {
        var a = ViolationAlert(missing)
        _ = a.read(violated, autoAlert: true)
        a.dismiss()
        #expect(a.read(healthy, autoAlert: true) == .clear(recovered: true))
        // healthy 清掉关掉的记录：同一个 violatedSince 也再弹
        #expect(a.read(violated, autoAlert: true) == .raise(.violated))
    }

    /// 只在违规还挂着时记：没有违规时关掉（演示红卡）不算
    @Test func dismissWithoutViolationIsNotRemembered() {
        var a = ViolationAlert(missing)
        a.dismiss()
        #expect(a.read(violated, autoAlert: true) == .raise(.violated))
    }

    @Test func autoAlertOffNeverRaisesNorRecovers() {
        #expect(run([violated, healthy], autoAlert: false) == [.none, .none])
    }

    @Test func demoAlertClearsOnHealthyWithoutRecovered() {
        var a = ViolationAlert(missing)
        #expect(a.demo() == .raise(.violated))
        #expect(a.read(healthy, autoAlert: true) == .clear(recovered: false))
        #expect(a.read(healthy, autoAlert: true) == .none)
    }

    @Test func demoAlertThenRealViolationRecovers() {
        var a = ViolationAlert(missing)
        _ = a.demo()
        #expect(run([violated, healthy], on: &a) == [.none, .clear(recovered: true)])
    }
}

/// 旧 --selftest 的「任何以 healthy 结尾的序列都没有红卡」
@Suite struct ViolationAlertEndings {
    @Test(arguments: [
        [violated, healthy], [violated, offline, healthy], [violated, stale, healthy], [violated, skew, missing, healthy],
        [stale, healthy], [mismatch, violated, mismatch, healthy],
    ])
    func endsCleared(_ reads: [GuardDisplay]) {
        #expect(run(reads).last == .clear(recovered: true))
    }

    /// 红卡挂着时关掉「出口异常时弹出红卡」：不再动它，回到 healthy 照样撤、照样弹恢复卡
    @Test func autoAlertTurnedOffWhileShown() {
        var a = ViolationAlert(missing)
        _ = a.read(violated, autoAlert: true)
        #expect(a.read(stale, autoAlert: false) == .none)
        #expect(a.read(healthy, autoAlert: false) == .clear(recovered: true))
    }
}
