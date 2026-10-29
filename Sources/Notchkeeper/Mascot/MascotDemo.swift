#if DEBUG
import AppKit
import SwiftUI
import DundunCore

/// `Notchkeeper --mascot-demo [outdir]`：把盾盾每个状态画成黑底 PNG，截图验收用，
/// 不用真去触发守卫或跑 agent（dundun-final-spec.md、agent-cards.md）。只在 DEBUG 构建里有。
/// 画的是 DundunCore 给的确定帧（停留帧、小动作中间帧、过渡中间帧），和屏幕上一模一样的 DundunPaint。
@MainActor
enum MascotDemo {
    static func run(outDir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var ok = true
        var count = 0
        func shot(_ name: String, _ r: DundunRender, _ scale: DundunScale) {
            let base = DundunPaint.base(scale)
            let view = DundunPaint(render: r, scale: scale, size: base)
                .frame(width: base.width, height: base.height)
                .background(Color.black)
            let ir = ImageRenderer(content: view)
            ir.scale = scale == .small ? 4 : 2
            ok = save(ir.cgImage, outDir.appendingPathComponent("\(name).png")) && ok
            count += 1
        }
        for scale in [DundunScale.small, .large] {
            let sz = scale == .small ? "20" : "40"
            for look in DundunLook.allCases {
                let p = DundunPlayer(scale: scale, look: look, at: 0, seed: 7)
                shot("\(look.rawValue)-\(sz)", p.render(at: 60), scale)
                shot("\(look.rawValue)-\(sz)-enter", p.render(at: 0.25), scale)
            }
            for m in [DundunMicro.turn, .pitch, .roll, .peek] {
                var p = DundunPlayer(scale: scale, look: .idle, at: 0, seed: 7)
                _ = p.advance(to: 0)
                _ = p.trigger(m, at: 1)
                shot("micro-\(m.rawValue)-\(sz)", p.render(at: 1.2), scale)
            }
            var t = DundunPlayer(scale: scale, look: .idle, at: 0, seed: 7)
            _ = t.advance(to: 0)
            t.setLook(.danger, at: 1)
            shot("transition-idle-danger-\(sz)", t.render(at: 1.1), scale)
        }

        // 真实的红卡：放进屏幕外的窗口，让 TimelineView 和 onAppear 照常跑
        let card = NotchCardView(card: .exitAlert(), countdown: nil, onDismiss: {})
            .frame(width: NotchLayout.cardWidth)
            .padding(.vertical, 16)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: card)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: host.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()

        // 让卡片里的 onAppear 和计时器跑一会儿再截
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            ok = save(rep.cgImage, outDir.appendingPathComponent("card-violated-38.png")) && ok
        } else {
            ok = false
        }
        window.close()
        print("mascot demo: \(count + 1) PNG → \(outDir.path)")
        return ok
    }

    private static func save(_ image: CGImage?, _ url: URL) -> Bool {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("FAIL  \(url.lastPathComponent)")
            return false
        }
        return (try? png.write(to: url)) != nil
    }
}
#endif
