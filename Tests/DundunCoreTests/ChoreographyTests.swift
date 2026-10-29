import Testing
@testable import DundunCore

/// 某次编排里所有 Track（循环、进场、换造型、空闲小动作、眨眼）
private func everything(reduceMotion: Bool) -> [Track] {
    let looks = Look.allCases.flatMap { l in
        Size.allCases.flatMap { s in Choreography.loop(l, size: s, reduceMotion: reduceMotion) }
            + Choreography.entrance(l, reduceMotion: reduceMotion)
    }
    let cues = IdleMotion.allCases.map(Cue.idle) + [.blink(double: false), .blink(double: true)]
    return looks + cues.flatMap { Choreography.tracks(for: $0, reduceMotion: reduceMotion) }
        + Choreography.change(reduceMotion: reduceMotion).tracks + Choreography.earPulse(reduceMotion: reduceMotion)
}

@Suite struct TrackShape {
    @Test func everyTrackIsWellFormed() {
        for t in everything(reduceMotion: false) + everything(reduceMotion: true) {
            #expect(t.duration > 0, "\(t)")
            #expect(t.delay >= 0, "\(t)")
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

    /// 动画都叠加在静止值上：一次性动作播完必须回到 0，否则结束那一刻会跳
    @Test func oneShotsEndAtRest() {
        for t in everything(reduceMotion: false) + everything(reduceMotion: true) where !t.repeats {
            #expect(t.values.last == 0 || isFullTurn(t), "\(t)")
        }
    }

    /// 往返的循环从 0 出发，回来时正好接上
    @Test func autoreversingLoopsStartAtRest() {
        for t in everything(reduceMotion: false) where t.autoreverses {
            #expect(t.values.first == 0, "\(t)")
        }
    }

    /// 不往返的循环首尾相接（整圈旋转除外），否则每圈开头会跳
    @Test func loopsAreSeamless() {
        for t in everything(reduceMotion: false) where t.repeats && !t.autoreverses {
            #expect(t.values.first == t.values.last || (t.values.first == 0 && isFullTurn(t)), "\(t)")
        }
    }

    /// docs/dundun.md §5「渲染」：循环动作 30–60fps，一次性动作不限
    @Test func loopsCapFrameRate() {
        for t in everything(reduceMotion: false) {
            #expect(t.frameRateRange == (t.repeats ? 30...60 : nil), "\(t)")
        }
    }
}

private func isFullTurn(_ t: Track) -> Bool {
    t.property == .rotation && abs(abs(t.values.last!) - 2 * .pi) < 1e-9
}

@Suite struct ReduceMotion {
    /// docs/dundun.md §5「减弱动态效果」：不位移、不缩放、不旋转；只保留眨眼（眼皮）
    @Test func noMovementExceptBlink() {
        for t in everything(reduceMotion: true) where t.property.isMovement {
            #expect(t.part == .lids, "减弱动态效果下还在动：\(t)")
        }
    }

    @Test func idleMotionsAreDropped() {
        for m in IdleMotion.allCases {
            #expect(Choreography.tracks(for: .idle(m), reduceMotion: true).isEmpty)
        }
    }

    @Test func blinkIsKept() {
        #expect(Choreography.tracks(for: .blink(double: false), reduceMotion: true)
            == Choreography.tracks(for: .blink(double: false), reduceMotion: false))
    }

    /// 颜色和眼形 0.15s 淡入淡出
    @Test func changeFadesFast() {
        let c = Choreography.change(reduceMotion: true)
        #expect(c.colorFade == 0.15)
        #expect(c.tracks.allSatisfy { $0.property == .opacity && $0.duration == 0.15 })
        #expect(c.swapAt == 0.075)
    }

    @Test func dangerRingStaysStill() {
        #expect(Choreography.earPulse(reduceMotion: true).isEmpty)
    }
}

@Suite struct Breathing {
    private func breath(_ look: Look) -> [Track] {
        Choreography.loop(look, size: .small, reduceMotion: false).filter { $0.part == .body && [.scale, .scaleX, .scaleY].contains($0.property) }
    }

    /// docs/dundun.md §5：周期 4.6s，scaleY 1→1.03、scaleX 1→0.99，正弦往返
    @Test func idle() {
        let b = breath(.idle)
        let y = b.first { $0.property == .scaleY }, x = b.first { $0.property == .scaleX }
        #expect(y?.values == [0, 0.03] && x?.values == [0, -0.01])
        for t in [y, x].compactMap({ $0 }) {
            #expect(t.duration * 2 == 4.6 && t.autoreverses && t.repeats && t.timings == [.sineInOut])
        }
    }

    /// 睡着：6s，scaleY 1.045
    @Test func sleeping() {
        let y = breath(.sleeping).first { $0.property == .scaleY }
        #expect(y?.values == [0, 0.045] && y.map { $0.duration * 2 } == 6)
    }

    /// 只有空闲和睡着呼吸，别的造型有自己的动作
    @Test func onlyIdleAndSleepingBreathe() {
        for l in Look.allCases where l != .idle && l != .sleeping {
            #expect(breath(l).isEmpty, "\(l)")
        }
    }
}

@Suite struct Blink {
    /// docs/dundun.md §5：scaleY 1→0.1→1，闭眼 60ms ease-in，睁眼 90ms ease-out
    @Test func single() {
        let t = Choreography.tracks(for: .blink(double: false), reduceMotion: false)
        #expect(t.count == 1)
        #expect(t.first?.part == .lids && t.first?.property == .scaleY)
        #expect(t.first?.values == [0, -0.9, 0])
        #expect(abs((t.first?.duration ?? 0) - 0.15) < 1e-9)
        #expect(abs((t.first?.keyTimes[1] ?? 0) - 0.4) < 1e-9)
        #expect(t.first?.timings == [.easeIn, .easeOut])
    }

    @Test func doubleBlinkIsTwoBlinksInSequence() {
        let t = Choreography.tracks(for: .blink(double: true), reduceMotion: false)
        #expect(t.count == 2 && t[0].delay == 0 && t[1].delay >= t[0].duration)
    }
}

@Suite struct DecoParts {
    /// 编排里点名的装饰部件都得真的存在
    @Test func referencedPartsExist() {
        for l in Look.allCases {
            for s in Size.allCases {
                let n = l.decoration(s).count
                for t in Choreography.loop(l, size: s, reduceMotion: false) + Choreography.entrance(l, reduceMotion: false) {
                    if case .decoPart(let i) = t.part { #expect(i < n, "\(l) \(s) \(t)") }
                }
            }
        }
    }
}

@Suite struct Retarget {
    /// 静止值已经改成 new，叠加动画从 old − new 回到 0：画面从 old 连贯地过渡到 new
    @Test func springStartsAtOldAndSettles() {
        let t = Choreography.retarget(.turn, .rotation, from: 0.1, to: 0.3, Choreography.followSpring)
        #expect(t.values == [0.1 - 0.3, 0] && t.timings == [Choreography.followSpring] && t.duration > 0)
    }

    @Test func curveTakesGivenDuration() {
        let t = Choreography.retarget(.gaze, .translationX, from: 1.5, to: 0, .sineInOut, duration: Choreography.gazeReturn)
        #expect(t.values == [1.5, 0] && t.duration == 0.8 && t.timings == [.sineInOut])
    }
}
