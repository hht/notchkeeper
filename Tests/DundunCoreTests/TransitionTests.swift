import CoreGraphics
import Testing
@testable import DundunCore

/// 规格 3A.3 的矩阵，测试里独立再抄一份（行 = 从，列 = 到）
private let specMatrix = """
— 眨 眨 眨 眨 眨 眨 眨↓ 眨 插 插 眨
眨 — 眨 眨 眨 插 眨 眨↓ 眨 眨 眨 眨
眨 眨 — 眨 眨 眨 眨 眨↓ 眨 眨 眨 眨
眨 眨 眨 — 眨 眨 眨 眨↓ 眨 眨 眨 眨
眨 眨 眨 眨 — 眨 眨 眨↓ 眨 眨 眨 眨
眨 插 眨 眨 眨 — 眨 眨↓ 眨 眨 眨 眨
眨 眨 眨 眨 眨 眨 — 眨↓ 眨 眨 眨 眨
眨↑ 眨↑ 眨↑ 眨↑ 眨↑ 眨↑ 眨↑ — 眨↑ 眨↑ 眨↑ 插
眨 眨 眨 眨 眨 眨 眨 眨↓ — 眨 眨 眨
插 眨 眨 眨 眨 眨 眨 眨↓ 眨 — — 眨
插 眨 眨 眨 眨 眨 眨 眨↓ 眨 — — 眨
眨 眨 眨 眨 眨 眨 眨 插 眨 眨 眨 —
""".split(separator: "\n").map { $0.split(separator: " ").map(String.init) }

@Suite struct EyeTransitionMatrix {
    /// 3A.6 建议测试 4：12 × 12 每格选到的过渡类型和 3A.3 一致
    @Test func everyCellMatchesSpec() {
        let looks = DundunLook.allCases
        #expect(looks.map(\.rawValue) == ["idle", "sleeping", "thinking", "working", "question", "finished", "error", "interrupted", "dizzy", "mismatch", "stale", "danger"])
        for (i, from) in looks.enumerated() {
            for (j, to) in looks.enumerated() {
                let spec = specMatrix[i][j]
                #expect(EyeTransition.matrix(from: from, to: to).rawValue == spec, "\(from) → \(to)")
                // 规则（按眼形）选的和表一致
                #expect(EyeTransition.rule(from: from.eyes, to: to.eyes).rawValue == spec, "rule \(from) → \(to)")
                // 真正切一次状态，过渡用的也是这一格
                var p = DundunPlayer(scale: .small, look: from, at: 0, seed: 7)
                _ = p.advance(to: 0)
                p.setLook(to, at: 5)
                if from != to { #expect(p.transition?.mode.rawValue == spec, "player \(from) → \(to)") }
            }
        }
    }

    @Test func countsMatchSpec() {
        let all = EyeTransition.matrix.flatMap { $0 }
        #expect(all.count == 144)
        #expect(all.filter { $0 == .none }.count == 14)
        #expect(all.filter { $0 == .interp }.count == 8)
        #expect(all.filter { $0 == .blink }.count == 102)
        #expect(all.filter { $0 == .blinkUp }.count == 10)
        #expect(all.filter { $0 == .blinkDown }.count == 10)
    }
}

@Suite struct StateTransitions {
    /// 3A.6 建议测试 1：快速连切 5 次后，最终回到新状态的步进
    @Test(arguments: [DundunScale.small, .large])
    func fiveRapidSwitchesEndStepped(_ scale: DundunScale) {
        var sim = Sim(DundunPlayer(scale: scale, look: .idle, at: 0, seed: 3), at: 0)
        let seq: [(Double, DundunLook)] = [(1.0, .thinking), (1.07, .danger), (1.15, .interrupted), (1.2, .finished), (1.26, .working)]
        sim.run(until: 3, switches: seq)
        #expect(sim.player.transition == nil)
        #expect(sim.player.look == .working)
        let last = sim.commits.last!
        #expect(last.kind == .step)
        // 屏幕上就是 working 的步进帧，没有残留的插值
        #expect(last.render == DundunRender(sim.player.frame(at: last.time), scale: scale))
        // 过渡结束后只剩 working 的 0.225s 步进
        let after = sim.commits.filter { $0.time > 1.6 }
        #expect(after.allSatisfy { $0.kind == .step })
        let gaps = zip(after.dropFirst(), after).map { $0.time - $1.time }
        #expect(gaps.allSatisfy { abs($0 - 0.225) < 1e-6 })
    }

    /// 3A.6 建议测试 2：过渡结束后，下一次重画时刻 = 步进表里的下一个时刻（新状态 0ms 从过渡结束算）
    @Test(arguments: [(DundunLook.working, 0.225), (.thinking, 0.35), (.sleeping, 0.5), (.dizzy, 0.2), (.finished, 0.6 / 12), (.mismatch, 0.25)])
    func nextRedrawBackOnStepTable(_ look: DundunLook, _ step: Double) {
        var sim = Sim(DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3), at: 0)
        sim.run(until: 2, switches: [(2, look)])
        let end = sim.player.transition!.end
        #expect(abs(end - 2.3) < 1e-9)
        // 过渡窗口里每 1/60 s 一次
        #expect(abs(sim.player.nextWake(after: 2)! - (2 + 1.0 / 60)) < 1e-9)
        sim.run(until: end)
        #expect(sim.commits.last!.time == end)
        #expect(sim.player.transition == nil)
        let next = sim.player.nextWake(after: end)!
        #expect(abs(next - (end + step)) < 1e-9)
    }

    /// 3A.6 建议测试 3：闭眼阶段被打断时，直接从横线展开到最新眼形
    @Test(arguments: [DundunScale.small, .large])
    func interruptedWhileClosingOpensFromLine(_ scale: DundunScale) {
        var p = DundunPlayer(scale: scale, look: .idle, at: 0, seed: 3)
        _ = p.advance(to: 0)
        p.setLook(.thinking, at: 1)             // 空闲 → 思考：眨
        #expect(p.transition?.mode == .blink)
        let mid = p.render(at: 1.06)
        #expect(mid.closing)
        #expect(mid.left!.close > 0 && mid.left!.close < 1)
        p.setLook(.working, at: 1.06)           // 闭眼中途改成工作
        #expect(p.transition?.mode == .blinkUp)
        // 0–0.12s 保持横线（旧眼形压到底），之后展开成 focus
        let held = p.render(at: 1.1)
        #expect(held.left!.close == 1)
        #expect(held.left!.geom == mid.left!.geom)
        let opening = p.render(at: 1.06 + 0.2)
        #expect(opening.left!.geom == .art(.focus, right: false))
        #expect(opening.left!.close > 0 && opening.left!.close < 1)
        let done = p.render(at: 1.36)
        #expect(done.left!.geom == .art(.focus, right: false))
        #expect(done.left!.close == 0)
    }

    @Test func blinkDownStopsAfterSquash() {
        var p = DundunPlayer(scale: .small, look: .working, at: 0, seed: 3)
        _ = p.advance(to: 0)
        p.setLook(.interrupted, at: 1)
        #expect(p.transition?.mode == .blinkDown)
        let a = p.render(at: 1.13), b = p.render(at: 1.29)
        #expect(a.left == b.left)
        #expect(a.left!.geom == EyeGeom.of(.blink, .small, right: false))
    }

    @Test func blinkUpSkipsSquash() {
        var p = DundunPlayer(scale: .small, look: .interrupted, at: 0, seed: 3)
        _ = p.advance(to: 0)
        p.setLook(.thinking, at: 1)
        #expect(p.transition?.mode == .blinkUp)
        #expect(p.render(at: 1.01).left!.geom == EyeGeom.of(.blink, .small, right: false))
        #expect(p.render(at: 1.11).left!.geom == EyeGeom.of(.blink, .small, right: false))
        #expect(p.render(at: 1.2).left!.geom == .art(.think, right: false))
    }

    @Test func interpolatesWithinFamilyOnHalfPointGrid() {
        var p = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3)
        _ = p.advance(to: 0)
        p.setLook(.mismatch, at: 1)
        #expect(p.transition?.mode == .interp)
        for k in 0...18 {
            guard case let .pill(r) = p.render(at: 1 + Double(k) / 60).left!.geom else { Issue.record("not a pill"); return }
            for v in [r.minX, r.minY, r.width, r.height] { #expect((v * 2).rounded() == v * 2) }
        }
        // danger ↔ interrupted：4 顶点逐点插
        var q = DundunPlayer(scale: .large, look: .interrupted, at: 0, seed: 3)
        _ = q.advance(to: 0)
        q.setLook(.danger, at: 1)
        #expect(q.transition?.mode == .interp)
        #expect(q.transition?.duration == 0.2)
        guard case .quad = q.render(at: 1.1).left!.geom else { Issue.record("not a quad"); return }
    }

    @Test func dangerEntryIsShorterAndEasesOut() {
        var p = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3)
        _ = p.advance(to: 0)
        p.setLook(.danger, at: 1)
        #expect(p.transition?.duration == 0.2)
        #expect(p.transition?.curve == .easeOut)
        p.setLook(.idle, at: 2)
        #expect(p.transition?.duration == 0.3)
    }

    @Test func colorsInterpolateInOKLab() {
        var p = DundunPlayer(scale: .small, look: .working, at: 0, seed: 3)
        _ = p.advance(to: 0)
        p.setLook(.danger, at: 1)
        let mid = p.render(at: 1.1).colors.bottom
        let a = DundunLook.working.colors.bottom, b = DundunLook.danger.colors.bottom
        let srgbMid = RGB(r: (a.r + b.r) / 2, g: (a.g + b.g) / 2, b: (a.b + b.b) / 2)
        #expect(mid != srgbMid)
        #expect(p.render(at: 1.2).colors == DundunLook.danger.colors)
        #expect(p.render(at: 1.0).colors == DundunLook.working.colors)
    }

    @Test func decorationsFadeOutThenScaleIn() {
        var p = DundunPlayer(scale: .small, look: .thinking, at: 0, seed: 3)
        _ = p.advance(to: 0)
        p.setLook(.question, at: 1)
        let early = p.render(at: 1.05).decos
        #expect(early.map(\.deco.id) == ["thinking"])
        #expect(abs(early[0].opacity - 0.5) < 1e-9)
        #expect(p.render(at: 1.1).decos.isEmpty)
        let late = p.render(at: 1.2).decos
        #expect(late.map(\.deco.id) == ["question"])
        #expect(late[0].scale > 0.8 && late[0].scale < 1)
        // 两边都没有装饰：不动
        var q = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3)
        _ = q.advance(to: 0)
        q.setLook(.working, at: 1)
        #expect(q.render(at: 1.15).decos.isEmpty)
    }

    @Test func singleSwitchFrameCounts() {
        var sim = Sim(DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3), at: 0)
        sim.run(until: 2, switches: [(1, .stale)])
        let n = sim.transitions(in: 1...1.31).count
        #expect((17...20).contains(n), "idle → stale \(n)")
        var d = Sim(DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3), at: 0)
        d.run(until: 2, switches: [(1, .danger)])
        let m = d.transitions(in: 1...1.21).count
        #expect((11...14).contains(m), "idle → danger \(m)")
    }

    /// 3A.5 最坏情况：1s 内来回切 3 次。每次都在上一段过渡没走完时打断、从当前插值重新开始，
    /// 所以一直连续重画；规格估计「这 1 秒（加最后一段 0.3s）≈ 60–78 帧」，即 60fps × 1.0–1.3s。
    /// 3 次切换挤在 0 / ⅓ / ⅔ s：重画窗口 0.97s → 57 帧；再往回切一次（第 1s 末）窗口 1.3s → 76 帧（每次打断丢掉半帧）。
    /// 步进的每秒 12 次上限不受影响，过渡结束后回到步进
    @Test(arguments: [DundunScale.small, .large])
    func threeSwitchesPerSecond(_ scale: DundunScale) {
        let third = 1.0 / 3
        let three: [(Double, DundunLook)] = [(1, .working), (1 + third, .idle), (1 + 2 * third, .working)]
        for (seq, range) in [(three, 56...58), (three + [(2, .idle)], 74...79)] {
            var sim = Sim(DundunPlayer(scale: scale, look: .idle, at: 0, seed: 3), at: 0)
            sim.run(until: 4, switches: seq)
            let frames = sim.transitions(in: 1...2.4)
            #expect(range.contains(frames.count), "\(seq.count) switches: \(frames.count) transition frames")
            #expect(frames.count <= 78 + 1)
            // 过渡帧最高 60fps：任意两帧间隔不小于 1/60 s
            let gaps = zip(frames.dropFirst(), frames).map { $0.time - $1.time }
            #expect(gaps.allSatisfy { $0 > 1.0 / 60 - 1e-6 })
            #expect(sim.maxWindow() <= DundunPlayer.budget)
            #expect(sim.player.transition == nil)
            #expect(sim.commits.filter { $0.time > 2.4 }.allSatisfy { $0.kind == .step })
        }
    }

    @Test func reduceMotionKeepsOnlyColor() {
        var p = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3, reduceMotion: true)
        _ = p.advance(to: 0)
        p.setLook(.thinking, at: 1)
        #expect(p.transition?.duration == 0.15)
        let mid = p.render(at: 1.07)
        #expect(mid.left!.geom == .art(.think, right: false))
        #expect(mid.colors != DundunLook.thinking.colors)
        #expect(mid.decos.map(\.opacity) == [1])
    }

    @Test func invisibleSwitchSkipsTransition() {
        var p = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3)
        _ = p.advance(to: 0)
        p.setVisible(false, at: 0.5)
        p.setLook(.finished, at: 1)
        #expect(p.transition == nil)
        #expect(p.nextWake(after: 1) == nil)
        p.setVisible(true, at: 10)
        // 恢复时直接画停留帧，不重播
        let c = p.advance(to: 10)!
        #expect(c.render.decos.first?.deco == .finished(big: 1, small: 0.6, bigRadius: 2.5))
        #expect(p.nextWake(after: 10) == nil)
    }

    @Test func transitionAbortsMicroAndResetsBlink() {
        var p = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3)
        _ = p.advance(to: 0)
        let okp = p.trigger(.turn, at: 1)
        #expect(okp)
        _ = p.advance(to: 1.2)
        p.setLook(.working, at: 1.25)
        #expect(p.microDisabledReason(at: 1.3) != nil)
        // 小动作的逐帧眼没有几何可插，走过渡眨眼
        #expect(p.transition?.mode == .blink)
        var sim = Sim(p, at: 1.25)
        sim.run(until: 1.6)
        guard case .shape(.focus, _, _) = sim.player.frame(at: 1.6).eyes else { Issue.record("not focus"); return }
    }
}
