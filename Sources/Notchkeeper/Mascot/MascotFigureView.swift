import AppKit
import QuartzCore
import MascotCore

/// 一只盾盾的图层树：把造型画出来，把 MascotCore 编排好的动作交给 Core Animation 播。
/// 中间帧由系统合成器在 App 进程外插值，App 只在换造型、动作开始、鼠标换了目标时提交一次（docs/mascot.md §5「渲染」）。
/// 不知道造型从哪来、什么时候眨眼（MascotDirector）。
///
/// 二维图形模拟三维（docs/mascot.md §1，照原型方案 (a)）：身体是球，眼睛贴在球面上，所有动作都是头的朝向。
/// stage ⊃ body（呼吸，锚点在身体底部）⊃ disc（圆形遮罩，不转）⊃ 渐变 + pose ⊃ yaw ⊃ pitch ⊃ roll ⊃ 两只眼；stage ⊃ 装饰。
/// pose 放造型的静止朝向，yaw / pitch 的静止值给跟随鼠标，动作叠加在 yaw / pitch / roll 上。
/// 眼睛图层锚点在眼睛中心、`anchorPointZ` 退到球心，按经纬度转到球面上；转到背面由 `isDoubleSided = false` 藏掉。
@MainActor
final class MascotFigureView: MascotLayerView {
    private let size: Size
    private let pt: CGFloat
    private let stage = CALayer(), body = CALayer(), disc = CALayer(), gradient = CAGradientLayer()
    private let poseLayer = CATransformLayer(), yawLayer = CATransformLayer(), pitchLayer = CATransformLayer(), rollLayer = CATransformLayer()
    private let eyeLayers = [CAShapeLayer(), CAShapeLayer()]
    private let rests = [Anatomy.leftEye, Anatomy.rightEye]
    private var deco: DecoLayer?

    private(set) var look: Look
    /// 两只眼当前的多边形（放大前）：下一次换形先对齐到它
    private var shapes: [EyeOutline]
    /// 收起态的左耳、面板：sign 装饰挪到右边，这里不画
    private var hidesSigns: Bool
    private var reduceMotion: Bool
    private var gazeTarget = Gaze.rest
    private var peeking = false
    /// 看得见时要补播的进场：创建时、或者看不见的时候换了造型
    private var entranceDue: Bool

    /// unit：1 画布单位多少 pt。entrance：第一次看得见时播不播当前造型的进场
    init(look: Look, size: Size, unit: CGFloat, reduceMotion: Bool, entrance: Bool, hidesSigns: Bool) {
        self.look = look
        self.size = size
        self.pt = unit
        self.reduceMotion = reduceMotion
        self.hidesSigns = hidesSigns
        entranceDue = entrance
        let e = look.eyes
        shapes = [e.left, e.right]
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: size.canvas.width * unit, height: size.canvas.height * unit)))
        build()
    }

    override var unit: CGFloat { pt }

    // MARK: 图层树

    private func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - size.canvas.minX) * pt, y: (p.y - size.canvas.minY) * pt)
    }

    private var toPoints: CGAffineTransform {
        CGAffineTransform(scaleX: pt, y: pt).translatedBy(x: -size.canvas.minX, y: -size.canvas.minY)
    }

    /// 子层和父层同大小、同坐标，只是锚点（缩放、旋转的中心）不同
    private func mount(_ l: CALayer, in parent: CALayer, anchor: CGPoint) {
        let a = point(anchor)
        l.bounds = bounds
        l.anchorPoint = CGPoint(x: a.x / bounds.width, y: a.y / bounds.height)
        l.position = a
        parent.addSublayer(l)
    }

    private func build() {
        guard let root = layer else { preconditionFailure("wantsLayer 之后一定有 layer") }
        let c = Anatomy.bodyCenter, r = Anatomy.bodyRadius
        mount(stage, in: root, anchor: c)
        mount(body, in: stage, anchor: CGPoint(x: c.x, y: c.y + r))
        mount(disc, in: body, anchor: c)
        let mask = CAShapeLayer()
        mask.frame = bounds
        var t = toPoints
        mask.path = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: &t)
        disc.mask = mask
        // 为了按屏幕倍率拍平三维子树，不是为了缓存：disc 里的动作一动就要重画（见 viewDidChangeBackingProperties）
        disc.shouldRasterize = true
        gradient.frame = bounds
        gradient.startPoint = CGPoint(x: 0.5, y: point(CGPoint(x: c.x, y: c.y - r)).y / bounds.height)
        gradient.endPoint = CGPoint(x: 0.5, y: point(CGPoint(x: c.x, y: c.y + r)).y / bounds.height)
        disc.addSublayer(gradient)
        mount(poseLayer, in: disc, anchor: c)
        mount(yawLayer, in: poseLayer, anchor: c)
        mount(pitchLayer, in: yawLayer, anchor: c)
        mount(rollLayer, in: pitchLayer, anchor: c)
        for (l, rest) in zip(eyeLayers, rests) {
            let (pitch, yaw) = Sphere.place(rest)
            l.bounds = bounds
            let a = point(rest)
            l.anchorPoint = CGPoint(x: a.x / bounds.width, y: a.y / bounds.height)
            l.anchorPointZ = -r * pt
            l.position = point(c)
            l.isDoubleSided = false
            // 先绕 x 轴转 pitch，再绕 y 轴转 yaw；约定同 HeadPose
            l.transform = CATransform3DConcat(CATransform3DMakeRotation(pitch, 1, 0, 0), CATransform3DMakeRotation(yaw, 0, 1, 0))
            l.fillColor = RGB.ink.cg
            rollLayer.addSublayer(l)
        }
        quietly {
            draw(look)
            settle(nil)
        }
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func eyePath(_ i: Int, _ poly: EyeOutline) -> CGPath {
        let k = Eyes.scale * (follows && peeking ? Choreography.peekEyes : 1)
        let p = CGMutablePath()
        p.addLines(between: poly.map { CGPoint(x: rests[i].x + $0.x * k, y: rests[i].y + $0.y * k).applying(toPoints) })
        p.closeSubpath()
        return p
    }

    private func poseTransform(_ l: Look) -> CATransform3D {
        let p = l.pose
        // 先 roll，再 pitch，最后 yaw：和图层树的嵌套顺序一致（docs/mascot.md §1）
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeRotation(p.roll, 0, 0, 1), CATransform3DMakeRotation(p.pitch, 1, 0, 0)),
                                   CATransform3DMakeRotation(p.yaw, 0, 1, 0))
    }

    private func makeDeco(_ l: Look) -> DecoLayer? {
        let parts = Self.decoration(l, size: size, hidesSigns: hidesSigns)
        guard !parts.isEmpty else { return nil }
        return DecoLayer(parts, in: stage, center: Anatomy.decoCenter, map: toPoints, unit: pt, scale: scale)
    }

    /// 直接换成某个造型的样子，不带动画
    private func draw(_ l: Look) {
        gradient.colors = [l.gradient.top.cg, l.gradient.bottom.cg]
        for (i, e) in eyeLayers.enumerated() { e.path = eyePath(i, shapes[i]) }
        poseLayer.transform = poseTransform(l)
        deco?.layer.removeFromSuperlayer()
        deco = makeDeco(l)
    }

    /// 头一转（yaw / pitch 不为 0），眼睛边缘就发软；展开时盾盾总在看刘海上的鼠标，眼睛就一直是糊的。
    /// 推断是三维子树拍平到 disc 时被重采样。disc 显式按屏幕倍率栅格化就清楚了（10-30 实测，docs/mascot.md §5「渲染」）
    /// @see https://developer.apple.com/documentation/quartzcore/calayer/shouldrasterize
    /// @see https://developer.apple.com/documentation/quartzcore/calayer/rasterizationscale
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        quietly { disc.rasterizationScale = scale }
    }

    override func layer(for part: Part) -> CALayer? {
        switch part {
        case .stage: return stage
        case .body: return body
        case .yaw: return yawLayer
        case .pitch: return pitchLayer
        case .roll: return rollLayer
        case .decoPart(let i): return deco?.parts.indices.contains(i) == true ? deco?.parts[i] : nil
        case .earDot: return nil
        }
    }

    // MARK: 静止值：注视 + 探头

    /// 只有睁着眼的造型看鼠标；减弱动态效果时不看、不探头（都是转动和缩放）
    private var follows: Bool { look.opensEyes && !reduceMotion }

    /// 正看着鼠标（不是回正的样子）：这时不做空闲小动作
    var isLooking: Bool { follows && gazeTarget != .rest }

    /// 把各层的静止值对到当前的注视、探头上；how 为 nil 时直接跳过去
    private func settle(_ how: Retarget?) {
        let g = follows ? gazeTarget : .rest
        let targets: [(Part, CALayer, Property, Double)] = [
            (.yaw, yawLayer, .rotationY, g.yaw),
            (.pitch, pitchLayer, .rotationX, g.pitch),
            (.body, body, .scale, follows && peeking ? Choreography.peekScale : 1),
        ]
        var tracks: [Track] = []
        quietly {
            for (part, l, p, new) in targets {
                let old = model(l, p)
                guard abs(old - new) > 1e-9 else { continue }
                setModel(l, p, new)
                if let how, active { tracks.append(Choreography.retarget(part, p, from: old, to: new, how)) }
            }
        }
        play(tracks)
    }

    // MARK: 外面调用

    /// 换造型；hidesSigns 一起给：两样都变时只换一次装饰，旧造型的告示不会先画出来再退场
    func setLook(_ new: Look, hidesSigns h: Bool) {
        guard new != look else { return setHidesSigns(h) }
        hidesSigns = h
        look = new
        let e = new.eyes
        shapes = [Eyes.aligned(e.left, to: shapes[0]), Eyes.aligned(e.right, to: shapes[1])]
        guard active else {
            quietly { draw(new); settle(nil) }
            entranceDue = true
            return
        }
        let c = Choreography.change(reduceMotion: reduceMotion)
        stopLoops(ease: !reduceMotion)
        quietly {
            for (i, eye) in eyeLayers.enumerated() {
                let to = eyePath(i, shapes[i])
                morph(eye, to: to, duration: c.eyeMorph)
                eye.path = to
            }
            let colors = [new.gradient.top.cg, new.gradient.bottom.cg]
            let blend = CABasicAnimation(keyPath: "colors")
            blend.fromValue = gradient.presentation()?.colors ?? gradient.colors
            blend.toValue = colors
            blend.duration = c.colorFade
            blend.timingFunction = Self.function(.sineInOut)
            gradient.add(blend, forKey: "colors")
            gradient.colors = colors
            let pose = poseTransform(new)
            if case .spring(let response, let damping)? = c.pose {
                let s = Self.spring(response: response, damping: damping, keyPath: "transform")
                s.fromValue = poseLayer.presentation()?.transform ?? poseLayer.transform
                s.toValue = pose
                poseLayer.add(s, forKey: "pose")
            }
            poseLayer.transform = pose
            deco?.exit(c, animated: true)
            deco = makeDeco(new)
            deco?.enter(c)
        }
        settle(Choreography.followSpring)
        play(Choreography.entrance(new, reduceMotion: reduceMotion))
        startLoops(loops, delay: c.loopDelay)
    }

    /// 眼形从屏幕上的样子逐点补间到 to（形状已对齐，点数相同）。先撤掉眨眼：
    /// 它比换形长，换形一结束会接着用旧的路径画下去
    private func morph(_ eye: CAShapeLayer, to: CGPath, duration: Double) {
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = eye.presentation()?.path ?? eye.path
        a.toValue = to
        a.duration = duration
        a.timingFunction = Self.function(.sineInOut)
        eye.removeAnimation(forKey: "blink")
        eye.add(a, forKey: "morph")
    }

    /// 飞到卡片上时告示画回来（红卡的 !!），回到左耳、面板再收起；换法和换造型时的装饰一样
    private func setHidesSigns(_ on: Bool) {
        guard on != hidesSigns else { return }
        hidesSigns = on
        guard look.isSign else { return }
        guard active else {
            quietly { draw(look) }
            return
        }
        let c = Choreography.change(reduceMotion: reduceMotion)
        stopLoops(ease: false)
        quietly {
            deco?.exit(c, animated: true)
            deco = makeDeco(look)
            deco?.enter(c)
        }
        startLoops(loops, delay: c.loopDelay)
    }

    func setReduceMotion(_ on: Bool) {
        guard on != reduceMotion else { return }
        reduceMotion = on
        quietly {
            for (i, e) in eyeLayers.enumerated() { e.path = eyePath(i, shapes[i]) }
        }
        settle(nil)
        if active {
            stopLoops(ease: false)
            startLoops(loops)
        }
    }

    /// 鼠标位置（屏幕坐标），nil = 鼠标停下太久，慢慢回正
    func follow(mouse: NSPoint?) {
        var g = Gaze.rest
        if let mouse, let window {
            let c = window.convertPoint(toScreen: convert(point(Anatomy.bodyCenter), to: nil))
            // 屏幕坐标 +y 向上，Gaze 要的是 +y 向下
            g = Gaze(toward: CGVector(dx: mouse.x - c.x, dy: c.y - mouse.y))
        }
        guard g != gazeTarget else { return }
        gazeTarget = g
        // 不跟随的造型只记下目标，换回会看鼠标的造型时 settle 再用
        guard active, follows else { return }
        if mouse == nil {
            settle(Choreography.gazeReturn)
        } else {
            settle(Choreography.followSpring)
        }
    }

    func setPeeking(_ on: Bool) {
        guard on != peeking else { return }
        peeking = on
        guard follows else { return }
        settle(Choreography.peekSpring)
        quietly {
            for (i, eye) in eyeLayers.enumerated() {
                let to = eyePath(i, shapes[i])
                if active { morph(eye, to: to, duration: Choreography.peekEyeMorph) }
                eye.path = to
            }
        }
    }

    /// force：「播放动作」测试用，不管当前造型能不能做
    func perform(_ cue: Cue, force: Bool = false) {
        guard active else { return }
        switch cue {
        case .blink(let twice):
            guard force || look.opensEyes else { return }
            // 正在换形就不眨：两段路径动画叠在一起会抢同一个 path
            guard eyeLayers.allSatisfy({ $0.animation(forKey: "morph") == nil && $0.animation(forKey: "blink") == nil }) else { return }
            blink(twice: twice)
        case .idle(let m):
            guard force || (look == .idle && !isLooking) else { return }
            play(Choreography.tracks(for: m, reduceMotion: reduceMotion))
        }
    }

    /// 眨眼：眼形补间成一条线再回来（docs/mascot.md §5）
    private func blink(twice: Bool) {
        let close = Choreography.blinkClose, open = Choreography.blinkOpen
        let once = close + open
        let total = twice ? Choreography.secondBlinkAfter + once : once
        for (i, eye) in eyeLayers.enumerated() {
            let o = eyePath(i, shapes[i])
            let s = eyePath(i, Eyes.shut(shapes[i]))
            var keys: [(Double, CGPath)] = [(0, o), (close, s), (once, o)]
            if twice { keys += [(Choreography.secondBlinkAfter, o), (Choreography.secondBlinkAfter + close, s), (total, o)] }
            let a = CAKeyframeAnimation(keyPath: "path")
            a.values = keys.map(\.1)
            a.keyTimes = keys.map { NSNumber(value: $0.0 / total) }
            a.timingFunctions = Array(repeating: Self.function(.sineInOut), count: keys.count - 1)
            a.duration = total
            eye.add(a, forKey: "blink")
        }
    }

    /// 画哪些装饰：收起态的左耳不画 sign（挪到右耳）。挂哪些装饰循环也只看这里，两边不会对不上
    nonisolated static func decoration(_ look: Look, size: Size, hidesSigns: Bool) -> [DecoPart] {
        hidesSigns && look.isSign ? [] : look.decoration(size)
    }

    /// 要挂的循环：只给画出来的装饰部件挂
    nonisolated static func loops(_ look: Look, size: Size, reduceMotion: Bool, hidesSigns: Bool) -> [Track] {
        let drawn = decoration(look, size: size, hidesSigns: hidesSigns).count
        return Choreography.loop(look, size: size, reduceMotion: reduceMotion).filter {
            if case .decoPart(let i) = $0.part { return i < drawn } else { return true }
        }
    }

    private var loops: [Track] { Self.loops(look, size: size, reduceMotion: reduceMotion, hidesSigns: hidesSigns) }

    // MARK: 看得见 / 看不见

    override func activeChanged(_ on: Bool) {
        guard on else { return }
        settle(nil)
        startLoops(loops)
        if entranceDue {
            entranceDue = false
            play(Choreography.entrance(look, reduceMotion: reduceMotion))
        }
    }
}
