import Foundation
import Testing
@testable import Notchkeeper

/// 「多久以前」只说过去：刚写完的守卫状态、和现在一样或稍晚的时间，不说成「0 秒后」（英文界面是「in 0 sec.」）
@Suite struct AgoTextTense {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let en = Locale(identifier: "en_US")
    private let zh = Locale(identifier: "zh-Hans")

    @Test(arguments: [0.0, 0.4, 3])
    func nowOrLaterIsPast(_ ahead: TimeInterval) {
        let s = AgoText.string(now.addingTimeInterval(ahead), now: now, locale: en)
        #expect(s.hasSuffix("ago") && !s.hasPrefix("in "), "\(s)")
        #expect(AgoText.string(now.addingTimeInterval(ahead), now: now, locale: zh).hasSuffix("前"))
    }

    @Test func pastStaysAsIs() {
        #expect(AgoText.string(now.addingTimeInterval(-300), now: now, locale: en) == "5 min. ago")
    }
}
