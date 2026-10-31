import Foundation
import Testing
import NotchCore

private let t0 = Date(timeIntervalSinceReferenceDate: 0)

/// 悬停展开面板：在刘海上停一下才展开，离开一会儿才收起（docs/ui.md「原则」：悬停或点击展开）
@Suite struct PanelHovering {
    @Test func opensAfterDwellOnNotch() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0)
        #expect(!h.isOpen)
        #expect(h.deadline == t0 + PanelHover.openDelay)
        // 停着时继续动不重新计时
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0 + 0.1)
        h.tick(now: t0 + PanelHover.openDelay)
        #expect(h.isOpen)
        #expect(h.deadline == nil)
    }

    /// 只是路过：没停够就离开，不展开
    @Test func passingByDoesNotOpen() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0)
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0 + 0.05)
        #expect(h.deadline == nil)
        h.tick(now: t0 + 1)
        #expect(!h.isOpen)
    }

    /// 关了「悬停展开」或固定了展开 / 收起：悬停不展开，点击照样展开
    @Test func hoverDisabledStillOpensOnClick() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: false, now: t0)
        #expect(h.deadline == nil)
        h.open()
        #expect(h.isOpen)
    }

    /// 离开形状（含 10pt 余量）一会儿才收起；回来就不收
    @Test func closesAfterLeaving() {
        var h = PanelHover()
        h.open()
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0)
        #expect(h.isOpen)
        #expect(h.deadline == t0 + PanelHover.closeDelay)
        h.mouseMoved(onNotch: false, nearShape: true, canOpen: true, now: t0 + 0.1)
        #expect(h.deadline == nil)
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0 + 0.2)
        // 在外面继续动不重新计时
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0 + 0.3)
        h.tick(now: t0 + 0.2 + PanelHover.closeDelay)
        #expect(!h.isOpen)
    }

    /// 点击展开的面板不受「悬停展开」开关影响，离开时照样收起
    @Test func clickOpenedClosesOnLeaveEvenIfHoverDisabled() {
        var h = PanelHover()
        h.open()
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: false, now: t0)
        h.tick(now: t0 + PanelHover.closeDelay)
        #expect(!h.isOpen)
    }

    /// 没到点的 tick 什么也不做
    @Test func earlyTickIsIgnored() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0)
        h.tick(now: t0 + PanelHover.openDelay / 2)
        #expect(!h.isOpen && h.deadline == t0 + PanelHover.openDelay)
    }

    /// 打开设置、换固定方式、关掉悬停展开：立刻收起，等着的展开也作废
    @Test func closeCancelsEverything() {
        var h = PanelHover()
        h.mouseMoved(onNotch: true, nearShape: false, canOpen: true, now: t0)
        h.close()
        h.tick(now: t0 + 1)
        #expect(!h.isOpen && h.deadline == nil)
        h.open()
        h.mouseMoved(onNotch: false, nearShape: false, canOpen: true, now: t0)
        h.close()
        #expect(!h.isOpen && h.deadline == nil)
    }
}
