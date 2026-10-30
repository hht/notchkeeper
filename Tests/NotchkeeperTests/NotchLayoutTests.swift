import CoreGraphics
import Testing
@testable import Notchkeeper

@Suite struct NotchLayoutRules {
    /// 卡片是短暂弹出的展开态，和面板等宽，元素保持相对位置（docs/ui.md「卡片」，HIG Live Activities）
    @Test(arguments: [CGSize(width: 185, height: 32), .zero])
    func cardIsAsWideAsDashboard(notch: CGSize) {
        let card = NotchLayout.size(.card, notch: notch, rows: 0)
        let dashboard = NotchLayout.size(.dashboard, notch: notch, rows: 0)
        #expect(card.width == dashboard.width)
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
