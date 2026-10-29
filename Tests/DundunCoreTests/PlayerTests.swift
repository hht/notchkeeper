import CoreGraphics
import Testing
@testable import DundunCore

@Suite struct MicroActions {
    /// 第 8 节：转身 6 / 880ms、上下翻 6 / 500ms、左右翻 6 / 400ms（20pt 真翻滚），20pt 和 40pt 一样；探头 2
    @Test(arguments: [DundunScale.small, .large])
    func stepCountsAndDurations(_ scale: DundunScale) {
        for (m, n, end) in [(DundunMicro.turn, 6, 0.88), (.pitch, 6, 0.5), (.roll, 6, 0.4), (.peek, 2, 1.2)] {
            var p = DundunPlayer(scale: scale, look: .idle, at: 0, seed: 11)
            _ = p.advance(to: 0)
            let okp = p.trigger(m, at: 1)
            #expect(okp)
            var sim = Sim(p, at: 1)
            sim.run(until: 1 + end + 0.05)
            let c = sim.steps(in: 1...(1 + end + 0.01))
            #expect(c.count == n, "\(m) \(scale): \(c.count)")
            #expect(abs(c.last!.time - (1 + end)) < 1e-9, "\(m) ends at \(end)")
            // 回正 = 回到当前注视帧
            #expect(c.last!.render == DundunRender(DundunFrame(look: .idle, eyes: .shape(.round, lx: 0, ly: 0), deco: .none), scale: scale))
            #expect(sim.maxWindow() <= DundunPlayer.budget)
        }
    }

    @Test func roll20ptIsTheRealRoll() {
        var p = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 11)
        _ = p.advance(to: 0)
        _ = p.trigger(.roll, at: 1)
        guard case let .flip(l, r) = p.frame(at: 1).eyes else { Issue.record("no flip"); return }
        #expect(l == .rect(CGRect(x: 7, y: 13.5, width: 2, height: 2)))
        #expect(r == .rect(CGRect(x: 13.5, y: 12.5, width: 2, height: 3)))
        guard case let .flip(l2, r2) = p.frame(at: 1.33).eyes else { Issue.record("no flip"); return }
        #expect(l2 == .rect(CGRect(x: 12.5, y: 18.5, width: 2, height: 3)))
        #expect(r2 == .rect(CGRect(x: 19, y: 18.5, width: 2, height: 2)))
    }

    @Test(arguments: [DundunScale.small, .large])
    func blinkIs110msAndTwoRedraws(_ scale: DundunScale) {
        var p = DundunPlayer(scale: scale, look: .idle, at: 0, seed: 11)
        _ = p.advance(to: 0)
        let okp = p.triggerBlink(at: 1)
        #expect(okp)
        var sim = Sim(p, at: 1)
        sim.run(until: 1.2)
        let c = sim.steps(in: 1...1.2)
        #expect(c.count == 2)
        #expect(abs(c[1].time - c[0].time - 0.11) < 1e-9)
        #expect(c[0].render.eyeKind == .blink)
    }

    @Test func buttonsDisabledWithReasons() {
        var p = DundunPlayer(scale: .small, look: .thinking, at: 0, seed: 11)
        #expect(p.microDisabledReason(at: 1) == "小动作只在空闲时播")
        #expect(p.blinkDisabledReason(at: 1) != nil)
        let okp = p.trigger(.turn, at: 1)
        #expect(!okp)
        p.setLook(.working, at: 2)
        #expect(p.blinkDisabledReason(at: 2.1) == "正在切换状态")
        #expect(p.blinkDisabledReason(at: 2.5) == nil)
        p.setLook(.question, at: 3)
        #expect(p.blinkDisabledReason(at: 3.35) == "进入动画播完才眨眼")
        #expect(p.blinkDisabledReason(at: 3.5) == nil)
        var q = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 11)
        let okq = q.trigger(.pitch, at: 1)
        #expect(okq)
        #expect(q.microDisabledReason(at: 1.1) == "正在播另一个小动作")
        #expect(q.blinkDisabledReason(at: 1.1) == "小动作期间不眨眼")
        let r = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 11, reduceMotion: true)
        #expect(r.microDisabledReason(at: 1) != nil)
        #expect(r.blinkDisabledReason(at: 1) != nil)
    }
}

@Suite struct RedrawRates {
    /// 第 8 节：空闲鼠标不动 ≈0.8 次 / s，任意 1s 窗口 ≤ 8
    @Test(arguments: [DundunScale.small, .large])
    func idleStill(_ scale: DundunScale) {
        var rates: [Double] = []
        for seed in UInt64(1)...8 {
            var sim = Sim(DundunPlayer(scale: scale, look: .idle, at: 0, seed: seed), at: 0)
            sim.run(until: 600, mouse: { _ in CGPoint(x: 400, y: 300) })
            rates.append(Double(sim.steps(in: 1...600).count) / 599)
            #expect(sim.maxWindow(from: 1) <= 8, "seed \(seed) window \(sim.maxWindow(from: 1))")
            #expect(sim.transitions(in: 0...600).isEmpty)
        }
        let avg = rates.reduce(0, +) / Double(rates.count)
        #expect(avg > 0.65 && avg < 0.95, "avg \(avg)")
    }

    /// 鼠标一直快速乱动：理论上限 12 次 / s（注视 10 + 眨眼 2）
    @Test(arguments: [DundunScale.small, .large])
    func mouseMoving(_ scale: DundunScale) {
        var rng = SplitMix64(seed: 99)
        var sim = Sim(DundunPlayer(scale: scale, look: .idle, at: 0, seed: 5), at: 0)
        sim.run(until: 120, mouse: { _ in CGPoint(x: rng.uniform(-300, 300), y: rng.uniform(-200, 200)) })
        #expect(sim.maxWindow() <= 12)
        let rate = Double(sim.steps(in: 1...120).count) / 119
        #expect(rate > 3, "mouse moving should follow, got \(rate)")
    }

    @Test func sleepingTwicePerSecond() {
        var sim = Sim(DundunPlayer(scale: .small, look: .sleeping, at: 0, seed: 5), at: 0)
        sim.run(until: 60)
        let rate = Double(sim.steps(in: 10...60).count) / 50
        #expect(abs(rate - 2) < 0.05, "\(rate)")
    }

    @Test(arguments: [(DundunLook.thinking, 2.857), (.working, 4.44), (.dizzy, 5)])
    func loopingStates(_ look: DundunLook, _ expected: Double) {
        var sim = Sim(DundunPlayer(scale: .large, look: look, at: 0, seed: 5), at: 0)
        sim.run(until: 60)
        let rate = Double(sim.steps(in: 10...60).count) / 50
        // 工作还有眨眼 ≈0.4
        #expect(rate >= expected - 0.1 && rate <= expected + 0.7, "\(look) \(rate)")
    }

    /// 一次性状态：进入 N 次，之后 0（会眨眼的只剩眨眼）
    @Test(arguments: [(DundunLook.question, 2, true), (.finished, 15, false), (.error, 2, false), (.interrupted, 3, false), (.mismatch, 5, true), (.stale, 1, false), (.danger, 4, false)])
    func oneShots(_ look: DundunLook, _ entry: Int, _ blinks: Bool) {
        var p = DundunPlayer(scale: .small, look: look, at: 0, seed: 5)
        var sim = Sim(p, at: 0)
        sim.run(until: 2)
        #expect(sim.steps(in: 0...2).count == entry, "\(look) \(sim.steps(in: 0...2).count)")
        if !blinks { #expect(sim.player.nextWake(after: 2) == nil) }
        p = sim.player
        _ = p
        if look == .finished {
            var l = Sim(DundunPlayer(scale: .large, look: .finished, at: 0, seed: 5), at: 0)
            l.run(until: 2)
            #expect(l.steps(in: 0...2).count == 21)
        }
    }

    @Test func pollingOnlyInIdle() {
        for look in DundunLook.allCases {
            let p = DundunPlayer(scale: .small, look: look, at: 0, seed: 5)
            #expect(p.wantsMouse(at: 1) == (look == .idle), "\(look)")
        }
        var p = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 5)
        p.setVisible(false, at: 1)
        #expect(!p.wantsMouse(at: 2))
        #expect(p.nextWake(after: 2) == nil)
        p.setVisible(true, at: 3)
        p.setReduceMotion(true, at: 3)
        #expect(!p.wantsMouse(at: 4))
        #expect(p.nextWake(after: 4) == nil)
        p.setReduceMotion(false, at: 5)
        p.setLook(.thinking, at: 5)
        #expect(!p.wantsMouse(at: 5.1))
        #expect(!p.wantsMouse(at: 6))
    }

    @Test(arguments: [DundunScale.small, .large])
    func everyStateRenders(_ scale: DundunScale) {
        for look in DundunLook.allCases {
            for rm in [false, true] {
                let p = DundunPlayer(scale: scale, look: look, at: 0, seed: 5, reduceMotion: rm)
                for t in stride(from: 0.0, through: 3, by: 0.05) {
                    let r = p.render(at: t)
                    #expect(r.look == look)
                    #expect(r.colors == look.colors)
                    #expect(r.left != nil && r.right != nil, "\(look) \(t)")
                }
                let hasDeco = ![.idle, .working, .interrupted, .dizzy].contains(look)
                #expect(!p.render(at: 3).decos.isEmpty == hasDeco || look == .thinking, "\(look) deco")
            }
        }
    }

    @Test func gazeQuantizes() {
        #expect(Gaze.quantize(CGPoint(x: 5, y: 0), scale: .small) == .zero)
        #expect(Gaze.quantize(CGPoint(x: -100, y: 0), scale: .small) == CGPoint(x: -1, y: 0))
        #expect(Gaze.quantize(CGPoint(x: 100, y: 100), scale: .small) == CGPoint(x: 1, y: 0.5))
        #expect(Gaze.quantize(CGPoint(x: 0, y: 100), scale: .small) == .zero)
        #expect(Gaze.quantize(CGPoint(x: 30, y: 0), scale: .large) == .zero)
        #expect(Gaze.quantize(CGPoint(x: 100, y: 10), scale: .large) == CGPoint(x: 1, y: 0))
    }
}

@Suite struct RightEar {
    @Test func mapping() {
        #expect(EarIndicator.for(.thinking, errorUnread: false) == .dots)
        #expect(EarIndicator.for(.working, errorUnread: true) == .dots)
        #expect(EarIndicator.for(.question, errorUnread: false) == .question)
        #expect(EarIndicator.for(.idle, errorUnread: true) == .error)
        #expect(EarIndicator.for(.idle, errorUnread: false) == .none)
        #expect(EarIndicator.for(.stale, errorUnread: false) == .none)
        #expect(EarIndicator.for(.danger, errorUnread: false) == .danger)
    }

    @Test func dangerPulseAfterTransition() {
        var e = DundunEarPlayer()
        e.set(.danger, at: 1)
        #expect(e.render(at: 1.1).layers.first?.ring == nil)
        #expect(abs(e.render(at: 1.1).layers[0].opacity - 0.5) < 0.01)
        #expect(e.nextRedraw(after: 1.1)! - 1.1 < 0.02)
        e.advance(to: 1.2)
        #expect(e.render(at: 1.2).layers[0].ring == EarRing(radius: 4.5, opacity: 0.5))
        // 1.2s 一圈 4 步 ≈ 3.3 次 / s
        var t = 1.2, n = 0
        while let next = e.nextRedraw(after: t), next < 13.2 { t = next; n += 1 }
        #expect(n == 40)
        e.setReduceMotion(true, at: 14)
        #expect(e.render(at: 14).layers[0].ring == EarPulse.still)
        #expect(e.nextRedraw(after: 14) == nil)
    }

    @Test func crossfadeAndColor() {
        var e = DundunEarPlayer()
        e.set(.dots, at: 0)
        e.advance(to: 1)
        e.set(.question, at: 1)
        let mid = e.render(at: 1.1)
        #expect(mid.layers.map(\.shape) == [.dots, .dot])
        e.advance(to: 1.3)
        e.set(.error, at: 2)
        let c = e.render(at: 2.1)
        #expect(c.layers.count == 1)
        #expect(c.layers[0].color != EarIndicator.error.color && c.layers[0].color != EarIndicator.question.color)
        e.advance(to: 2.3)
        #expect(e.nextRedraw(after: 2.3) == nil)
        e.set(.none, at: 3)
        #expect(e.render(at: 3.1).layers.count == 1)
        #expect(e.render(at: 3.25).layers.isEmpty)
    }
}
