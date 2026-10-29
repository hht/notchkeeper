import AppKit
import QuartzCore
import DundunCore

/// 一只盾盾的图层树：把造型画出来，把 DundunCore 编排好的动作交给 Core Animation 播。
/// 中间帧由系统合成器在 App 进程外插值，App 只在换造型、动作开始、鼠标换了目标时提交一次（docs/dundun.md §5「渲染」）。
/// 不知道造型从哪来、什么时候眨眼（DundunDirector）。
///
/// 和 ui-ux-pro-max 的 SwiftUI 建议（用 `.animation`）不同：自定义 Animatable 每一帧都要在主线程跑 body，
/// 常驻的小部件改用 Core Animation（Lottie 4 换成 Core Animation 引擎也是这个理由）。
/// @see https://developer.apple.com/videos/play/wwdc2023/10156/
/// @see https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html
///
/// 图层（都和画布同大小、同坐标，只是锚点不同）：
/// stage（整体不透明度）⊃ body（锚点在身体底部）⊃ disc（圆形遮罩，不转）⊃ turn（绕圆心转）⊃ 渐变 + gaze ⊃ lids ⊃ 两只眼；
/// stage ⊃ deco（右上装饰，不跟身体动）
@MainActor
final class DundunLayerView: MascotLayerView {
    private let size: Size
    private let pt: CGFloat
    private let stage = CALayer(), body = CALayer(), disc = CALayer(), turn = CALayer(), gradient = CAGradientLayer()
    private let gaze = CALayer(), lids = CALayer(), leftEye = CAShapeLayer(), rightEye = CAShapeLayer()
    private var deco = CALayer()

    private(set) var look: Look
    private var reduceMotion: Bool
    private var gazeTarget = Gaze.rest
    private var peeking = false
    /// 看得见时要补播的进场：创建时、或者看不见的时候换了造型
    private var entranceDue: Bool

    /// unit：1 画布单位多少 pt。entrance：第一次看得见时播不播当前造型的进场（「关于」页一直开心的那只不播）
    init(look: Look, size: Size, unit: CGFloat, reduceMotion: Bool, entrance: Bool) {
        self.look = look
        self.size = size
        self.pt = unit
        self.reduceMotion = reduceMotion
        entranceDue = entrance
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
        let circle = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        mount(stage, in: root, anchor: c)
        mount(body, in: stage, anchor: CGPoint(x: c.x, y: c.y + r))
        mount(disc, in: body, anchor: c)
        let mask = CAShapeLayer()
        mask.frame = bounds
        var t = toPoints
        mask.path = CGPath(ellipseIn: circle, transform: &t)
        disc.mask = mask
        mount(turn, in: disc, anchor: c)
        // 渐变比圆大一圈，转起来四角不露底；起止点仍对准圆的上下沿
        let rect = circle.applying(toPoints)
        let pad = rect.height * 0.25
        gradient.frame = rect.insetBy(dx: -pad, dy: -pad)
        let edge = Double(pad / gradient.frame.height)
        gradient.startPoint = CGPoint(x: 0.5, y: edge)
        gradient.endPoint = CGPoint(x: 0.5, y: 1 - edge)
        turn.addSublayer(gradient)
        let eyeLine = CGPoint(x: c.x, y: Anatomy.eyeLine)
        mount(gaze, in: turn, anchor: eyeLine)
        mount(lids, in: gaze, anchor: eyeLine)
        mount(leftEye, in: lids, anchor: Anatomy.leftEye)
        mount(rightEye, in: lids, anchor: Anatomy.rightEye)
        quietly {
            draw(look)
            settle(nil)
        }
    }

    /// 直接换成某个造型的样子，不带动画
    private func draw(_ l: Look) {
        gradient.colors = [l.gradient.top.cg, l.gradient.bottom.cg]
        paint(leftEye, l.eyes.left)
        paint(rightEye, l.eyes.right)
        deco.removeFromSuperlayer()
        deco = makeDeco(l)
    }

    private func makeDeco(_ l: Look) -> CALayer {
        let d = CALayer()
        mount(d, in: stage, anchor: Anatomy.decoCenter)
        for spec in l.decoration(size) {
            let s = CAShapeLayer()
            s.frame = bounds
            s.contentsScale = window?.backingScaleFactor ?? 2
            paint(s, spec)
            d.addSublayer(s)
        }
        return d
    }

    private func paint(_ l: CAShapeLayer, _ s: ShapeSpec) {
        var t = toPoints
        l.path = s.path.copy(using: &t)
        let color = s.color.cg
        switch s.paint {
        // 不画的那一项用透明色而不是 nil：换眼形时「保持旧值」的动画两端都得是确定的值，nil 会被当成「取呈现层的值」去插值
        // @see https://developer.apple.com/documentation/quartzcore/cabasicanimation
        case .fill:
            l.fillColor = color
            l.strokeColor = CGColor.clear
            l.lineWidth = 0
        case .stroke(let w):
            l.fillColor = CGColor.clear
            l.strokeColor = color
            l.lineWidth = w * pt
        case .fillAndStroke(let w):
            l.fillColor = color
            l.strokeColor = color
            l.lineWidth = w * pt
        }
        l.lineCap = .round
        l.lineJoin = .round
        l.opacity = Float(s.opacity)
    }

    override func layer(for part: Part) -> CALayer? {
        switch part {
        case .body: return body
        case .turn: return turn
        case .gaze: return gaze
        case .lids: return lids
        case .leftEye: return leftEye
        case .rightEye: return rightEye
        case .deco: return deco
        case .decoPart(let i): return deco.sublayers?.indices.contains(i) == true ? deco.sublayers?[i] : nil
        case .ring: return nil
        }
    }

    // MARK: 静止值：姿态 + 注视 + 探头

    /// 只有睁着眼的造型看鼠标；减弱动态效果时不看、不探头（都是位移和缩放）
    private var follows: Bool { look.blinks && !reduceMotion }

    /// 正看着鼠标（不是回正的样子）：这时不做空闲小动作
    var isLooking: Bool { follows && gazeTarget != .rest }

    /// 把各层的静止值对到当前的姿态、注视、探头上；timing 为 nil 时直接跳过去
    private func settle(_ timing: Timing?, duration: Double = 0) {
        let pose = look.pose
        let g = follows ? gazeTarget : .rest
        let peek = follows && peeking
        let targets: [(Part, CALayer, Property, Double)] = [
            (.body, body, .scale, pose.scale * (peek ? Choreography.peekScale : 1)),
            (.body, body, .translationY, pose.dy),
            (.turn, turn, .rotation, pose.tilt + g.tilt),
            (.gaze, gaze, .translationX, g.eyes.dx),
            (.gaze, gaze, .translationY, g.eyes.dy),
            (.gaze, gaze, .scale, peek ? Choreography.peekEyes : 1),
        ]
        var tracks: [Track] = []
        quietly {
            for (part, l, p, new) in targets {
                let old = model(l, p)
                guard abs(old - new) > 1e-9 else { continue }
                setModel(l, p, new)
                if let timing, active, !reduceMotion {
                    tracks.append(Choreography.retarget(part, p, from: old, to: new, timing, duration: duration))
                }
            }
            if stage.opacity != Float(pose.opacity) {
                if timing != nil, active { fade(stage, from: stage.opacity, duration: 0.3) }
                stage.opacity = Float(pose.opacity)
            }
        }
        play(tracks)
    }

    // MARK: 外面调用

    func setLook(_ new: Look) {
        guard new != look else { return }
        look = new
        guard active else {
            quietly { draw(new); settle(nil) }
            entranceDue = true
            return
        }
        let change = Choreography.change(reduceMotion: reduceMotion)
        quietly {
            // 颜色交叉淡化
            let colors = gradient.presentation()?.colors ?? gradient.colors
            let blend = CABasicAnimation(keyPath: "colors")
            blend.fromValue = colors
            blend.duration = change.colorFade
            blend.timingFunction = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
            gradient.colors = [new.gradient.top.cg, new.gradient.bottom.cg]
            gradient.add(blend, forKey: "colors")
            // 眼形在眼睛压成线（或淡没）的那一刻换：之前一直显示旧的
            for (eye, spec) in [(leftEye, new.eyes.left), (rightEye, new.eyes.right)] {
                for key in ["path", "fillColor", "strokeColor", "lineWidth"] {
                    let hold = CABasicAnimation(keyPath: key)
                    hold.fromValue = eye.value(forKey: key)
                    hold.toValue = eye.value(forKey: key)
                    hold.duration = change.swapAt
                    eye.add(hold, forKey: "hold.\(key)")
                }
                paint(eye, spec)
            }
            // 旧装饰淡出后拿掉，新装饰按进场出来。淡出被撤掉（变得看不见）时 completion 也会调，旧装饰不会留下
            // @see https://developer.apple.com/documentation/quartzcore/catransaction/setcompletionblock(_:)
            let gone = deco
            CATransaction.setCompletionBlock { gone.removeFromSuperlayer() }
            gone.opacity = 0
            fade(gone, from: 1, duration: change.decoFadeOut)
            deco = makeDeco(new)
        }
        stopLoops()
        // 眼皮同一时刻只做一件事：眨眼和「眨眼换形」都是在 scaleY 上叠 −0.9，叠在一起会变成 −0.8，眼睛被上下翻过来
        lids.removeAllAnimations()
        play(change.tracks)
        settle(Choreography.poseSpring)
        play(Choreography.entrance(new, reduceMotion: reduceMotion))
        startLoops()
    }

    func setReduceMotion(_ on: Bool) {
        guard on != reduceMotion else { return }
        reduceMotion = on
        settle(nil)
        if active {
            stopLoops()
            startLoops()
        }
    }

    /// 鼠标位置（屏幕坐标），nil = 鼠标停下太久，慢慢回正
    func follow(mouse: NSPoint?) {
        var g = Gaze.rest
        if let mouse, let window {
            let c = window.convertPoint(toScreen: convert(point(Anatomy.bodyCenter), to: nil))
            // 屏幕坐标 +y 向上，画布 +y 向下
            g = Gaze(toward: CGVector(dx: mouse.x - c.x, dy: c.y - mouse.y))
        }
        guard g != gazeTarget else { return }
        gazeTarget = g
        // 不跟随的造型只记下目标，换回会看鼠标的造型时 settle 再用
        guard active, follows else { return }
        if mouse == nil {
            settle(.sineInOut, duration: Choreography.gazeReturn)
        } else {
            settle(Choreography.followSpring)
        }
    }

    func setPeeking(_ on: Bool) {
        guard on != peeking else { return }
        peeking = on
        guard follows else { return }
        settle(Choreography.peekSpring)
    }

    /// force：「播放动作」测试用，不管当前造型能不能做
    func perform(_ cue: Cue, force: Bool = false) {
        guard active else { return }
        if !force {
            switch cue {
            case .blink: guard look.blinks else { return }
            case .idle: guard look == .idle, !isLooking else { return }
            }
        }
        if case .blink = cue, lids.animationKeys()?.isEmpty == false { return }
        play(Choreography.tracks(for: cue, reduceMotion: reduceMotion))
    }

    // MARK: 看得见 / 看不见

    override func activeChanged(_ on: Bool) {
        guard on else { return }
        settle(nil)
        startLoops()
        if entranceDue {
            entranceDue = false
            play(Choreography.entrance(look, reduceMotion: reduceMotion))
        }
    }

    private func startLoops() {
        play(Choreography.loop(look, size: size, reduceMotion: reduceMotion), at: DundunDirector.shared.epoch, loop: true)
    }
}
