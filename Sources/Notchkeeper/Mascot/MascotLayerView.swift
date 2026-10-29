import AppKit
import QuartzCore
import MascotCore

/// 盾盾和右耳共用的两件事：此刻看不看得见；把 MascotCore 的 `Track` 提交成 Core Animation 动画。
/// 不知道画的是什么（子类搭图层树、给出 `Part` 对应哪一层）。
///
/// 看得见 = 在窗口里、窗口没收起也没被完全挡住、没熄屏也没锁屏（docs/mascot.md §5「渲染」）。
/// 窗口收起后 SwiftUI 不会移除里面的视图，所以要自己看窗口的遮挡状态。看不见时撤掉全部动画，
/// 静止值都在模型层上，回来时重新挂循环就行；左耳和面板的循环都从 `DundunDirector.epoch` 起算，所以步调一致。
/// @see https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property
@MainActor
class MascotLayerView: NSView {
    private(set) var active = false
    private var serial = 0
    private var loopKeys: [(CALayer, String)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("只用代码创建") }

    /// 和画布坐标一致：原点左上、+y 向下。AppKit 会把翻转视图的 layer 设成 geometryFlipped，子层跟着翻转，
    /// 正的旋转角在屏幕上是顺时针（实测 macOS 26，2026-10-29：转 0.5 弧度后，圆心右边的点在屏幕上往下走）
    /// @see https://developer.apple.com/documentation/quartzcore/calayer/isgeometryflipped
    override var isFlipped: Bool { true }
    /// 点击交给外面的 SwiftUI（面板里的盾盾点一下会晕）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    /// @see https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            DundunDirector.shared.attach(self)
        } else {
            DundunDirector.shared.detach(self)
        }
        refreshActive()
    }

    @objc private func occlusionChanged() { refreshActive() }

    /// 形状、渐变按屏幕倍率栅格化，换到别的屏幕时跟着换
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        func walk(_ l: CALayer) {
            l.contentsScale = scale
            l.sublayers?.forEach(walk)
            l.mask.map(walk)
        }
        layer?.sublayers?.forEach(walk)
    }

    func refreshActive() {
        let on = window?.occlusionState.contains(.visible) == true && !DundunDirector.shared.paused
        guard on != active else { return }
        active = on
        if !on {
            quietly { layer?.sublayers?.forEach(Self.removeAnimations) }
            loopKeys = []
        }
        activeChanged(on)
        DundunDirector.shared.activityChanged()
    }

    /// 子类：变得看得见时挂上循环，看不见时这里之前所有动画已经撤掉
    func activeChanged(_ on: Bool) {}

    /// 子类：Track 作用在哪一层
    func layer(for part: Part) -> CALayer? { nil }

    /// 1 画布单位多少 pt：位移的值要换算
    var unit: CGFloat { 1 }

    /// 提交一组 Track，从 begin（媒体时间）开始。loop 的那些会被 `stopLoops` 一起撤掉
    func play(_ tracks: [Track], at begin: CFTimeInterval = CACurrentMediaTime(), loop: Bool = false) {
        for t in tracks {
            guard let target = layer(for: t.part) else { preconditionFailure("没有这一层：\(t.part)") }
            let values = t.values.map { ca($0, t.property) }
            let a: CAPropertyAnimation
            if case .spring(let response, let damping) = t.timings.first {
                // SwiftUI 的 spring(response:dampingFraction:) 对应 duration = response、bounce = 1 − dampingFraction
                // @see https://developer.apple.com/documentation/quartzcore/caspringanimation/init(perceptualduration:bounce:)
                // @see https://developer.apple.com/videos/play/wwdc2023/10158/
                let s = CASpringAnimation(perceptualDuration: response, bounce: 1 - damping)
                s.fromValue = values[0]
                s.toValue = values[1]
                s.duration = s.settlingDuration
                a = s
            } else {
                let k = CAKeyframeAnimation()
                k.values = values
                k.keyTimes = t.keyTimes.map { NSNumber(value: $0) }
                k.timingFunctions = t.timings.map(Self.function)
                k.duration = t.duration
                a = k
            }
            a.keyPath = t.property.rawValue
            a.isAdditive = true
            a.beginTime = target.convertTime(begin, from: nil) + t.delay
            // 延后开始的动画在开始前就停在第一帧（比如还没弹出的装饰先藏着）
            a.fillMode = .backwards
            if t.repeats { a.repeatCount = .infinity }
            a.autoreverses = t.autoreverses
            serial += 1
            let key = "\(loop ? "loop" : "once").\(serial)"
            target.add(a, forKey: key)
            if loop { loopKeys.append((target, key)) }
        }
    }

    func stopLoops() {
        for (l, k) in loopKeys { l.removeAnimation(forKey: k) }
        loopKeys = []
    }

    /// 改模型层不带隐式动画：独立的 CALayer 改属性默认会自己动 0.25s
    /// @see https://developer.apple.com/documentation/quartzcore/catransaction/setdisableactions(_:)
    func quietly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// 不透明度从 from 淡到模型值（正弦缓动）
    func fade(_ l: CALayer, from: Float, duration: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
        l.add(a, forKey: "fade")
    }

    /// 静止值，单位同 Track（位移是画布单位）。transform 的子键路径走 Core Animation 的 KVC 扩展：
    /// 读的是分解出来的分量，写的时候重组整个 transform
    /// @see https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/Key-ValueCodingExtensions/Key-ValueCodingExtensions.html
    func model(_ l: CALayer, _ p: Property) -> Double {
        ((l.value(forKeyPath: p.rawValue) as? NSNumber)?.doubleValue ?? 0) / ca(1, p)
    }

    func setModel(_ l: CALayer, _ p: Property, _ v: Double) {
        l.setValue(ca(v, p), forKeyPath: p.rawValue)
    }

    private func ca(_ v: Double, _ p: Property) -> Double {
        p == .translationX || p == .translationY ? v * unit : v
    }

    private static func removeAnimations(_ l: CALayer) {
        l.removeAllAnimations()
        l.sublayers?.forEach(removeAnimations)
    }

    private static func function(_ t: Timing) -> CAMediaTimingFunction {
        guard case .bezier(let a, let b, let c, let d) = t else { preconditionFailure("关键帧里不能有弹簧：\(t)") }
        return CAMediaTimingFunction(controlPoints: Float(a), Float(b), Float(c), Float(d))
    }
}

extension RGB {
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}
