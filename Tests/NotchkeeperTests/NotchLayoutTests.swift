import AppKit
import SwiftUI
import Testing
import NotchCore
@testable import Notchkeeper

@Suite struct NotchLayoutRules {
    /// 卡片是短暂弹出的展开态，和面板等宽，元素保持相对位置（docs/ui.md「卡片」，HIG Live Activities）
    @Test(arguments: [CGSize(width: 185, height: 32), .zero])
    func cardIsAsWideAsDashboard(notch: CGSize) {
        let card = NotchLayout.size(.card, notch: notch, rows: 0, cardContent: NotchLayout.cardRowHeight)
        let dashboard = NotchLayout.size(.dashboard, notch: notch, rows: 0, cardContent: 0)
        #expect(card.width == dashboard.width)
    }

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
            #expect(NotchLayout.size(.card, notch: notch, rows: 0, cardContent: content).height <= NotchController.windowSize.height)
        }
    }

    /// 小字（≤17pt）对比度至少 4.5:1（HIG Accessibility）；黑底和会话容器的白 0.06 底上都要够
    @Test(arguments: [0, 0.06])
    func secondaryTextMeetsContrast(background: Double) {
        let text = background + NotchLayout.secondaryTextOpacity * (1 - background)
        #expect(contrast(text, background) >= 4.5)
    }

    /// WCAG 2 对比度；按 sRGB 编码值合成，比按线性值合成算出的对比度低，是保守的一侧
    private func contrast(_ a: Double, _ b: Double) -> Double {
        func luminance(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }
}
