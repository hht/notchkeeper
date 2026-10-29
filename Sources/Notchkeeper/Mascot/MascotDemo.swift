#if DEBUG
import AppKit
import SwiftUI

/// `Notchkeeper --mascot-demo [outdir]`：把盾盾每个状态画成黑底 2x 的 PNG，截图验收用，
/// 不用真去触发守卫或跑 agent（mascot-port-batch1.md、agent-cards.md）。只在 DEBUG 构建里有。
@MainActor
enum MascotDemo {
    static func run(outDir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var shots: [(name: String, engine: DundunEngine, size: CGFloat)] = []
        func add(_ name: String, _ state: DundunState, size: CGFloat, reduceMotion: Bool = false, beaming: Bool = false) {
            let e = DundunEngine()
            e.reduceMotion = reduceMotion
            e.showsShield = size >= 30
            e.setState(state, force: true)
            if beaming { e.setPermanentEmote(.happy) }
            shots.append((name, e, size))
        }
        for s in DundunState.allCases {
            add("\(s.rawValue)-40", s, size: 40)
            add("\(s.rawValue)-40-reduce-motion", s, size: 40, reduceMotion: true)
            add("\(s.rawValue)-120", s, size: 120)
        }
        add("idle-22", .idle, size: 22)
        add("sleeping-22", .sleeping, size: 22)
        add("about-beaming-54", .idle, size: 54, beaming: true)

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

        // 补间按真实时间算：主线程跑 1.6 秒、每 1/60 秒走一步，停在各状态稳定后的画面
        let end = Date().addingTimeInterval(1.6)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
            for s in shots { s.engine.update(dt: DundunCanvasView.stepDt) }
        }

        var ok = true
        for s in shots {
            let c = DundunCanvasView.canvasSize(body: s.size)
            let still = Canvas { ctx, size in
                s.engine.draw(context: ctx, size: size)
                s.engine.drawExtras(context: ctx, size: size)
            }
            .frame(width: c.width, height: c.height)
            .background(Color.black)
            let r = ImageRenderer(content: still)
            r.scale = 2
            ok = save(r.cgImage, outDir.appendingPathComponent("\(s.name).png")) && ok
        }
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            ok = save(rep.cgImage, outDir.appendingPathComponent("card-violated-38.png")) && ok
        } else {
            ok = false
        }
        window.close()
        print("mascot demo: \(shots.count + 1) PNG → \(outDir.path)")
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
