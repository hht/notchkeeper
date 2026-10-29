import Testing
import MascotCore
@testable import Notchkeeper

/// 收起态左耳不画 sign 装饰，也就不能给这些不存在的部件挂循环（10-29 实机崩溃：出口不符时左耳的循环找不到装饰层）
@Suite struct MascotLoopTests {
    @Test func hiddenSignsHaveNoDecoLoops() {
        for l in Look.allCases where l.isSign {
            let tracks = MascotFigureView.loops(l, size: .small, reduceMotion: false, hidesSigns: true)
            #expect(!tracks.contains { if case .decoPart = $0.part { return true } else { return false } }, "\(l)")
            #expect(tracks.contains { $0.part == .body }, "身体照样呼吸：\(l)")
        }
    }

    /// 心情装饰留在左耳，照常循环
    @Test func moodLoopsStay() {
        let tracks = MascotFigureView.loops(.sleeping, size: .small, reduceMotion: false, hidesSigns: true)
        #expect(tracks == Choreography.loop(.sleeping, size: .small, reduceMotion: false))
    }
}
