import AppKit
import SwiftUI
import Testing
import NotchCore
@testable import Notchkeeper

@Suite struct CardFitsWindow {
    /// 卡片按内容的自然高度长；内容最满的卡也装得进刘海窗口（docs/ui.md「卡片」）
    @Test @MainActor func fullestCardFitsWindow() {
        let notch = CGSize(width: 185, height: 32)
        let long = String(repeating: "很长的一句话", count: 40)
        let source = Card.Source.plugin(id: "x", name: long, symbol: "sparkles")
        let buttons = [Card.Button(title: long, action: .activate(bundleID: "x")), Card.Button(title: long, action: .activate(bundleID: "y"))]
        let cards = [
            Card(source: source, title: long, subtitle: long, value: long, outcome: .done, block: .text([long, long, long]), buttons: buttons),
            Card(source: source, title: long, outcome: .failed, block: .log([long, long, long]), buttons: buttons),
            Card(source: source, title: long, outcome: .info, block: .facts((1...4).map { _ in Card.Fact(title: long, value: long) }), buttons: buttons),
        ]
        for card in cards {
            let content = NSHostingView(rootView: NotchCardView(card: card, onDismiss: {}, onAction: { _ in })
                .frame(width: NotchLayout.dashWidth).fixedSize(horizontal: false, vertical: true)).fittingSize.height
            #expect(content > NotchLayout.cardRowHeight)
            #expect(NotchLayout.size(.card, notch: notch, panel: PanelShape(header: true, list: []), cardContent: content, ears: true).height
                    <= NotchLayout.windowSize.height)
        }
    }
}
