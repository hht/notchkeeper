// Ported from Coucou (https://github.com/louis-cfm/coucou @ 47d1c2d).
//
// MIT License
//
// Copyright (c) 2026 Louis Raillé
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Modified for Notchkeeper. Character used for personal, private use only — see AGENTS.md:49.

import QuartzCore
import SwiftUI

private func K(_ target: CGFloat, _ duration: CGFloat, _ ease: @escaping (CGFloat) -> CGFloat) -> TweenKey {
    TweenKey(target: target, duration: duration, ease: ease)
}

// MARK: - Engine

@MainActor
final class DundunEngine: ObservableObject {
    /// 开了「减弱动态效果」：不弹跳、不打滚、不抖动、不出粒子、不跟随鼠标；颜色、眼型、盾牌、角标和眨眼保留。
    var reduceMotion = false
    /// 身体太小（< 30pt）时不画盾牌，由视图按尺寸设置。
    var showsShield = true
    /// 1.7 秒内被拍 3 下。由视图决定晕多久。
    var onDizzy: (() -> Void)?

    // Animation state (mirrors prototype 's' object)
    var yaw:    CGFloat = 0
    var pitch:  CGFloat = 0
    var roll:   CGFloat = 0
    var tilt:   CGFloat = 0
    var open:   CGFloat = 1          // eye open amount
    var sx:     CGFloat = 1          // scale X
    var sy:     CGFloat = 1          // scale Y
    var oy:     CGFloat = 0          // offset Y (bounce)
    var ox:     CGFloat = 0          // offset X (shake)
    var tint:   CGFloat = 0
    var blush:  CGFloat = 0
    var es:     CGFloat = 1          // eye scale
    var badgeS: CGFloat = 0          // badge scale
    var shieldS: CGFloat = 0         // shield scale
    var shield: ShieldKind? = nil

    // Targets
    var tgYaw:    CGFloat = 0
    var tgPitch:  CGFloat = 0
    var tgTilt:   CGFloat = 0
    var tgSy:     CGFloat = 1
    var tgSx:     CGFloat = 1
    var tgEs:     CGFloat = 1   // eye-scale target (hover: 1.08, normal: 1)

    // Color (animated)
    var col:  (CGFloat, CGFloat, CGFloat) = cgColorToTuple(DundunConst.baseTop)
    var colT: (CGFloat, CGFloat, CGFloat) = cgColorToTuple(DundunConst.baseTop)

    // State
    var state: DundunState = .idle
    var cfg: DundunStateCfg = DundunStates[.idle]!

    /// 减弱动态效果时换状态改成 0.2 秒淡入淡出：旧颜色、旧色调、旧眼型和开始时间（mascot-port-batch1.md 第 8 节）。
    var fade: (col: (CGFloat, CGFloat, CGFloat), tint: CGFloat, eye: EyeShape, start: Double)? = nil
    private static let fadeDuration = 0.2

    // Eye override (emote)
    var eyeOverride: EyeShape? = nil
    var eyeOverrideUntil: Double = 0   // CACurrentMediaTime()
    var permanentEye: EyeShape? = nil  // restored after temporary emote/blink expires

    // Badge animation
    var badge: BadgeType? = nil
    var badgeKey: String = "none"
    var badgeToken: Int = 0

    // Tweens (keyed by property name)
    var tweens: [String: Tween] = [:]
    var locks:  Set<String> = []

    // Particles
    var particles: [Particle] = []

    // Look target
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0

    // Timing
    var t0: Double = CACurrentMediaTime() - Double.random(in: 0...5)
    var nextBlink: Double = CACurrentMediaTime() + 1.5 + Double.random(in: 0...2)
    var lastAmbient: Double = 0

    // Slap tracking (for dizzy on 3 slaps)
    var slapTimes: [Double] = []

    // How the Mac feels (DundunMood.swift): the target is set every frame, the levels ease towards it.
    var moodTarget = DundunMood.calm
    var moodBusy: CGFloat = 0
    var moodHot: CGFloat = 0
    var moodFull: CGFloat = 0
    var moodTired: CGFloat = 0
    var nextMoodDrop: Double = 0
    var moodDrops: [MoodDrop] = []
    var hop = MoodHop()
    var moodShiftApplied: CGFloat = 0
    // Stressed eyes: where they dart, when next, their tremble, the next nervous blink.
    var stressLook = CGPoint.zero
    var nextStressLook: Double = 0
    var stressTremble = CGPoint.zero
    var nextNervousBlink: Double = 0
    var moodLiftApplied: CGFloat = 0
    var nextMoodYawn: Double = 0

    // MARK: - Public API

    func setState(_ newState: DundunState, force: Bool = false) {
        guard state != newState || force else { return }
        let prev = state
        fade = reduceMotion && !force ? (col, tint, eyeOverride ?? cfg.eye, CACurrentMediaTime()) : nil
        state = newState
        cfg = DundunStates[newState]!
        colT = cgColorToTuple(cfg.color)
        setTarget(key: "tint", value: cfg.tint)
        setTarget(key: "tilt", value: cfg.tilt)
        setBadge(cfg.badge)
        setShield(Self.shieldKind(newState))

        switch newState {
        case .finished:
            doRoll(duration: 950, turns: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.emit(.spark, count: 5)
            }
        case .error, .guardViolated:
            anim("ox", [K(0.08, 50, Ease.out), K(-0.08, 70, Ease.inOut), K(0.05, 70, Ease.inOut), K(0, 90, Ease.out)])
        case .approval, .guardMismatch:
            anim("oy", [K(-0.2, 150, Ease.out), K(0, 300, Ease.back)])
        case .dizzy:
            doRoll(duration: 1300, turns: 2)
        case .question:
            blink()
        case .ratelimit:
            emit(.sweat, count: 1)
        default:
            if prev != .idle || newState != .idle { blink() }
        }
        // 化险为夷才开心一下（Emily 规格第 4 节，2026-10-28 改为不含 unknown）。
        if DundunState.celebrates(from: prev, to: newState) && !force { triggerEmote(.happy, duration: 1.8) }
    }

    private static func shieldKind(_ s: DundunState) -> ShieldKind? {
        switch s {
        case .guardUnknown:  return .hollow
        case .guardMismatch: return .solid
        case .guardViolated: return .cracked
        default:             return nil
        }
    }

    private func setShield(_ kind: ShieldKind?) {
        guard kind != shield || (kind != nil && shieldS < 0.01) else { return }
        if let kind {
            shield = kind
            shieldS = 0
            anim("shieldS", [K(1, 320, Ease.back)])
        } else {
            anim("shieldS", [K(0, 120, Ease.inOut)]) { [weak self] in
                self?.shield = nil
            }
        }
    }

    func setBadge(_ b: BadgeType?) {
        let key = badgeString(b)
        guard key != badgeKey else { return }
        badgeKey = key
        let tok = badgeToken + 1
        badgeToken = tok
        anim("badgeS", [K(0, 90, Ease.inOut)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, tok == self.badgeToken else { return }
            self.badge = b
            if b != nil {
                self.anim("badgeS", [K(1, 280, Ease.back)])
            }
        }
    }

    func blink() {
        guard !locks.contains("open") else { return }
        anim("open", [K(0.06, 70, Ease.inOut), K(1, 130, Ease.out)])
    }

    func squash() {
        anim("sy", [K(0.78, 70, Ease.out), K(1.1, 130, Ease.out), K(1, 170, Ease.inOut)])
        anim("sx", [K(1.16, 70, Ease.out), K(0.95, 130, Ease.out), K(1, 170, Ease.inOut)])
    }

    // MARK: - Slap (dizzy mechanic)

    func slap() {
        guard state != .dizzy else { return }
        let now = CACurrentMediaTime()
        slapTimes = slapTimes.filter { now - $0 < 1.7 }
        slapTimes.append(now)
        squash()
        if slapTimes.count >= 3 {
            slapTimes = []
            onDizzy?()
        } else {
            // Annoyed: line eyes for 800ms
            eyeOverride = .line
            eyeOverrideUntil = now + 0.8
        }
    }

    func doRoll(duration: CGFloat, turns: CGFloat) {
        roll = 0
        anim("roll", [K(.pi * 2 * turns, duration, Ease.inOut)]) { [weak self] in
            self?.roll = 0
            self?.squash()
        }
    }

    /// Sets a permanent eye expression that survives blinks and transient emotes.
    func setPermanentEmote(_ emote: DundunEmote?) {
        permanentEye = emote.map { emoteEyeShape($0) }
        if let eye = permanentEye {
            eyeOverride = eye
            eyeOverrideUntil = .greatestFiniteMagnitude
        } else if eyeOverrideUntil == .greatestFiniteMagnitude {
            eyeOverride = nil
            eyeOverrideUntil = 0
        }
    }

    func triggerEmote(_ emote: DundunEmote, duration: Double = 1.8) {
        let now = CACurrentMediaTime()
        eyeOverride = emoteEyeShape(emote)
        eyeOverrideUntil = now + duration

        switch emote {
        case .love:
            anim("blush", [K(1, 300, Ease.out), K(1, CGFloat((duration - 0.6) * 1000), Ease.lin), K(0, 300, Ease.inOut)])
            emit(.heart, count: 4)
            anim("oy", [K(-0.1, 160, Ease.out), K(0, 300, Ease.back)])
        case .surprised:
            anim("oy", [K(-0.3, 140, Ease.out), K(0, 380, Ease.back)])
            anim("es", [K(1.25, 120, Ease.out), K(1, 500, Ease.inOut)])
        case .proud:
            squash()
            emit(.star, count: 5)
            anim("tilt", [K(-0.14, 220, Ease.out), K(-0.14, CGFloat((duration - 0.5) * 1000), Ease.lin), K(0, 280, Ease.inOut)])
            anim("blush", [K(0.7, 250, Ease.out), K(0.7, CGFloat((duration - 0.5) * 1000), Ease.lin), K(0, 300, Ease.inOut)])
        case .wink:
            anim("tilt", [K(0.12, 160, Ease.out), K(0.12, CGFloat((duration - 0.4) * 1000), Ease.lin), K(0, 240, Ease.inOut)])
        case .yawn:
            anim("sy", [K(1.12, 500, Ease.inOut), K(1, 500, Ease.inOut)])
            anim("sx", [K(0.94, 500, Ease.inOut), K(1, 500, Ease.inOut)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.eyeOverride = .closed
                self?.emit(.z, count: 2)
            }
        case .happy:
            anim("blush", [K(0.6, 200, Ease.out), K(0, 600, Ease.inOut)])
        case .annoyed:
            eyeOverride = .line
            eyeOverrideUntil = now + 0.8
        }
    }

    func emit(_ type: Particle.ParticleType, count: Int) {
        guard !reduceMotion else { return }
        for i in 0..<count {
            let isZ = type == .z
            particles.append(Particle(
                type: type,
                x: (CGFloat.random(in: -0.5...0.5)) * 0.9 + (isZ ? 0.55 : 0),
                y: -0.7 - CGFloat.random(in: 0...0.2),
                vx: CGFloat.random(in: -0.5...0.5) * 0.35 + (isZ ? 0.18 : 0),
                vy: -(0.45 + CGFloat.random(in: 0...0.35)),
                age: -Double(i) * 0.14,
                life: 1.3 + Double.random(in: 0...0.5),
                rot: CGFloat.random(in: 0...(.pi * 2)),
                size: 0.15 + CGFloat.random(in: 0...0.08)
            ))
        }
    }

    // MARK: - Update (called every frame from TimelineView)

    func update(dt: Double) {
        let now = CACurrentMediaTime()
        // The stressed hop of the last frame comes off first (DundunMood.swift).
        undoMoodOffsets()

        // Process tweens
        for key in tweens.keys {
            guard var tw = tweens[key] else { continue }
            let k = tw.keys[tw.keyIndex]
            let elapsed = now * 1000 - tw.startTime
            let p = min(1, max(0, CGFloat(elapsed) / k.duration))
            setProperty(key, value: tw.from + (k.target - tw.from) * k.ease(p))

            if p >= 1 {
                tw.from = k.target
                tw.keyIndex += 1
                tw.startTime = now * 1000
                if tw.keyIndex >= tw.keys.count {
                    tweens.removeValue(forKey: key)
                    locks.remove(key)
                    tw.onComplete?()
                } else {
                    tweens[key] = tw
                }
            } else {
                tweens[key] = tw
            }
        }

        // Compute look targets
        let t = CGFloat(now - t0)
        var ty: CGFloat = lookX * 0.62
        var tp: CGFloat = lookY * 0.5

        if let fixedLook = cfg.look {
            ty = ty * 0.35 + fixedLook.x * 0.55
            tp = tp * 0.3  + fixedLook.y * 0.5
        }
        if cfg.scans {
            ty = sin(t * 2.6) * 0.6
            tp = -0.06
        }
        if state == .sleeping { ty = 0; tp = -0.14 }
        if state == .dizzy    { ty = sin(t * 9) * 0.25 }

        // 减弱动态效果：眼睛不转，只留眨眼
        tgYaw   = reduceMotion ? 0 : ty
        tgPitch = reduceMotion ? 0 : tp
        tgTilt  = cfg.tilt

        let bounce = cfg.bounces && !reduceMotion ? -abs(sin(t * 5.2)) * 0.07 : CGFloat(0)
        // oy tween can override if not locked
        if !locks.contains("oy") { oy += (bounce - oy) * CGFloat(1 - pow(0.0008, dt)) }

        if cfg.breathes && !reduceMotion {
            tgSy = 1 + sin(t * 1.8) * 0.035
            tgSx = 1 - sin(t * 1.8) * 0.035 * 0.57
        } else {
            tgSy = 1; tgSx = 1
        }

        // The Mac's mood (sweat, puffed up, tired) adjusts the targets above.
        updateMood(dt: dt, now: now, t: t)

        // Smooth look
        let kLook = CGFloat(1 - pow(0.0025, dt))
        let kGen  = CGFloat(1 - pow(0.0008, dt))

        if !locks.contains("yaw")   { yaw   += (tgYaw   - yaw)   * kLook }
        if !locks.contains("pitch") { pitch += (tgPitch  - pitch) * kLook }
        if !locks.contains("tilt")  { tilt  += (tgTilt   - tilt)  * kGen  }
        if !locks.contains("sy")    { sy    += (tgSy     - sy)    * kGen  }
        if !locks.contains("sx")    { sx    += (tgSx     - sx)    * kGen  }
        if !locks.contains("es")    { es    += (tgEs     - es)    * kGen  }

        // Animate color
        if let f = fade {
            let k = fadeProgress(f.start, now: now)
            col = mixColor(f.col, colT, k)
            if !locks.contains("tint") { tint = f.tint + (cfg.tint - f.tint) * k }
            if k >= 1 { fade = nil }
        } else {
            col = mixColor(col, colT, 1 - pow(0.002, dt))
        }

        // Blink
        if now > nextBlink {
            if state != .sleeping && state != .dizzy {
                blink()
                if Double.random(in: 0...1) < 0.22 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) { [weak self] in self?.blink() }
                }
            }
            nextBlink = now + 2.2 + Double.random(in: 0...3.2)
        }

        // Clear expired eye override (restore permanent if set)
        if eyeOverride != nil && now > eyeOverrideUntil {
            eyeOverride = permanentEye
            if permanentEye != nil { eyeOverrideUntil = .greatestFiniteMagnitude }
        }

        // Ambient particles
        if now - lastAmbient > 1.3 {
            lastAmbient = now
            if cfg.zz { emit(.z, count: 1) }
            if cfg.sweat && Double.random(in: 0...1) < 0.5 { emit(.sweat, count: 1) }
        }

        // Age particles
        for i in particles.indices { particles[i].age += dt }
        particles.removeAll { $0.age >= $0.life }
    }

    // MARK: - Draw

    /// 身体中心（世界坐标）。身体放在画布底部那块正方形里，多出来的高度是头顶留给 z、汗滴的空间。
    private func center(_ size: CGSize, R: CGFloat) -> CGPoint {
        CGPoint(x: size.width / 2 + ox * R, y: size.height - size.width / 2 + oy * R + R * 0.06)
    }

    func draw(context: GraphicsContext, size: CGSize) {
        let R = size.width * 0.3
        let rx = R * 1.14
        let ry = R * 0.88
        let c = center(size, R: R)

        var ctx = context
        ctx.translateBy(x: c.x, y: c.y)
        if tilt != 0 { ctx.rotate(by: .radians(tilt)) }
        ctx.scaleBy(x: sx, y: sy)

        let bodyPath = superellipse(rx: rx, ry: ry)
        drawBody(ctx: &ctx, path: bodyPath, R: R, rx: rx, ry: ry)

        // A warm Mac flushes him (DundunMood.swift).
        drawMoodTint(ctx: &ctx, path: bodyPath, rx: rx, ry: ry)

        // Blush — always shows a floor proportional to tint (prototype behaviour)
        let blushVal = max(blush, tint * 0.5, moodHot * 0.85)
        if blushVal > 0.01 {
            drawBlush(ctx: ctx, path: bodyPath, rx: rx, ry: ry, R: R, blush: blushVal)
        }

        drawEyes(ctx: ctx, path: bodyPath, R: R)

        if let shield, showsShield, shieldS > 0.01 {
            drawShield(ctx: ctx, kind: shield, R: R, ry: ry)
        }
    }

    func drawExtras(context: GraphicsContext, size: CGSize) {
        let R = size.width * 0.3
        let rx = R * 1.14
        let ry = R * 0.88
        let c = center(size, R: R)

        if let badge, badgeS > 0.01 {
            drawBadge(context: context, badge: badge, R: R, cx: c.x, cy: c.y)
        }
        // Sweat and heat waves (DundunMood.swift)
        drawMoodExtras(context: context, R: R, rx: rx, ry: ry, cx: c.x, cy: c.y)
        drawParticles(context: context, R: R, cx: c.x, cy: c.y)
    }

    // MARK: - Private draw helpers

    private func superellipse(rx: CGFloat, ry: CGFloat) -> Path {
        let n = 72
        let expN: CGFloat = 2.0 / 2.7
        var path = Path()
        for i in 0...n {
            let a = CGFloat(i) / CGFloat(n) * .pi * 2
            let ca = cos(a), sa = sin(a)
            let p = CGPoint(x: rx * (ca >= 0 ? pow(ca, expN) : -pow(-ca, expN)),
                            y: ry * (sa >= 0 ? pow(sa, expN) : -pow(-sa, expN)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    private func drawBody(ctx: inout GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        ctx.fill(path, with: .linearGradient(
            Gradient(colors: [Color(cgColor: DundunConst.baseTop), Color(cgColor: DundunConst.baseBottom)]),
            startPoint: CGPoint(x: rx*0.7, y: -ry*0.85),
            endPoint: CGPoint(x: -rx*0.8, y: ry*0.9)
        ))
        // State tint
        if tint > 0.01 {
            let tc = colorFromTuple(col)
            ctx.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: tc.opacity(Double(0.72 * tint)), location: 0),
                    .init(color: tc.opacity(0), location: 1)
                ]),
                startPoint: CGPoint(x: 0, y: ry),
                endPoint: CGPoint(x: 0, y: -ry)
            ))
        }
        // Shadow rim
        ctx.fill(path, with: .radialGradient(
            Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.6),
                .init(color: Color.black.opacity(0.2), location: 1)
            ]),
            center: .zero, startRadius: R*0.15, endRadius: R*1.25
        ))
        // Highlight
        ctx.fill(path, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color.white.opacity(0.55), location: 0),
                .init(color: .clear, location: 1)
            ]),
            center: CGPoint(x: rx*0.34, y: -ry*0.46),
            startRadius: 0,
            endRadius: R*0.42
        ))
    }

    private func drawBlush(ctx: GraphicsContext, path: Path, rx: CGFloat, ry: CGFloat, R: CGFloat, blush: CGFloat) {
        var ctx = ctx
        ctx.clip(to: path)
        let yOffset = sin(yaw) * rx * 0.8
        for sd in [-1.0, 1.0] {
            let bx = CGFloat(sd) * rx * 0.55 + yOffset
            let by = ry * 0.2
            let ellipse = Path(ellipseIn: CGRect(x: bx - R*0.17, y: by - R*0.1, width: R*0.34, height: R*0.2))
            ctx.fill(ellipse, with: .color(Color(red: 1, green: 0.471, blue: 0.588, opacity: Double(0.5 * blush))))
        }
    }

    private func fadeProgress(_ start: Double, now: Double) -> CGFloat {
        CGFloat(min(1, (now - start) / Self.fadeDuration))
    }

    private func drawEyes(ctx: GraphicsContext, path: Path, R: CGFloat) {
        let shape = eyeOverride ?? cfg.eye
        if let f = fade, f.eye != shape {
            let k = fadeProgress(f.start, now: CACurrentMediaTime())
            drawEyes(shape: f.eye, opacity: 1 - k, ctx: ctx, path: path, R: R)
            drawEyes(shape: shape, opacity: k, ctx: ctx, path: path, R: R)
        } else {
            drawEyes(shape: shape, opacity: 1, ctx: ctx, path: path, R: R)
        }
    }

    private func drawEyes(shape: EyeShape, opacity: CGFloat, ctx: GraphicsContext, path: Path, R: CGFloat) {
        var ctx = ctx
        ctx.opacity = Double(opacity)
        ctx.clip(to: path)
        for f in eyeFrames(R: R, yaw: yaw, pitch: pitch) {
            // Re-derive pitch with roll for the roll-through effect
            var eyePitch = DundunConst.eyeP + pitch + roll
            eyePitch = ((eyePitch + .pi).truncatingRemainder(dividingBy: .pi*2) + .pi*2).truncatingRemainder(dividingBy: .pi*2) - .pi
            let eyeYaw = f.sd * DundunConst.eyeSp + yaw
            guard cos(eyeYaw) * cos(eyePitch) > 0.04 else { continue }

            // Stressed (DundunMood.swift): a little smaller, like pupils tightening with fear, and trembling.
            let fear = min(1, moodBusy * 1.3)
            let ew = R * DundunConst.eyeW * es * (1 - 0.2 * fear)
            let eh = R * DundunConst.eyeH * es * (1 - 0.1 * fear)

            var eyeCtx = ctx
            eyeCtx.translateBy(x: f.x + stressTremble.x * R, y: f.y + stressTremble.y * R)
            eyeCtx.scaleBy(x: f.fx, y: f.fy)
            drawEyeShape(ctx: &eyeCtx, shape: shape, w: ew, h: eh, open: open, sd: f.sd)
        }
    }

    private func drawEyeShape(ctx: inout GraphicsContext, shape: EyeShape, w: CGFloat, h: CGFloat, open: CGFloat, sd: CGFloat) {
        let ink = Color(cgColor: DundunConst.ink)
        let now = CGFloat(CACurrentMediaTime())

        switch shape {
        case .wide:
            drawEyeShape(ctx: &ctx, shape: .pill, w: w*1.16, h: h*1.12, open: open, sd: sd)

        case .pill:
            let hh = max(h * open, w * 0.3)
            var p = Path()
            p.addRoundedRect(in: CGRect(x: -w/2, y: -hh/2, width: w, height: hh),
                             cornerSize: CGSize(width: min(w/2, hh/2), height: min(w/2, hh/2)))
            ctx.fill(p, with: .color(ink))

        case .dot:
            ctx.fill(Path(ellipseIn: CGRect(x: -w*0.45, y: -w*0.45, width: w*0.9, height: w*0.9)), with: .color(ink))

        case .line:
            ctx.rotate(by: .radians(-sd * 0.2))
            var p = Path()
            p.addRoundedRect(in: CGRect(x: -w*0.78, y: -w*0.21, width: w*1.56, height: w*0.42),
                             cornerSize: CGSize(width: w*0.21, height: w*0.21))
            ctx.fill(p, with: .color(ink))

        case .flat:
            var p = Path()
            p.addRoundedRect(in: CGRect(x: -w*0.72, y: -w*0.2, width: w*1.44, height: w*0.4),
                             cornerSize: CGSize(width: w*0.2, height: w*0.2))
            ctx.fill(p, with: .color(ink))

        case .happy:
            var p = Path()
            // 角度照 design/prototype/notch-buddy.html 的 1.12π→1.88π（Coucou Swift 版这里写错，画出来是个点）。
            p.addArc(center: CGPoint(x: 0, y: h*0.18), radius: w*0.82,
                     startAngle: .radians(.pi * 1.12), endAngle: .radians(.pi * 1.88), clockwise: false)
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: w*0.5, lineCap: .round))

        case .closed:
            var p = Path()
            p.addArc(center: CGPoint(x: 0, y: -h*0.08), radius: w*0.78,
                     startAngle: .degrees(15), endAngle: .degrees(165), clockwise: false)
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: w*0.36, lineCap: .round))

        case .spiral:
            var p = Path()
            var a: CGFloat = 0
            let spin = reduceMotion ? 0 : now * 9 * sd
            while a < 4.4 * .pi {
                let r  = w * 0.06 + a * w * 0.058
                let pt = CGPoint(x: cos(a + spin) * r, y: sin(a + spin) * r)
                if a == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                a += 0.2
            }
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: w*0.22, lineCap: .round))

        case .heart:
            ctx.fill(heartShape(size: w * 1.2), with: .color(Color(cgColor: .hex(0xFF4D6D))))

        case .star:
            if !reduceMotion { ctx.rotate(by: .radians(now * 1.5 * sd)) }
            ctx.fill(starShape(outer: w * 1.05, inner: w * 0.46), with: .color(Color(cgColor: .hex(0xF7B32B))))

        case .tired:
            var p1 = Path()
            p1.addRoundedRect(in: CGRect(x: -w/2, y: -h*0.02, width: w, height: h*0.38),
                              cornerSize: CGSize(width: w/2, height: w/2))
            ctx.fill(p1, with: .color(ink))
            var p2 = Path()
            p2.addRoundedRect(in: CGRect(x: -w*0.62, y: -h*0.1, width: w*1.24, height: w*0.22),
                              cornerSize: CGSize(width: w*0.11, height: w*0.11))
            ctx.fill(p2, with: .color(ink))

        case .wink:
            if sd < 0 {
                drawEyeShape(ctx: &ctx, shape: .pill, w: w, h: h, open: open, sd: sd)
            } else {
                drawEyeShape(ctx: &ctx, shape: .happy, w: w, h: h, open: open, sd: sd)
            }
        }
    }

    /// 头顶的小盾牌（Emily 规格第 3 节）：宽 0.46R、高 0.54R，上边微凸，两侧竖直 40% 后收成底尖，
    /// 圆角 0.06R；底尖落在身体顶边往下 0.10R。画在身体的变换里，所以跟着 tilt、sx/sy 和弹跳一起动。
    private func drawShield(ctx: GraphicsContext, kind: ShieldKind, R: CGFloat, ry: CGFloat) {
        let w = R * 0.46, h = R * 0.54, corner = R * 0.06
        let tip = -ry + R * 0.10
        let top = tip - h
        var ctx = ctx
        // 从底尖缩放，弹出时像是从头顶长出来。
        ctx.translateBy(x: 0, y: tip)
        ctx.scaleBy(x: shieldS, y: shieldS)
        ctx.translateBy(x: 0, y: -tip)

        // 实心盾：路径往里收一个圆角，再用同宽的圆头描边补回来，外轮廓正好是规格尺寸且带圆角。
        func outline(inset d: CGFloat) -> Path {
            let l = -w / 2 + d, r = w / 2 - d, t = top + d, b = tip - d
            let side = t + (b - t) * 0.4
            var p = Path()
            p.move(to: CGPoint(x: l, y: t))
            p.addQuadCurve(to: CGPoint(x: r, y: t), control: CGPoint(x: 0, y: t - R * 0.08))
            p.addLine(to: CGPoint(x: r, y: side))
            p.addQuadCurve(to: CGPoint(x: 0, y: b), control: CGPoint(x: r, y: side + (b - side) * 0.55))
            p.addQuadCurve(to: CGPoint(x: l, y: side), control: CGPoint(x: l, y: side + (b - side) * 0.55))
            p.closeSubpath()
            return p
        }

        switch kind {
        case .hollow:
            let lw = max(1.5, R * 0.07)
            ctx.stroke(outline(inset: lw / 2), with: .color(Color(cgColor: DundunConst.grey)),
                       style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        case .solid, .cracked:
            let color = Color(cgColor: kind == .solid ? DundunConst.amber : DundunConst.red)
            let body = outline(inset: corner)
            ctx.fill(body, with: .color(color))
            ctx.stroke(body, with: .color(color),
                       style: StrokeStyle(lineWidth: corner * 2, lineCap: .round, lineJoin: .round))
            if kind == .cracked {
                var crack = Path()
                crack.move(to: CGPoint(x: -R * 0.05, y: top + h * 0.18))
                crack.addLine(to: CGPoint(x: R * 0.04, y: top + h * 0.40))
                crack.addLine(to: CGPoint(x: -R * 0.03, y: top + h * 0.60))
                crack.addLine(to: CGPoint(x: R * 0.03, y: top + h * 0.80))
                ctx.stroke(crack, with: .color(.white.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func drawBadge(context: GraphicsContext, badge: BadgeType, R: CGFloat, cx: CGFloat, cy: CGFloat) {
        var ctx = context
        ctx.translateBy(x: cx - R * 0.72 * sx, y: cy - R * 0.72 * sy)
        ctx.scaleBy(x: badgeS, y: badgeS)
        let now = CGFloat(CACurrentMediaTime())

        switch badge {
        case .dots(let col):
            // Pill badge with animated dots (prototype style)
            let pw: CGFloat = R * 0.72
            let ph: CGFloat = R * 0.36
            var pill = Path()
            pill.addRoundedRect(in: CGRect(x: -pw/2, y: -ph/2, width: pw, height: ph),
                                cornerSize: CGSize(width: ph/2, height: ph/2))
            ctx.fill(pill, with: .color(Color(cgColor: col)))
            for i in 0..<3 {
                let phase = ((now * 2.4 - CGFloat(i) * 0.22).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
                let pulse = reduceMotion ? 0 : 0.4 * max(0, sin(phase * .pi * 2))
                let dotR = R * 0.055 * (1 + pulse)
                ctx.fill(Path(ellipseIn: CGRect(x: (CGFloat(i)-1)*R*0.18 - dotR, y: -dotR, width: dotR*2, height: dotR*2)),
                         with: .color(.white))
            }

        case .bang(let col), .question(let col):
            ctx.fill(Path(ellipseIn: CGRect(x: -R*0.3, y: -R*0.3, width: R*0.6, height: R*0.6)), with: .color(.black))
            ctx.fill(Path(ellipseIn: CGRect(x: -R*0.23, y: -R*0.23, width: R*0.46, height: R*0.46)),
                     with: .color(Color(cgColor: col)))
            let text = badge == .bang(col) ? "!" : "?"
            ctx.draw(Text(text).font(.system(size: R*0.32, weight: .black)).foregroundColor(.white),
                     at: CGPoint(x: 0, y: R*0.02))

        case .dot(let col):
            ctx.fill(Path(ellipseIn: CGRect(x: -R*0.2, y: -R*0.2, width: R*0.4, height: R*0.4)), with: .color(.black))
            ctx.fill(Path(ellipseIn: CGRect(x: -R*0.135, y: -R*0.135, width: R*0.27, height: R*0.27)),
                     with: .color(Color(cgColor: col)))
        }
    }

    private func drawParticles(context: GraphicsContext, R: CGFloat, cx: CGFloat, cy: CGFloat) {
        for p in particles {
            guard p.age > 0 else { continue }
            let k = CGFloat(p.age / p.life)
            let a = k < 0.2 ? k / 0.2 : 1 - (k - 0.2) / 0.8
            let px = cx + (p.x + p.vx * CGFloat(p.age)) * R * 1.3
            let py = cy + (p.y + p.vy * CGFloat(p.age)) * R * 1.3
            let sz = R * p.size * (1 + k * 0.4)

            var pctx = context
            pctx.translateBy(x: px, y: py)
            pctx.opacity = Double(min(max(a, 0), 1))

            switch p.type {
            case .heart:
                pctx.rotate(by: .radians(sin(CGFloat(p.age) * 6) * 0.3))
                pctx.fill(heartShape(size: sz), with: .color(Color(cgColor: .hex(0xFF4D6D))))
            case .star:
                pctx.rotate(by: .radians(p.rot + CGFloat(p.age) * 2))
                pctx.fill(starShape(outer: sz, inner: sz*0.45), with: .color(Color(cgColor: .hex(0xF7B32B))))
            case .spark:
                pctx.rotate(by: .radians(p.rot))
                pctx.fill(starShape(outer: sz*0.8, inner: sz*0.18), with: .color(.white))
            case .sweat:
                var drop = Path()
                drop.move(to: CGPoint(x: 0, y: -sz))
                drop.addQuadCurve(to: CGPoint(x: 0, y: sz*0.6), control: CGPoint(x: sz*0.8, y: sz*0.2))
                drop.addQuadCurve(to: CGPoint(x: 0, y: -sz), control: CGPoint(x: -sz*0.8, y: sz*0.2))
                pctx.fill(drop, with: .color(Color(cgColor: .hex(0x7CC7FF))))
            case .z:
                pctx.draw(Text("z").font(.system(size: sz*1.9, weight: .bold))
                            .foregroundColor(Color(red: 0.82, green: 0.86, blue: 0.92)), at: .zero)
            }
        }
    }

    // MARK: - Tween helpers

    /// 减弱动态效果时不做位移、打滚、抖动和缩放弹跳的补间；颜色、眼睛开合、角标和盾牌照常。
    private static let motionKeys: Set<String> = ["oy", "ox", "roll", "sx", "sy", "tilt", "yaw", "pitch"]

    func anim(_ key: String, _ keys: [TweenKey], onComplete: (() -> Void)? = nil) {
        if reduceMotion && Self.motionKeys.contains(key) { onComplete?(); return }
        if reduceMotion && (key == "badgeS" || key == "shieldS") {
            // 0.2 秒线性淡入淡出代替回弹。
            let target = keys.last?.target ?? 1
            tweens[key] = Tween(property: key, keys: [K(target, 200, Ease.lin)],
                                from: getProperty(key), startTime: CACurrentMediaTime() * 1000, onComplete: onComplete)
            locks.insert(key)
            return
        }
        tweens[key] = Tween(property: key, keys: keys, keyIndex: 0,
                            from: getProperty(key), startTime: CACurrentMediaTime() * 1000,
                            onComplete: onComplete)
        locks.insert(key)
    }

    private func setTarget(key: String, value: CGFloat) {
        guard !locks.contains(key) else { return }
        switch key {
        case "tint":  tint  += (value - tint)  // immediate target, smoothed in update
        case "tilt":  tgTilt = value
        default: break
        }
    }

    private static let props: [String: ReferenceWritableKeyPath<DundunEngine, CGFloat>] = [
        "yaw": \.yaw, "pitch": \.pitch, "roll": \.roll, "tilt": \.tilt, "open": \.open, "sx": \.sx,
        "sy": \.sy, "oy": \.oy, "ox": \.ox, "tint": \.tint, "blush": \.blush, "es": \.es,
        "badgeS": \.badgeS, "shieldS": \.shieldS,
    ]

    private func setProperty(_ key: String, value: CGFloat) {
        if let kp = Self.props[key] { self[keyPath: kp] = value }
    }

    private func getProperty(_ key: String) -> CGFloat {
        Self.props[key].map { self[keyPath: $0] } ?? 0
    }
}

// MARK: - Math helpers

private func cgColorToTuple(_ c: CGColor) -> (CGFloat, CGFloat, CGFloat) {
    let comps = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0.5, 0.5, 0.5, 1]
    return (comps[0], comps.count > 2 ? comps[1] : comps[0], comps.count > 2 ? comps[2] : comps[0])
}

private func mixColor(_ a: (CGFloat,CGFloat,CGFloat), _ b: (CGFloat,CGFloat,CGFloat), _ t: CGFloat) -> (CGFloat,CGFloat,CGFloat) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

private func colorFromTuple(_ t: (CGFloat,CGFloat,CGFloat)) -> Color {
    Color(red: Double(t.0), green: Double(t.1), blue: Double(t.2))
}

private func badgeString(_ b: BadgeType?) -> String {
    guard let b else { return "none" }
    switch b {
    case .dots:     return "dots"
    case .bang:     return "bang"
    case .question: return "q"
    case .dot(let c):
        let comps = c.components ?? []
        return "dot-" + comps.map { String(format: "%.3f", $0) }.joined(separator: ",")
    }
}

private func emoteEyeShape(_ e: DundunEmote) -> EyeShape {
    switch e {
    case .love:      return .heart
    case .surprised: return .dot
    case .proud:     return .star
    case .wink:      return .wink
    case .yawn:      return .tired
    case .happy:     return .happy
    case .annoyed:   return .line
    }
}

// MARK: - Shape helpers

private func heartShape(size s: CGFloat) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 0, y: s * 0.38))
    p.addCurve(to: CGPoint(x: 0, y: -s * 0.38),
               control1: CGPoint(x: -s * 1.05, y: -s * 0.15),
               control2: CGPoint(x: -s * 0.5,  y: -s * 0.95))
    p.addCurve(to: CGPoint(x: 0, y: s * 0.38),
               control1: CGPoint(x: s * 0.5,   y: -s * 0.95),
               control2: CGPoint(x: s * 1.05,  y: -s * 0.15))
    p.closeSubpath()
    return p
}

private func starShape(outer ro: CGFloat, inner ri: CGFloat) -> Path {
    var p = Path()
    for i in 0..<10 {
        let r = i.isMultiple(of: 2) ? ro : ri
        let a = -.pi/2 + CGFloat(i) * .pi/5
        let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}
