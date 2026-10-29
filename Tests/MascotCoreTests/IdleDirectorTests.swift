import Testing
@testable import MascotCore

/// 从 start 起一直取到 end，记下每个提示和它的时刻
private func run(seed: UInt64, from start: Double = 0, to end: Double) -> [(at: Double, cue: Cue)] {
    var d = IdleDirector(seed: seed, now: start)
    var out: [(Double, Cue)] = []
    while d.nextWake <= end {
        let t = d.nextWake
        out += d.cues(at: t).map { (t, $0) }
    }
    return out
}

private func motions(_ log: [(at: Double, cue: Cue)]) -> [(at: Double, motion: Motion)] {
    log.compactMap { e in if case .idle(let m) = e.cue { return (e.at, m) } else { return nil } }
}

private func blinks(_ log: [(at: Double, cue: Cue)]) -> [(at: Double, double: Bool)] {
    log.compactMap { e in if case .blink(let d) = e.cue { return (e.at, d) } else { return nil } }
}

@Suite struct IdleDirectorTests {
    @Test func sameSeedSameSequence() {
        let a = run(seed: 42, to: 600), b = run(seed: 42, to: 600)
        #expect(a.map(\.at) == b.map(\.at) && a.map(\.cue) == b.map(\.cue))
        #expect(run(seed: 43, to: 600).map(\.at) != a.map(\.at))
    }

    /// docs/mascot.md §5：小动作每 8–20s 一个，不连续重复
    @Test func idleMotionsSpacedAndNeverRepeat() {
        for seed in UInt64(1)...20 {
            let m = motions(run(seed: seed, to: 3600))
            #expect(m.count > 150)
            for (a, b) in zip(m, m.dropFirst()) {
                #expect(a.motion != b.motion)
                #expect(b.at - a.at >= 8 - 1e-9 && b.at - a.at <= 20 + 1e-9)
            }
        }
    }

    /// 眨眼间隔 2.5–6s，约 15% 连眨两次
    @Test func blinkSpacingAndDoubleRate() {
        let b = (UInt64(1)...20).flatMap { blinks(run(seed: $0, to: 3600)) }
        for seed in UInt64(1)...5 {
            let one = blinks(run(seed: seed, to: 600))
            for (x, y) in zip(one, one.dropFirst()) { #expect(y.at - x.at >= 2.5 - 1e-9 && y.at - x.at <= 6 + 1e-9) }
        }
        let rate = Double(b.filter(\.double).count) / Double(b.count)
        #expect(abs(rate - 0.15) < 0.02, "连眨比例 \(rate)")
    }

    /// docs/mascot.md §5：左右转圈、上下翻圈各约 5%，其余等概率；完成跳转不是空闲小动作
    @Test func spinsAreRare() {
        let m = (UInt64(1)...20).flatMap { motions(run(seed: $0, to: 3600)) }
        for rare in [Motion.spinAround, .flip] {
            let rate = Double(m.filter { $0.motion == rare }.count) / Double(m.count)
            #expect(rate > 0.02 && rate < 0.08, "\(rare) 比例 \(rate)")
        }
        let nod = Double(m.filter { $0.motion == .nod }.count) / Double(m.count)
        #expect(abs(nod - 0.1125) < 0.03, "点头比例 \(nod)")
        #expect(Set(m.map(\.motion)) == Set(Motion.allCases).subtracting([.finishJump]))
    }

    /// 鼠标在动时不做小动作；停下以后至少再等一个完整间隔
    @Test func postponeWhileMouseMoves() {
        var d = IdleDirector(seed: 7, now: 0)
        d.postponeMotions(until: 100)
        var first: Double?
        while first == nil {
            let t = d.nextWake
            if d.cues(at: t).contains(where: { if case .idle = $0 { return true } else { return false } }) { first = t }
        }
        #expect(first! >= 108)
    }

    /// 看不见一段时间后回来：不补发攒下的提示，从现在重新排
    @Test func resumeReschedulesFromNow() {
        var d = IdleDirector(seed: 7, now: 0)
        d.resume(at: 1000)
        #expect(d.nextWake >= 1000 + 2.5)
        #expect(d.cues(at: 1000).isEmpty)
    }
}
