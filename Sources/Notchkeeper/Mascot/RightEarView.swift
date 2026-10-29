import AppKit
import SwiftUI
import QuartzCore
import MascotCore

/// 收起态右耳的指示（docs/mascot.md §2「右耳指示」）：44 宽、刘海高，指示的中心在 (44 − 17.5, H/2)
struct RightEarView: NSViewRepresentable {
    let indicator: EarIndicator
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> EarLayerView {
        let w = NotchLayout.earWidth
        return EarLayerView(size: CGSize(width: w, height: height), center: CGPoint(x: w - NotchLayout.earDotInset, y: height / 2),
                            indicator: indicator, reduceMotion: reduceMotion)
    }

    func updateNSView(_ v: EarLayerView, context: Context) {
        v.set(indicator, reduceMotion: reduceMotion)
    }
}

/// 右耳图层：点、三蓝点、灰环，或者 sign 造型的装饰图标（和 40pt 盾盾右上角的一样大、一样动）。
/// 换指示时和盾盾换装饰一样：旧的缩小淡出，新的弹出
@MainActor
final class EarLayerView: MascotLayerView {
    private let center: CGPoint
    private var indicator: EarIndicator
    private var reduceMotion: Bool
    private var shown: DecoLayer?

    init(size: CGSize, center: CGPoint, indicator: EarIndicator, reduceMotion: Bool) {
        self.center = center
        self.indicator = indicator
        self.reduceMotion = reduceMotion
        super.init(frame: CGRect(origin: .zero, size: size))
        shown = make()
    }

    func set(_ i: EarIndicator, reduceMotion rm: Bool) {
        guard i != indicator || rm != reduceMotion else { return }
        indicator = i
        reduceMotion = rm
        let c = Choreography.change(reduceMotion: rm)
        stopLoops(ease: false)
        quietly {
            shown?.exit(c, animated: active)
            shown = make()
            if active { shown?.enter(c) }
        }
        if active { startLoops(loops, delay: c.loopDelay) }
    }

    override func layer(for part: Part) -> CALayer? {
        switch part {
        case .decoPart(let i), .earDot(let i): return shown?.parts.indices.contains(i) == true ? shown?.parts[i] : nil
        default: return nil
        }
    }

    override var unit: CGFloat {
        if case .sign = indicator { return 2 }
        return 1
    }

    override func activeChanged(_ on: Bool) {
        if on { startLoops(loops) }
    }

    /// sign 只要装饰的节奏（右耳没有身体和头）
    private var loops: [Track] {
        switch indicator {
        case .dots: return Choreography.earDots(reduceMotion: reduceMotion)
        case .sign(let look):
            return Choreography.loop(look, size: .large, reduceMotion: reduceMotion).filter {
                if case .decoPart = $0.part { return true } else { return false }
            }
        case .none, .dot, .ring: return []
        }
    }

    private func make() -> DecoLayer? {
        guard let root = layer else { preconditionFailure("wantsLayer 之后一定有 layer") }
        let scale = window?.backingScaleFactor ?? 2
        func circle(_ c: CGPoint, diameter d: CGFloat, _ paint: Paint, _ color: RGB, opacity: Double = 1) -> DecoPart {
            let r = paint == .fill ? d / 2 : d / 2 - 0.5
            return DecoPart(spec: ShapeSpec(CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil),
                                            paint, color, opacity: opacity), anchor: c)
        }
        let parts: [DecoPart]
        var map = CGAffineTransform.identity
        switch indicator {
        case .none:
            return nil
        case .dots:
            // 直径 3，圆心在中心 x − 8、− 3、+ 2
            parts = [-8.0, -3, 2].map { circle(CGPoint(x: center.x + $0, y: center.y), diameter: 3, .fill, EarIndicator.dotsColor,
                                               opacity: Choreography.earDotRest) }
        case .dot(let color):
            parts = [circle(center, diameter: 7, .fill, color)]
        case .ring:
            // 7pt 外径、1pt 描边
            parts = [circle(center, diameter: 7, .stroke(1), .grey)]
        case .sign(let look):
            // 装饰外框的中心对准右耳中心，1 画布单位 = 2pt
            parts = look.decoration(.large)
            let box = parts.map { $0.spec.path.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
            map = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: 2, y: 2).translatedBy(x: -box.midX, y: -box.midY)
            return DecoLayer(parts, in: root, center: CGPoint(x: box.midX, y: box.midY), map: map, unit: 2, scale: scale)
        }
        return DecoLayer(parts, in: root, center: center, map: map, unit: 1, scale: scale)
    }
}
