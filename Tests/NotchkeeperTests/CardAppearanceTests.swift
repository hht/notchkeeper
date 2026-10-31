import AppKit
import SwiftUI
import Testing
import MascotCore
import NotchCore
@testable import Notchkeeper

/// 每种结果的 Pip 造型和提示音（docs/ui.md「卡片」7、docs/agent-integration.md「提醒」）
@Suite struct CardAppearance {
    @Test(arguments: [
        (Card.Outcome.done, Look.finished, "Glass" as String?),
        (.recovered, .finished, "Glass"),
        (.failed, .error, "Funk"),
        (.question, .question, "Ping"),
        (.approval, .approval, "Ping"),
        (.attention, .question, "Ping"),
        (.info, .idle, nil),
        (.violation, .danger, "Basso"),
    ])
    func lookAndSound(_ outcome: Card.Outcome, _ look: Look, _ sound: String?) {
        let card = Card(source: .exitGuard, title: "t", outcome: outcome)
        #expect(card.look == look && card.sound.map { $0 as String } == sound)
    }

    /// 正文只认行内格式：链接和图片都去掉（动作只走点卡片和按钮；不收图片路径）
    @Test @MainActor func markdownDropsLinksAndImages() {
        let s = CardBlockView.markdown("**粗** [链接](https://example.com) ![图](file:///etc/hosts)")
        #expect(s.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
        #expect(s.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized })
    }
}
