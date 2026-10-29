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

import AppKit
import SwiftUI

/// 盾盾的画布：把 DundunEngine 画进 SwiftUI，管帧率、尺寸、交互，以及「晕」「犯困」这两个只在本地的状态。
/// 外面只通过 Mascot.swift 的 `MascotRenderable` 用它（AGENTS.md）。
struct DundunCanvasView: MascotRenderable {
    let state: DundunState
    /// 身体宽度，也是布局里占的 size×size；画布按比例放大画在 overlay 里，蹦跳和盾牌可以出框。
    let size: CGFloat
    let emote: MascotEmote
    /// 面板头部那只：能拍、眼睛跟着鼠标、悬停时眼睛放大
    let interactive: Bool

    init(state: DundunState, size: CGFloat, emote: MascotEmote = .none, interactive: Bool = false) {
        self.state = state
        self.size = size
        self.emote = emote
        self.interactive = interactive
    }

    /// 引擎里身体半宽 R = 画布宽 × 0.3，身体宽 2.28R
    static let bodyShare: CGFloat = 0.3 * 2.28
    /// 画布头顶多留的高度（画布宽的 0.3，也就是 1R），睡觉的 z、限流的汗滴往上飘不会被裁掉。
    /// 引擎把身体画在画布底部的正方形里，所以画布往上长、身体位置不变。
    static let headroom: CGFloat = 0.3
    static func canvasSize(body size: CGFloat) -> CGSize {
        let w = size / bodyShare
        return CGSize(width: w, height: w * (1 + headroom))
    }
    /// 引擎按每个显示帧走一步 0.05 调的手感（Coucou MochiFrameClock）。低帧率时一帧补走 3 步，速度不变。
    static let stepDt = 0.05
    static let slowSteps = 3
    /// minimumInterval 比目标帧间隔短 10%：显示帧有抖动，正好 1/60 会隔一帧才画一次。
    /// @see https://developer.apple.com/documentation/swiftui/timelineschedule/animation(minimuminterval:paused:)
    static func interval(fps: Double) -> TimeInterval { 0.9 / fps }

    @StateObject private var engine = DundunEngine()
    @ObservedObject private var director = DundunDirector.shared
    /// @see https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dizzyUntil = Date.distantPast
    @State private var anchor = ScreenAnchor()
    /// 所在窗口被收起（orderOut）或完全挡住时停画。窗口收起后 SwiftUI 不会移除里面的视图，
    /// TimelineView 照样每帧刷新（实测面板收起后仍占约 22% CPU），所以要自己看窗口的遮挡状态。
    /// @see https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property
    /// @see https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification
    @State private var windowVisible = true

    var body: some View {
        // 不在面板里、底色是 idle（犯困也从它来）时只有呼吸和眨眼，20fps 足够
        let slow = !interactive && state == .idle
        let canvas = Self.canvasSize(body: size)
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                TimelineView(.animation(minimumInterval: Self.interval(fps: slow ? 20 : 60), paused: director.paused || !windowVisible)) { timeline in
                    let date = timeline.date
                    Canvas { context, canvasSize in
                        render(at: date, steps: slow ? Self.slowSteps : 1, context: context, size: canvasSize)
                    }
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(y: (canvas.width - canvas.height) / 2)
                }
                .allowsHitTesting(false)
            }
            .background { ScreenAnchorView(anchor: anchor, windowVisible: $windowVisible) }
            // @see https://developer.apple.com/documentation/swiftui/view/onreceive(_:perform:)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                guard let window = note.object as? NSWindow, window === anchor.view?.window else { return }
                windowVisible = window.occlusionState.contains(.visible)
            }
            .contentShape(Rectangle())
            .onTapGesture { if interactive { engine.slap() } }
            // @see https://developer.apple.com/documentation/swiftui/view/onhover(perform:)
            .onHover { inside in if interactive { engine.tgEs = inside ? 1.08 : 1 } }
            .onAppear {
                engine.showsShield = size >= 30
                engine.onDizzy = { dizzyUntil = Date().addingTimeInterval(3.3) }
                switch emote {
                case .none: break
                case .cheer: engine.triggerEmote(.happy)
                case .beaming: engine.setPermanentEmote(.happy)
                }
                MachineVitals.shared.retain()
            }
            .onDisappear { MachineVitals.shared.release() }
            .accessibilityElement()
            .accessibilityLabel("盾盾")
    }

    private func render(at date: Date, steps: Int, context: GraphicsContext, size: CGSize) {
        engine.reduceMotion = reduceMotion
        engine.setState(DundunState.shown(base: state, dizzy: date < dizzyUntil, drowsy: director.drowsy))
        engine.moodTarget = MachineVitals.shared.mood
        (engine.lookX, engine.lookY) = interactive && !reduceMotion ? anchor.look() : (0, 0)
        for _ in 0..<steps { engine.update(dt: Self.stepDt) }
        engine.draw(context: context, size: size)
        engine.drawExtras(context: context, size: size)
    }
}

/// 盾盾在屏幕上的位置和所在窗口。面板不是 key window，SwiftUI 的 hover 只在视图范围内有坐标，
/// 眼睛要跟着整块屏幕上的鼠标走，只能拿全局鼠标位置和视图的屏幕坐标比。
@MainActor
final class ScreenAnchor {
    fileprivate(set) weak var view: NSView?

    /// 鼠标相对盾盾的方向，两轴各压到 -1...1（向右、向上为正）
    /// @see https://developer.apple.com/documentation/appkit/nsevent/mouselocation
    /// @see https://developer.apple.com/documentation/appkit/nswindow/converttoscreen(_:)
    func look() -> (CGFloat, CGFloat) {
        guard let view, let window = view.window else { return (0, 0) }
        let c = window.convertToScreen(view.convert(view.bounds, to: nil))
        let m = NSEvent.mouseLocation
        return (tanh((m.x - c.midX) / 260), tanh((m.y - c.midY) / 200))
    }
}

/// 面板的视图在挂进窗口之前就建好了（onAppear 时还没有窗口），而一直没显示过的窗口不会发遮挡变化的通知，
/// 所以第一次读窗口可见与否要等视图真正进了窗口。
private struct ScreenAnchorView: NSViewRepresentable {
    let anchor: ScreenAnchor
    @Binding var windowVisible: Bool

    func makeNSView(context: Context) -> AnchorNSView { AnchorNSView() }
    func updateNSView(_ nsView: AnchorNSView, context: Context) {
        anchor.view = nsView
        nsView.onWindowVisible = { windowVisible = $0 }
    }

    final class AnchorNSView: NSView {
        var onWindowVisible: ((Bool) -> Void)?
        /// @see https://developer.apple.com/documentation/appkit/nsview/viewdidmovetowindow()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowVisible?(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}

/// 所有盾盾共用的两件事：犯困（鼠标久不靠近刘海）和暂停（锁屏、屏幕睡眠时不画）。
@MainActor
final class DundunDirector: ObservableObject {
    static let shared = DundunDirector()

    @Published private(set) var drowsy = false
    @Published private(set) var paused = false

    static let nearDistance: CGFloat = 150
    static let drowsyAfter: TimeInterval = 120

    private var notchRect: () -> NSRect = { .zero }
    private var lastNear = Date()
    private var screensAsleep = false
    private var locked = false
    private var timer: Timer?

    /// App 启动时调用一次，传入刘海在屏幕上的位置
    func start(notchRect: @escaping () -> NSRect) {
        guard timer == nil else { return }
        self.notchRect = notchRect
        lastNear = Date()
        // @see https://developer.apple.com/documentation/appkit/nsworkspace/notificationcenter
        // @see https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification
        // @see https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DundunDirector.shared.set(asleep: true) }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in DundunDirector.shared.set(asleep: false) }
        }
        // 锁屏没有公开的 API 通知；这两个名字是系统发出的分布式通知，Apple 文档里没有列出。
        // 万一哪个系统版本不再发这两个通知，也只是少了锁屏这一路：熄屏（上面的 screensDidSleep）
        // 和窗口遮挡（windowVisible，看 occlusionState）照样会让 TimelineView 暂停。
        // @see https://developer.apple.com/documentation/foundation/distributednotificationcenter
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in DundunDirector.shared.set(locked: true) }
        }
        dn.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in DundunDirector.shared.set(locked: false) }
        }
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in DundunDirector.shared.checkDrowsy(mouse: NSEvent.mouseLocation, now: Date()) }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func set(asleep: Bool? = nil, locked: Bool? = nil) {
        if let asleep { screensAsleep = asleep }
        if let locked { self.locked = locked }
        let p = screensAsleep || self.locked
        if p != paused { paused = p }
    }

    private func checkDrowsy(mouse: NSPoint, now: Date) {
        if Self.distance(from: mouse, to: notchRect()) <= Self.nearDistance { lastNear = now }
        let d = now.timeIntervalSince(lastNear) > Self.drowsyAfter
        if d != drowsy { drowsy = d }
    }

    /// 点到矩形的距离，点在矩形里为 0
    nonisolated static func distance(from p: NSPoint, to r: NSRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }
}
