import Testing
@testable import MascotCore

private let deg = Double.pi / 180

/// 某次编排里所有 Track（循环、进场、动作、右耳的点）
private func everything(reduceMotion: Bool) -> [Track] {
    let looks = Look.allCases.flatMap { l in
        Size.allCases.flatMap { s in Choreography.loop(l, size: s, reduceMotion: reduceMotion) }
            + Choreography.entrance(l, reduceMotion: reduceMotion)
    }
    return looks + Motion.allCases.flatMap { Choreography.tracks(for: $0, reduceMotion: reduceMotion) }
        + Choreography.earDots(reduceMotion: reduceMotion)
}

private func loop(_ l: Look, _ part: Part, _ p: Property, size: Size = .large) -> Track? {
    Choreography.loop(l, size: size, reduceMotion: false).first { $0.part == part && $0.property == p }
}

private func near(_ a: [Double]?, _ b: [Double]) -> Bool {
    guard let a, a.count == b.count else { return false }
    return zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
}

@Suite struct TrackShape {
    @Test func everyTrackIsWellFormed() {
        for t in everything(reduceMotion: false) + everything(reduceMotion: true) {
            #expect(t.duration > 0, "\(t)")
            #expect(t.phase >= 0 && t.phase < t.duration, "相位在一圈之内：\(t)")
            if case .spring = t.timings.first {
                #expect(t.values.count == 2 && t.timings.count == 1 && !t.repeats, "弹簧只能是一段：\(t)")
            } else {
                #expect(t.keyTimes.count == t.values.count, "\(t)")
                #expect(t.timings.count == t.values.count - 1, "\(t)")
                #expect(t.keyTimes.first == 0 && t.keyTimes.last == 1, "\(t)")
                #expect(zip(t.keyTimes, t.keyTimes.dropFirst()).allSatisfy { $0 <= $1 }, "\(t)")
            }
        }
    }

    /// 动画都叠加在静止值上：一次性动作播完必须回到 0（整圈旋转除外），否则结束那一刻会跳
    @Test func oneShotsEndAtRest() {
        for t in everything(reduceMotion: false) where !t.repeats {
            #expect(t.values.last == 0 || isFullTurn(t), "\(t)")
        }
    }

    /// 循环首尾相接，否则每圈开头会跳。例外：整圈旋转；四角星转 90°（转完和原来一样）；
    /// 同一部件首尾时刻完全透明的（Z 和汗珠回到原处时看不见）
    @Test func loopsAreSeamless() {
        for l in Look.allCases {
            for s in Size.allCases {
                let tracks = Choreography.loop(l, size: s, reduceMotion: false)
                for t in tracks where t.values.first != t.values.last {
                    let star = l == .finished && t.part == .decoPart(0) && t.property == .rotationZ
                    let hidden = tracks.contains { $0.part == t.part && $0.property == .opacity && $0.values.first == -1 && $0.values.last == -1 }
                    #expect(isFullTurn(t) || star || hidden, "\(l) \(t)")
                }
            }
        }
    }
}

private func isFullTurn(_ t: Track) -> Bool {
    [.rotationX, .rotationY, .rotationZ].contains(t.property) && abs(abs(t.values.last! - t.values.first!) - 2 * .pi) < 1e-9
}

@Suite struct ReduceMotion {
    /// docs/mascot.md §5「减弱动态效果」：不位移、不缩放、不旋转，只剩不透明度
    @Test func onlyOpacity() {
        for t in everything(reduceMotion: true) { #expect(t.property == .opacity, "\(t)") }
    }

    @Test func motionsAndEntrancesAreDropped() {
        for m in Motion.allCases { #expect(Choreography.tracks(for: m, reduceMotion: true).isEmpty) }
        for l in Look.allCases { #expect(Choreography.entrance(l, reduceMotion: true).isEmpty) }
    }

    /// 颜色和眼形 0.15s 淡入淡出；朝向直接设值
    @Test func change() {
        let c = Choreography.change(reduceMotion: true)
        #expect(c.eyeMorph == 0.15 && c.colorFade == 0.15 && c.pose == nil && c.decoPop == nil && c.loopDelay == 0)
    }
}

@Suite struct LookChangeTests {
    /// docs/mascot.md §5「换造型」
    @Test func numbers() {
        let c = Choreography.change(reduceMotion: false)
        #expect(c.eyeMorph == 0.38 && c.colorFade == 0.4)
        #expect(c.pose == .spring(response: 0.5, damping: 0.75))
        #expect(c.decoExit == 0.18 && c.decoExitScale == 0.4)
        #expect(c.decoEnterDelay == 0.1 && c.decoPop == .spring(response: 0.38, damping: 0.6) && c.decoFadeIn == 0.16)
        #expect(c.loopDelay == 0.4)
    }
}

@Suite struct Breathing {
    /// docs/mascot.md §5：所有造型都呼吸，周期 4.6s，scaleY +0.03、scaleX −0.01
    @Test func everyLookBreathes() {
        for l in Look.allCases where l != .sleeping {
            let y = loop(l, .body, .scaleY), x = loop(l, .body, .scaleX)
            #expect(y?.duration == 4.6 && near(y?.values, [0, 0.03, 0]) && near(x?.values, [0, -0.01, 0]), "\(l)")
            #expect(y?.timings == [.sineInOut, .sineInOut])
        }
    }

    /// 睡着：6s，scaleY +0.045
    @Test func sleeping() {
        let y = loop(.sleeping, .body, .scaleY)
        #expect(y?.duration == 6 && near(y?.values, [0, 0.045, 0]))
    }
}

@Suite struct HeadLoops {
    /// docs/mascot.md §5「身体和头」
    @Test func working() {
        let t = loop(.working, .yaw, .rotationY)
        #expect(t?.duration == 1.4 && t?.phase == 0.45 && near(t?.values, [-7 * deg, 7 * deg, -7 * deg, -7 * deg]))
        #expect(near(t?.keyTimes, [0, 0.9 / 1.4, 1.15 / 1.4, 1]))
    }

    @Test func longTurnReadsFaster() {
        let t = loop(.longTurn, .yaw, .rotationY)
        #expect(t?.duration == 1.0 && t?.phase == 0.3)
    }

    @Test func others() {
        #expect(near(loop(.sleeping, .pitch, .rotationX)?.values, [0, -4 * deg, 0]))
        #expect(loop(.thinking, .yaw, .rotationY)?.duration == 3.6)
        #expect(near(loop(.dizzy, .roll, .rotationZ)?.values, [0, 6 * deg, 0, -6 * deg, 0]))
        #expect(near(loop(.offline, .yaw, .rotationY)?.values, [0, -25 * deg, -25 * deg, 25 * deg, 25 * deg, 0, 0]))
        #expect(loop(.idle, .yaw, .rotationY) == nil)
    }
}

@Suite struct DecoLoops {
    /// 编排里点名的装饰部件都得真的存在
    @Test func referencedPartsExist() {
        for l in Look.allCases {
            for s in Size.allCases {
                let n = l.decoration(s).count
                for t in Choreography.loop(l, size: s, reduceMotion: false) {
                    if case .decoPart(let i) = t.part { #expect(i < n, "\(l) \(s) \(t)") }
                }
            }
        }
    }

    /// 三个 Z 每秒一个：周期 3s，相位 0、2、1
    @Test func zzz() {
        let phases = (0..<3).map { loop(.sleeping, .decoPart($0), .translationY)?.phase }
        #expect(phases == [0, 2, 1])
        #expect(near(loop(.sleeping, .decoPart(0), .opacity)?.values, [-1, 0, 0, -1]))
    }

    /// 不透明度都换算成叠加量：小星静止 0.6，闪到 1、暗到 0.25
    @Test func opacityIsAdditive() {
        #expect(near(loop(.finished, .decoPart(1), .opacity)?.values, [0, 0.4, -0.35, 0]))
        #expect(near(loop(.offline, .decoPart(0), .opacity)?.values, [-0.75, 0, -0.75, -0.75]))
        #expect(loop(.offline, .decoPart(3), .opacity) == nil, "斜杠不动")
    }

    /// 两个 ! 轮流跳，第二个错开 0.24s
    @Test func dangerAlternates() {
        #expect(loop(.danger, .decoPart(0), .translationY)?.phase == 0)
        let p = loop(.danger, .decoPart(1), .translationY)?.phase ?? 0
        #expect(abs(p - 0.66) < 1e-9)
    }

    /// 右耳三蓝点依次亮：周期 1.2s，相邻错开 0.2s
    @Test func earDots() {
        let t = Choreography.earDots(reduceMotion: false)
        #expect(t.count == 3 && t.allSatisfy { $0.duration == 1.2 && $0.property == .opacity })
        #expect(near(t.map(\.phase), [0, 1.0, 0.8]))
    }
}

@Suite struct Motions {
    /// docs/mascot.md §5「动作」：只出现有动的分量
    @Test func channels() {
        let spin = Choreography.tracks(for: .spinAround, reduceMotion: false)
        #expect(spin.count == 1 && spin[0].part == .yaw && near(spin[0].values, [0, 2 * .pi]) && spin[0].duration == 0.9)
        let curious = Choreography.tracks(for: .curious, reduceMotion: false)
        #expect(Set(curious.map(\.part)) == [.yaw, .pitch, .roll])
        let jump = Choreography.tracks(for: .finishJump, reduceMotion: false)
        #expect(Set(jump.map(\.part)) == [.yaw, .stage])
        #expect(near(jump.first { $0.part == .stage }?.values, [0, 1, -4, 0, 0]))
    }

    /// 进 finished 跳、进 working 点头、进 danger 横向抖三下
    @Test func entrances() {
        #expect(Choreography.entrance(.finished, reduceMotion: false) == Choreography.tracks(for: .finishJump, reduceMotion: false))
        #expect(Choreography.entrance(.working, reduceMotion: false) == Choreography.tracks(for: .nod, reduceMotion: false))
        let shake = Choreography.entrance(.danger, reduceMotion: false)
        #expect(shake.count == 1 && shake[0].part == .stage && shake[0].property == .translationX && shake[0].duration == 0.45)
        #expect(Choreography.entrance(.idle, reduceMotion: false).isEmpty)
    }
}

@Suite struct Retarget {
    /// 静止值已经改成 new，叠加动画从 old − new 回到 0：画面从 old 连贯地过渡到 new
    @Test func springStartsAtOldAndSettles() {
        let t = Choreography.retarget(.yaw, .rotationY, from: 0.1, to: 0.3, Choreography.followSpring)
        #expect(t.values == [0.1 - 0.3, 0] && t.timings == [.spring(response: 0.3, damping: 0.85)] && t.duration == 0.3)
    }

    /// 鼠标停下后回正：0.8s 正弦
    @Test func sineTakesGivenDuration() {
        let t = Choreography.retarget(.pitch, .rotationX, from: 0.2, to: 0, Choreography.gazeReturn)
        #expect(t.values == [0.2, 0] && t.duration == 0.8 && t.timings == [.sineInOut])
    }
}

/// 循环在某一刻自己叠了多少：撤循环时只把这一份补间收尾，不碰同一层上还在跑的弹簧（10-29 审查）
@Suite struct TrackValue {
    @Test func linearInterpolation() {
        let t = Track.keys(.yaw, .rotationY, [(0, 0), (2, 4)], timing: .linear, repeats: true)
        #expect(abs(t.value(at: 0.5) - 1) < 1e-6)
        #expect(abs(t.value(at: 2.5) - 1) < 1e-6, "循环：过了一圈接着算")
    }

    @Test func phaseShiftsStart() {
        let t = Track.keys(.yaw, .rotationY, [(0, 0), (1, 1), (2, 0)], timing: .linear, phase: 1, repeats: true)
        #expect(abs(t.value(at: 0) - 1) < 1e-6)
    }

    /// 正弦缓动：一半时刻正好一半，四分之一时刻不到四分之一
    @Test func easing() {
        let t = Track.keys(.yaw, .rotationY, [(0, 0), (1, 1)], repeats: true)
        #expect(abs(t.value(at: 0.5) - 0.5) < 1e-4)
        #expect(t.value(at: 0.25) < 0.2)
    }

    @Test func multiSegment() {
        let t = Choreography.loop(.dizzy, size: .large, reduceMotion: false).first { $0.part == .roll }!
        #expect(abs(t.value(at: 0.6) - 6 * deg) < 1e-6 && abs(t.value(at: 1.8) + 6 * deg) < 1e-6)
    }
}
