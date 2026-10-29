import AppKit
import SwiftUI
import DundunCore

// MARK: - 盾盾最终画法（dundun-final-spec.md v2.8）

@MainActor
extension SelfTest {
    static func dundunTests(_ check: (String, Bool) -> Void) {
        _ = NSApplication.shared
        coordinateTests(check)
        microTests(check)
        renderTests(check)
        triggerTests(check)
    }

    /// 收起态坐标：W = 刘海 + 88，H = 刘海高；两种刘海尺寸
    private static func coordinateTests(_ check: (String, Bool) -> Void) {
        for notch in [CGSize(width: 185, height: 32), CGSize(width: 200, height: 38)] {
            let e = NotchLayout.ears(notch: notch)
            let w = notch.width + 88, h = notch.height
            let name = "\(Int(notch.width))×\(Int(notch.height))"
            check("耳朵坐标 \(name)：左画布左缘 10、上缘 H/2 − 16.5", e.canvas.minX == 10 && e.canvas.minY == h / 2 - 16.5)
            check("耳朵坐标 \(name)：身体左缘 14、圆心 (24, H/2)",
                  e.bodyCenter == CGPoint(x: 24, y: h / 2) && e.bodyCenter.x - NotchLayout.earMascotSize / 2 == 14)
            check("耳朵坐标 \(name)：右耳圆点圆心 (W − 17.5, H/2)，三颗点右缘 W − 14",
                  e.dot == CGPoint(x: w - 17.5, y: h / 2) && e.dots.x + 5 + 1.5 == w - 14)
            check("耳朵坐标 \(name)：形状 = W × H", NotchLayout.size(.closed, notch: notch, rows: 0) == CGSize(width: w, height: h))
        }
    }

    /// 「触发小动作」的四个动作在两种尺寸下的步数和时长（§8）
    private static func microTests(_ check: (String, Bool) -> Void) {
        for scale in [DundunScale.small, .large] {
            let sz = scale == .small ? "20pt" : "40pt"
            for (m, n, end) in [(DundunMicro.turn, 6, 0.88), (.pitch, 6, 0.5), (.roll, 6, 0.4)] {
                let c = run(scale) { p in p.trigger(m, at: 1) }
                check("小动作 \(sz) \(m.rawValue)：\(n) 帧、\(Int(end * 1000))ms 回正",
                      c.count == n && abs((c.last?.time ?? 0) - (1 + end)) < 1e-9)
            }
            let b = run(scale) { p in p.triggerBlink(at: 1) }
            check("小动作 \(sz) 眨眼：2 帧、闭眼 110ms",
                  b.count == 2 && abs(b[1].time - b[0].time - 0.11) < 1e-9 && b[0].render.eyeKind == .blink)
        }
        var p = DundunPlayer(scale: .small, look: .idle, at: 0, seed: 3)
        _ = p.advance(to: 0)
        _ = p.trigger(.roll, at: 1)
        if case let .flip(l, r) = p.frame(at: 1).eyes {
            check("小动作 20pt 左右翻是真翻滚（第一帧左眼 2×2、右眼 2×3）",
                  l == .rect(CGRect(x: 7, y: 13.5, width: 2, height: 2)) && r == .rect(CGRect(x: 13.5, y: 12.5, width: 2, height: 3)))
        } else {
            check("小动作 20pt 左右翻是真翻滚", false)
        }
        var q = DundunPlayer(scale: .small, look: .thinking, at: 0, seed: 3)
        check("小动作：不在空闲时按钮灰掉并给原因", q.microDisabledReason(at: 1) == "小动作只在空闲时播" && !q.trigger(.turn, at: 1))
    }

    /// 从 1s 起按 nextWake 跑到 2.5s，返回 1s 之后的步进帧
    private static func run(_ scale: DundunScale, _ start: (inout DundunPlayer) -> Bool) -> [DundunCommit] {
        var p = DundunPlayer(scale: scale, look: .idle, at: 0, seed: 11)
        _ = p.advance(to: 0)
        guard start(&p) else { return [] }
        var out: [DundunCommit] = []
        var t = 1.0
        if let c = p.advance(to: t) { out.append(c) }
        while let n = p.nextWake(after: t), n <= 2.5 {
            t = n
            if let c = p.advance(to: t), c.kind == .step { out.append(c) }
        }
        return out.filter { $0.time <= 1.9 }
    }

    /// 每个造型两种尺寸都画得出来，而且没有一个像素画到画布外（头顶装饰不被裁）
    private static func renderTests(_ check: (String, Bool) -> Void) {
        var drawn = true, inside = true, bad: [String] = []
        for scale in [DundunScale.small, .large] {
            let base = DundunPaint.base(scale)
            let margin: CGFloat = 12
            for look in DundunLook.allCases {
                var p = DundunPlayer(scale: scale, look: look, at: 0, seed: 5)
                _ = p.advance(to: 0)
                for t in [0.0, 0.1, 0.2, 0.35, 0.5, 0.8, 1.2, 1.6, 2.4, 60] {
                    let r = p.render(at: t)
                    let view = Canvas { ctx, _ in
                        var c = ctx
                        c.translateBy(x: margin, y: margin)
                        DundunPainter.draw(r, scale: scale, in: c)
                    }
                    .frame(width: base.width + 2 * margin, height: base.height + 2 * margin)
                    let ir = ImageRenderer(content: view)
                    ir.scale = 1
                    guard let img = ir.cgImage else { drawn = false; continue }
                    let (any, outside) = coverage(img, inner: CGRect(x: margin, y: margin, width: base.width, height: base.height))
                    drawn = drawn && any
                    if outside {
                        inside = false
                        bad.append("\(look.rawValue)@\(t)")
                    }
                }
            }
        }
        check("盾盾：12 个造型 × 20pt / 40pt 都画得出来", drawn)
        check("盾盾：所有帧都在画布里，头顶不被裁\(bad.isEmpty ? "" : "（\(bad.prefix(6).joined(separator: ", "))）")", inside)
        check("盾盾：unknown 收起态按空闲画、右耳不亮",
              DundunState.guardUnknown.look == .idle && EarIndicator.for(.idle, errorUnread: false).shape == nil)
        check("盾盾：等待（approval）和提问同一造型，stale 有自己的造型",
              DundunState.approval.look == .question && DundunState.guardStale.look == .stale
              && DundunState.interrupted.look == .interrupted)
    }

    private static func coverage(_ img: CGImage, inner: CGRect) -> (any: Bool, outside: Bool) {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (false, true) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var any = false, outside = false
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
                // CGContext 的行 0 在内存最前面，对应图片最上面一行
                let inIt = CGFloat(x) >= inner.minX - 0.5 && CGFloat(x) < inner.maxX + 0.5
                    && CGFloat(y) >= inner.minY - 0.5 && CGFloat(y) < inner.maxY + 0.5
                if inIt { any = true } else { outside = true }
            }
        }
        return (any, outside)
    }

    /// 真的 DundunDriver：看不见时不播；看得见时按一下转身，0.95s 里正好 6 次步进重画；
    /// 鼠标只在空闲时采样
    private static func triggerTests(_ check: (String, Bool) -> Void) {
        func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let d = DundunDriver(scale: .small, look: .idle, settled: true)
        DundunTriggers.shared.register(d, label: "自检")
        check("触发小动作：看不见时按钮灰掉", DundunTriggers.shared.reason(.turn, for: d) != nil && !d.trigger(.turn))
        d.setVisible(true)
        wait(0.3)
        check("触发小动作：空闲、看得见时在采样鼠标", d.isSamplingMouse)
        let before = DundunStats.shared.snapshot.steps
        let fired = DundunTriggers.shared.fire(.turn)
        wait(0.95)
        let steps = DundunStats.shared.snapshot.steps - before
        check("触发小动作：转身在真驱动上播一次，6 次步进重画（实得 \(steps)）", fired >= 1 && steps == 6)
        d.setLook(.working)
        wait(0.4)
        check("触发小动作：非空闲不采样鼠标，按钮灰掉", !d.isSamplingMouse && DundunTriggers.shared.reason(.turn, for: d) != nil)
        d.setVisible(false)
        check("看不见时停掉鼠标采样", !d.isSamplingMouse)
        DundunTriggers.shared.unregister(d)
    }
}
