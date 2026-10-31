import AppKit
import NotchCore
import QuartzCore
import SwiftUI

/// 卡片边缘的流星（docs/ui.md「卡片」，用户 10-30）：卡片弹出、形状长好后，两颗流星从顶部两端沿边匀速流到底边中间，
/// 1.5 秒走完、汇合处淡出。只走一趟，不循环；不再代表倒计时，卡片停多久照设置。
/// 悬停、熄屏锁屏时卡片停住，还没走完的光也停在原处。常驻红卡没有倒计时、或开了减弱动态效果：不流，
/// 只画一条很淡的同色细边（照灵动岛的 keylineTint）。
/// @see https://developer.apple.com/documentation/widgetkit/dynamicisland/keylinetint(_:)
/// 不知道卡片是什么。
///
/// 照 Magic UI 的 Border Beam：一块渐变色块（透明 → 颜色 → 亮白）沿边框路径跑，用只留边框一圈的遮罩裁出来，
/// 尾巴是顺滑的渐变，拐角也跟着弯。光压在卡片边缘正中（视图放在卡片的裁切外面），柔光往里外两边晕开。
/// @see https://magicui.design/docs/components/border-beam
/// 位置交给 Core Animation：一条 1.5 秒的沿路径关键帧动画，按卡片弹出后已过的时间从对应那一帧放起；
/// 暂停时动画速度设成 0、停在那一帧。主线程不逐帧重画（CLAUDE.md「界面」）。
/// @see https://developer.apple.com/library/archive/qa/qa1673/_index.html
struct CardEdge: NSViewRepresentable {
    /// 和形状同一组参数：路径要和卡片外形完全重合
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let tint: Color
    /// nil：常驻卡片
    let countdown: CardCountdown?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CardEdgeView { CardEdgeView() }

    func updateNSView(_ v: CardEdgeView, context: Context) {
        v.set(shape: NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, closed: false),
              tint: NSColor(tint), countdown: countdown, reduceMotion: reduceMotion)
    }
}

final class CardEdgeView: NSView {
    /// 一层光：外层负责模糊，里层用一圈描边做遮罩，里面是左右两块沿边跑的渐变。先遮再模糊，光才晕得开
    private final class Beams {
        let blurred = CALayer()
        let ring = CALayer()
        let mask = CAShapeLayer()
        let left = CAGradientLayer()
        let right = CAGradientLayer()

        init(width: CGFloat, blur: CGFloat, opacity: Float, length: CGFloat) {
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.lineWidth = width
            mask.lineCap = .round
            mask.lineJoin = .round
            ring.mask = mask
            for g in [left, right] {
                g.startPoint = CGPoint(x: 0, y: 0.5)
                g.endPoint = CGPoint(x: 1, y: 0.5)
                // 头在右端：锚点放在头上，头压在路径上、尾巴拖在后面
                g.anchorPoint = CGPoint(x: 1, y: 0.5)
                g.bounds = CGRect(x: 0, y: 0, width: length, height: 24)
                g.locations = [0, 0.55, 0.92, 1]
                // 没在流的时候放在画面外
                g.position = CGPoint(x: -1000, y: -1000)
                ring.addSublayer(g)
            }
            blurred.addSublayer(ring)
            blurred.opacity = opacity
            if blur > 0 { blurred.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) as Any] }
        }
    }

    /// 常驻卡片的细边
    private let keyline = CAShapeLayer()
    /// 流星头外面的一层光：拉长的椭圆，顺着来的方向往后拉；不受边框遮罩，往边缘里外两边晕开
    private let heads = [CAGradientLayer(), CAGradientLayer()]
    /// 流星的实体头：清晰的水滴形，前端是比尾巴粗的亮核，往后收尖接进细尾巴；前白后卡片色，不模糊。
    /// 水滴是直的，放进一条沿边的窄带遮罩里：拐弯时偏出边缘的部分被裁掉，看上去贴着圆弧弯过去
    private let nuclei = [CAGradientLayer(), CAGradientLayer()]
    private let nucleusBand = CALayer()
    private let nucleusMask = CAShapeLayer()
    /// 流星的形状 = 头上的椭圆光团 + 只在靠近头那一段的柔光（短）+ 一路拖到后面的细芯（长）：亮而宽 → 渐细 → 消失
    private let core = Beams(width: 1, blur: 0, opacity: 1, length: 200)
    private let halo = Beams(width: 4, blur: 3, opacity: 0.6, length: 80)
    private var shape = NotchShape(topRadius: 0, bottomRadius: 0, closed: false)
    private var tint: NSColor?
    private var countdown: CardCountdown?
    private var reduceMotion = false

    /// 头上光团的长和宽；实体头的长度和亮核半径；模糊层四周留的余量
    /// 光团不能拉太长：拐弯时会朝切线方向甩出去
    private static let headSize = CGSize(width: 18, height: 9)
    /// 水滴不能太长：圆角半径 28pt，越长拐弯时偏出越多；剩下的长度交给会拐弯的细尾巴
    private static let nucleusLength: CGFloat = 16
    private static let nucleusRadius: CGFloat = 1.5
    private static let blurPad: CGFloat = 16
    /// 流星走一趟的时长（用户 10-30）
    private static let sweep: TimeInterval = 1.5
    /// 卡片弹出后等形状快长好再流，免得拐角错开；和 `Notch.swift` 里流星视图的淡入延迟是同一个数
    static let appearDelay: TimeInterval = 0.35

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // 柔光要高斯模糊：图层的 filters 只在打开它时生效，代价是这个视图在 App 进程里渲染；卡片收起就拆掉
        // @see https://developer.apple.com/documentation/appkit/nsview/layerusescoreimagefilters
        layerUsesCoreImageFilters = true
        guard let root = layer else { preconditionFailure("wantsLayer 之后一定有 layer") }
        root.masksToBounds = false
        keyline.fillColor = nil
        keyline.lineWidth = 1
        root.addSublayer(keyline)
        root.addSublayer(halo.blurred)
        root.addSublayer(core.blurred)
        for h in heads {
            h.type = .radial
            h.startPoint = CGPoint(x: 0.5, y: 0.5)
            h.endPoint = CGPoint(x: 1, y: 1)
            h.locations = [0, 0.25, 1]
            h.bounds = CGRect(origin: .zero, size: Self.headSize)
            // 椭圆的大半在头后面：光团往来的方向拉长，再收进尾巴
            h.anchorPoint = CGPoint(x: 0.7, y: 0.5)
            h.position = CGPoint(x: -1000, y: -1000)
            h.opacity = 0.7
            root.addSublayer(h)
        }
        // 水滴：尖在左（尾巴那头），圆在右（头）；锚点放在圆心上，圆心压在路径上
        let l = Self.nucleusLength, r = Self.nucleusRadius
        let drop = CGMutablePath()
        drop.move(to: CGPoint(x: 0, y: r))
        drop.addLine(to: CGPoint(x: l, y: 0))
        drop.addArc(center: CGPoint(x: l, y: r), radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        drop.closeSubpath()
        nucleusMask.fillColor = nil
        nucleusMask.strokeColor = NSColor.white.cgColor
        nucleusMask.lineWidth = 2 * r + 1.2
        nucleusMask.lineCap = .round
        nucleusMask.lineJoin = .round
        nucleusBand.mask = nucleusMask
        root.addSublayer(nucleusBand)
        for n in nuclei {
            n.startPoint = CGPoint(x: 0, y: 0.5)
            n.endPoint = CGPoint(x: 1, y: 0.5)
            n.locations = [0, 0.55, 0.85, 1]
            n.bounds = CGRect(x: 0, y: 0, width: l + r, height: 2 * r)
            n.anchorPoint = CGPoint(x: l / (l + r), y: 0.5)
            n.position = CGPoint(x: -1000, y: -1000)
            let shape = CAShapeLayer()
            shape.path = drop
            n.mask = shape
            nucleusBand.addSublayer(n)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("只用代码创建") }

    /// 和 SwiftUI 的 Shape 一样原点在左上
    override var isFlipped: Bool { true }
    func set(shape s: NotchShape, tint t: NSColor, countdown c: CardCountdown?, reduceMotion rm: Bool) {
        let changed = t != tint || c != countdown || rm != reduceMotion
        shape = s
        countdown = c
        reduceMotion = rm
        if t != tint {
            tint = t
            // 尾巴是卡片色、越往后越淡，头是亮白
            let colors = [t.withAlphaComponent(0), t.withAlphaComponent(0.35), t.blended(withFraction: 0.5, of: .white) ?? t, .white].map(\.cgColor)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for b in [core, halo] { [b.left, b.right].forEach { $0.colors = colors } }
            keyline.strokeColor = t.withAlphaComponent(0.5).cgColor
            // 中心亮白，往外过渡到卡片色，再到透明
            heads.forEach { $0.colors = [NSColor.white.withAlphaComponent(0.8), t.withAlphaComponent(0.35), t.withAlphaComponent(0)].map(\.cgColor) }
            nuclei.forEach { $0.colors = [t.withAlphaComponent(0), t.withAlphaComponent(0.7), NSColor.white, NSColor.white].map(\.cgColor) }
            CATransaction.commit()
        }
        if changed { reshape() }
    }

    /// 卡片跟着弹簧长大时，遮罩和轨迹都按新尺寸重算（动画按时间对齐，重挂不跳）
    override func layout() {
        super.layout()
        reshape()
    }

    private func reshape() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let path = shape.path(in: bounds).cgPath
        // 不流的时候（常驻卡片、减弱动态效果）只留一条很淡的同色细边
        let flowing = countdown != nil && !reduceMotion
        keyline.frame = bounds
        keyline.path = path
        nucleusBand.frame = bounds
        nucleusMask.frame = bounds
        nucleusMask.path = path
        keyline.isHidden = flowing
        // 模糊只画在图层范围里：四周多留余量，压在底边上的光才能往外晕开，不被切掉一半
        let pad = Self.blurPad
        for b in [core, halo] {
            b.blurred.frame = bounds.insetBy(dx: -pad, dy: -pad)
            b.ring.frame = CGRect(origin: CGPoint(x: pad, y: pad), size: bounds.size)
            b.mask.frame = b.ring.bounds
            b.mask.path = path
            [b.left, b.right].forEach { $0.removeAllAnimations() }
            b.blurred.isHidden = !flowing
        }
        (heads + nuclei).forEach {
            $0.removeAllAnimations()
            $0.isHidden = !flowing
        }
        guard flowing, let c = countdown else { return }
        // 走过的时间从形状长好那一刻算起；还没到时为负，动画在未来开始
        let elapsed = c.total - c.remaining(at: Date()) - Self.appearDelay
        // 已经走完：不再挂动画（暂停时 timeOffset 超过时长会绕回起点）
        guard elapsed < Self.sweep else {
            ([core.blurred, halo.blurred] + heads + nuclei).forEach { $0.isHidden = true }
            return
        }
        // 左边一道沿左半边从顶端流到底边中间，右边一道走镜像；头朝前，顺着路径转向，匀速走（看得出还剩多少）
        let half = shape.leftHalf(in: bounds).cgPath
        var mirror = CGAffineTransform(translationX: bounds.width, y: 0).scaledBy(x: -1, y: 1)
        guard let mirrored = half.copy(using: &mirror) else { preconditionFailure("仿射变换一定能复制路径") }
        let sides = [half, mirrored]
        // 光团和流星的头走同一条路、同一个时间轴，都顺着路径转向
        let layers = [core.left, core.right, halo.left, halo.right, heads[0], heads[1], nuclei[0], nuclei[1]]
        for (i, layer) in layers.enumerated() {
            let path = sides[i % 2]
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            move.rotationMode = .rotateAuto
            // 开头淡入，汇合前淡出
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.12, 0.8, 1]
            let once = CAAnimationGroup()
            once.animations = [move, fade]
            once.duration = Self.sweep
            // 走着：开始时刻往前推已过的时间（QA1673 恢复动画的写法；用 timeOffset 会在到点时绕回起点）；
            // 暂停：速度 0、停在已过的那一帧
            if c.isPaused {
                once.speed = 0
                once.timeOffset = max(elapsed, 0)
            } else {
                once.beginTime = CACurrentMediaTime() - elapsed
            }
            // 开始前停在第一帧（透明），走完停在最后一帧（透明）
            once.fillMode = .both
            once.isRemovedOnCompletion = false
            layer.add(once, forKey: "once")
        }
    }
}
