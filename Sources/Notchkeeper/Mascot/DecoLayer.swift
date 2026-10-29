import QuartzCore
import MascotCore

/// 一组装饰：每块部件一层、各自的锚点，以及进出场。同一份装饰既挂在盾盾右上角，也原样挂到收起态的右耳
/// （40pt 的装饰和右耳图标一样大，都是 1 画布单位 = 2pt，docs/mascot.md §2「右耳指示」）。
/// 不知道部件怎么循环（`Choreography.loop` 按下标点名，由持有它的视图提交）。
@MainActor
final class DecoLayer {
    let layer = CALayer()
    private(set) var parts: [CAShapeLayer] = []

    /// map：画布坐标 → 父层坐标；unit：1 画布单位多少 pt（描边宽要换算）；center：整组缩放的中心（画布坐标）
    init(_ deco: [DecoPart], in parent: CALayer, center: CGPoint, map: CGAffineTransform, unit: CGFloat, scale: CGFloat) {
        func mount(_ l: CALayer, in p: CALayer, anchor: CGPoint) {
            let a = anchor.applying(map)
            l.bounds = parent.bounds
            l.anchorPoint = CGPoint(x: a.x / parent.bounds.width, y: a.y / parent.bounds.height)
            l.position = a
            p.addSublayer(l)
        }
        mount(layer, in: parent, anchor: center)
        for d in deco {
            let s = CAShapeLayer()
            mount(s, in: layer, anchor: d.anchor)
            s.contentsScale = scale
            Self.paint(s, d.spec, map: map, unit: unit)
            parts.append(s)
        }
    }

    /// 旧装饰缩小淡出（ease-in），播完拿掉。淡出被撤掉（变得看不见）时 completion 也会调，旧装饰不会留下
    /// @see https://developer.apple.com/documentation/quartzcore/catransaction/setcompletionblock(_:)
    func exit(_ c: LookChange, animated: Bool) {
        let l = layer
        guard animated else { return l.removeFromSuperlayer() }
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        var animations: [CAAnimation] = []
        if let s = c.decoExitScale {
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = s
            animations.append(shrink)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = (l.presentation() ?? l).opacity
        fade.toValue = 0
        animations.append(fade)
        let g = CAAnimationGroup()
        g.animations = animations
        g.duration = c.decoExit
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        l.opacity = 0
        l.add(g, forKey: "exit")
        CATransaction.commit()
    }

    /// 延迟一会儿弹出：弹簧从 0.4 放大到 1（照 SF Symbols 的 Replace 效果），同时淡入
    /// @see https://developer.apple.com/videos/play/wwdc2023/10258/
    func enter(_ c: LookChange) {
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + c.decoEnterDelay
        var animations: [CAAnimation] = []
        if case .spring(let response, let damping)? = c.decoPop {
            let pop = MascotLayerView.spring(response: response, damping: damping, keyPath: "transform.scale")
            pop.fromValue = 0.4
            pop.toValue = 1
            animations.append(pop)
        }
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.duration = c.decoFadeIn
        animations.append(appear)
        for a in animations {
            a.beginTime = begin
            a.fillMode = .backwards
            layer.add(a, forKey: nil)
        }
    }

    static func paint(_ l: CAShapeLayer, _ s: ShapeSpec, map: CGAffineTransform, unit: CGFloat) {
        var t = map
        l.path = s.path.copy(using: &t)
        let color = s.color.cg
        switch s.paint {
        case .fill:
            l.fillColor = color
            l.strokeColor = nil
        case .stroke(let w):
            l.fillColor = nil
            l.strokeColor = color
            l.lineWidth = w * unit
        case .fillAndStroke(let w):
            l.fillColor = color
            l.strokeColor = color
            l.lineWidth = w * unit
        }
        l.lineCap = .round
        l.lineJoin = .round
        l.opacity = Float(s.opacity)
    }
}
