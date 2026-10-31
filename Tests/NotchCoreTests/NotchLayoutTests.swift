import CoreGraphics
import Foundation
import Testing
import NotchCore

@Suite struct NotchLayoutRules {
    /// 卡片是短暂弹出的展开态，和面板等宽，元素保持相对位置（docs/ui.md「卡片」，HIG Live Activities）
    @Test(arguments: [CGSize(width: 185, height: 32), .zero])
    func cardIsAsWideAsDashboard(notch: CGSize) {
        let card = NotchLayout.size(.card, notch: notch, panel: PanelShape(header: true, list: []), cardContent: NotchLayout.cardRowHeight, ears: true)
        let dashboard = NotchLayout.size(.dashboard, notch: notch, panel: PanelShape(header: true, list: []), cardContent: 0, ears: true)
        #expect(card.width == dashboard.width)
    }

    /// 面板最满时（每段都只露 1 行、段数到上限，或行数到上限）也装得进刘海窗口
    @Test(arguments: [CGSize(width: 185, height: 38), CGSize(width: 180, height: 0)])
    func fullestPanelFitsWindow(notch: CGSize) {
        let rows = (0..<10).map { PanelSection(plugin: "p\($0)", rows: Array(repeating: row, count: 9), maxRows: 5) }
        for sections in [rows, rows.map { var s = $0; s.maxRows = 1; return s }] {
            let shape = PanelShape(guardEnabled: true, sections: sections)
            #expect(NotchLayout.size(.dashboard, notch: notch, panel: shape, cardContent: 0, ears: true).height <= NotchLayout.windowSize.height)
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

private let row = PanelRow(id: "r", icon: .claude, title: "~/x", indicator: .working, trailing: .value("1"))

/// 面板按插件分段（docs/ui.md「面板布局」）：出口守卫在顶上，其余各段按顺序、每段至多露自己的行数，合起来至多 6 行
@Suite struct PanelShapes {
    private func section(_ id: String, rows: Int, max: Int = 5) -> PanelSection {
        PanelSection(plugin: id, rows: Array(repeating: row, count: rows), maxRows: max)
    }

    @Test func rowsPerSection() {
        let shape = PanelShape(guardEnabled: true, sections: [section("claude", rows: 2), section("dl", rows: 7, max: 3)])
        #expect(shape == PanelShape(header: true, list: [.init(plugin: "claude", rows: 2), .init(plugin: "dl", rows: 3)]))
    }

    /// 空的段不画；都空时一行占位
    @Test func emptySectionsHidden() {
        #expect(PanelShape(guardEnabled: true, sections: [section("claude", rows: 0), section("dl", rows: 1)]).list == [.init(plugin: "dl", rows: 1)])
        #expect(PanelShape(guardEnabled: false, sections: [section("claude", rows: 0)]) == PanelShape(header: false, list: []))
    }

    /// 合起来至多 6 行：排在前面的先拿，拿不到的段不画
    @Test func budgetAcrossSections() {
        let shape = PanelShape(guardEnabled: true, sections: [section("a", rows: 5), section("b", rows: 5), section("c", rows: 5)])
        #expect(shape.list == [.init(plugin: "a", rows: 5), .init(plugin: "b", rows: 1)])
    }

    /// 只开了守卫：没有列表；一个插件都没开：一行占位（「还没有开启的插件」）
    @Test func guardOnlyAndNothing() {
        #expect(PanelShape(guardEnabled: true, sections: []) == PanelShape(header: true, list: nil))
        #expect(PanelShape(guardEnabled: false, sections: []) == PanelShape(header: false, list: []))
    }

    @Test func heights() {
        let notch = CGSize(width: 185, height: 32)
        func h(_ shape: PanelShape) -> CGFloat { NotchLayout.size(.dashboard, notch: notch, panel: shape, cardContent: 0, ears: true).height }
        let guardOnly = h(PanelShape(header: true, list: nil))
        #expect(h(PanelShape(header: true, list: [])) == guardOnly + NotchLayout.listGap + NotchLayout.rowHeight + 2 * NotchLayout.listInset)
        #expect(h(PanelShape(header: false, list: nil)) == guardOnly - NotchLayout.dashStatusHeight)
        let two = h(PanelShape(header: true, list: [.init(plugin: "a", rows: 1), .init(plugin: "b", rows: 2)]))
        #expect(two == guardOnly + NotchLayout.listGap + 3 * NotchLayout.rowHeight + 4 * NotchLayout.listInset + NotchLayout.sectionGap)
    }

    /// 收起时没有耳朵就是刘海本身（关掉了左耳的 Pip、右耳也没东西）
    @Test func closedWithoutEars() {
        let notch = CGSize(width: 185, height: 32)
        #expect(NotchLayout.size(.closed, notch: notch, panel: PanelShape(header: true, list: nil), cardContent: 0, ears: false) == notch)
        #expect(NotchLayout.size(.closed, notch: notch, panel: PanelShape(header: true, list: nil), cardContent: 0, ears: true).width
                == notch.width + 2 * NotchLayout.earWidth)
    }
}
