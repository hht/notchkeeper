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
import DundunCore

/// 盾盾（dundun-final-spec.md）：正圆身体 + 渐变，没有盾牌。外面只通过 Mascot.swift 的 `MascotRenderable` 用它（AGENTS.md）。
/// 布局占 size×size，正好是身体圆的外框；画布按 §1.1 的比例画在 overlay 里，装饰在右上方出框。
/// size ≤ 24 用 20pt 画法（左耳），更大用 40pt 画法按比例缩放（面板、卡片、设置页）。
/// 每一帧画什么由 DundunCore 的 `DundunPlayer` 按显式时间算（§7、§10、3A）；这里只负责：
/// - 步进帧：Task 睡到 `nextWake` 再 `advance`，帧变了才在 `Transaction(animation: nil)` 里提交一次；静止时什么都不跑。
/// - 过渡窗口（0.3s，进入危险 0.2s）：只在这段时间里开 `TimelineView(.animation)`，≤ 60fps，结束就暂停。
/// - 看不见（窗口收起或被挡住、熄屏、锁屏）：停掉全部计时器，恢复时直接画当前帧（§7.4）。
struct DundunView: MascotRenderable {
    let state: DundunState
    let size: CGFloat
    let emote: MascotEmote
    /// 面板头部那只：能拍（拍一下晕 1.6s）
    let interactive: Bool

    init(state: DundunState, size: CGFloat, emote: MascotEmote = .none, interactive: Bool = false) {
        self.state = state
        self.size = size
        self.emote = emote
        self.interactive = interactive
        let scale = Self.scale(for: size)
        _driver = StateObject(wrappedValue: DundunDriver(scale: scale, look: emote == .beaming ? .finished : state.look, settled: emote == .beaming))
    }

    static func scale(for size: CGFloat) -> DundunScale { size <= 24 ? .small : .large }

    /// 画布相对身体外框（原点 = 身体左上）的位置和大小，§1.1：
    /// 20pt 画布 28×28、身体外框 x 4–24 / y 6.5–26.5；40pt 画布 80×68pt、身体圆心 (36, 45)pt、半径 20
    static func canvasFrame(body size: CGFloat) -> CGRect {
        switch scale(for: size) {
        case .small:
            let k = size / 20
            return CGRect(x: -4 * k, y: -6.5 * k, width: 28 * k, height: 28 * k)
        case .large:
            let k = size / 40
            return CGRect(x: -16 * k, y: -25 * k, width: 80 * k, height: 68 * k)
        }
    }

    /// 拍一下晕多久
    static let dizzyFor: TimeInterval = 1.6
    /// 完成卡、恢复卡出现时开心多久（§3：完成 5.2s 回空闲）
    static let cheerFor: TimeInterval = 5.2

    @StateObject private var driver: DundunDriver
    @ObservedObject private var director = DundunDirector.shared
    /// @see https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dundunLiteral) private var literal
    @Environment(\.dundunTriggerTarget) private var triggerTarget
    @State private var dizzy = false
    @State private var cheering = false
    @State private var appeared = false
    @State private var anchor = ScreenAnchor()
    /// 所在窗口被收起（orderOut）或完全挡住时停画。窗口收起后 SwiftUI 不会移除里面的视图，
    /// 计时器照样会跑，所以要自己看窗口的遮挡状态。
    /// @see https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.property
    /// @see https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification
    @State private var windowVisible = false

    private var look: DundunLook {
        if emote == .beaming || cheering { return .finished }
        return (literal ? state : DundunState.shown(base: state, dizzy: dizzy, drowsy: director.drowsy)).look
    }

    private var visible: Bool { appeared && windowVisible && !director.paused }

    var body: some View {
        let f = Self.canvasFrame(body: size)
        Color.clear
            .frame(width: size, height: size)
            .overlay(alignment: .topLeading) {
                DundunFrameView(driver: driver, size: f.size)
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
                    .allowsHitTesting(false)
            }
            .background { ScreenAnchorView(anchor: anchor, windowVisible: $windowVisible) }
            // @see https://developer.apple.com/documentation/swiftui/view/onreceive(_:perform:)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                guard let window = note.object as? NSWindow, window === anchor.view?.window else { return }
                windowVisible = window.occlusionState.contains(.visible)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard interactive, !dizzy else { return }
                dizzy = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.dizzyFor))
                    dizzy = false
                }
            }
            // @see https://developer.apple.com/documentation/swiftui/view/onchange(of:initial:_:)
            .onChange(of: reduceMotion, initial: true) { _, on in driver.setReduceMotion(on) }
            .onChange(of: look, initial: true) { _, l in driver.setLook(l) }
            .onChange(of: visible, initial: true) { _, v in driver.setVisible(v) }
            .onAppear {
                driver.screenCenter = { [anchor] in anchor.screenCenter() }
                if let triggerTarget { DundunTriggers.shared.register(driver, label: triggerTarget) }
                if emote == .cheer && !cheering {
                    cheering = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.cheerFor))
                        cheering = false
                    }
                }
                appeared = true
            }
            .onDisappear {
                appeared = false
                DundunTriggers.shared.unregister(driver)
            }
            .accessibilityElement()
            .accessibilityLabel("盾盾")
    }
}

extension DundunState {
    /// 画成哪一种造型（§0 的 12 个状态）。unknown 收起态不显示任何指示，盾盾按空闲画（§0 v2.8）
    var look: DundunLook {
        switch self {
        case .idle, .guardUnknown: return .idle
        case .sleeping: return .sleeping
        case .thinking, .ratelimit: return .thinking
        case .working, .searching: return .working
        case .question, .approval: return .question
        case .finished: return .finished
        case .error: return .error
        case .interrupted: return .interrupted
        case .dizzy: return .dizzy
        case .guardMismatch: return .mismatch
        case .guardStale: return .stale
        case .guardViolated: return .danger
        }
    }
}

/// 画布：平时只画提交过的那一帧；过渡窗口里交给 TimelineView 每个显示帧（≤ 60fps）按时刻算一帧。
/// minimumInterval 比 1/60 短 10%：显示帧有抖动，正好 1/60 会隔一帧才画一次；120Hz 屏上照样隔帧取，最多 60fps。
/// 不在过渡里时 paused，TimelineView 不再更新。
/// @see https://developer.apple.com/documentation/swiftui/timelineschedule/animation(minimuminterval:paused:)
struct DundunFrameView: View {
    @ObservedObject var driver: DundunDriver
    let size: CGSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.9 / 60, paused: !driver.animating)) { timeline in
            DundunPaint(render: driver.animating ? driver.render(at: timeline.date) : driver.shown, scale: driver.scale, size: size)
                .equatable()
        }
    }
}

/// 一帧的画。Equatable：帧没变就不重画（§7.2），driver 别的属性变了也不会连带重画
/// @see https://developer.apple.com/documentation/swiftui/view/equatable()
/// @see https://developer.apple.com/documentation/swiftui/canvas
struct DundunPaint: View, Equatable {
    let render: DundunRender
    let scale: DundunScale
    let size: CGSize

    static func base(_ scale: DundunScale) -> CGSize { scale == .small ? CGSize(width: 28, height: 28) : CGSize(width: 80, height: 68) }

    var body: some View {
        Canvas { context, _ in
            let t0 = DundunStats.threadCPU()
            var ctx = context
            let b = Self.base(scale)
            ctx.scaleBy(x: size.width / b.width, y: size.height / b.height)
            DundunPainter.draw(render, scale: scale, in: ctx)
            DundunStats.shared.drew(since: t0)
        }
    }
}

/// 读鼠标位置。NSEvent.mouseLocation 只是查询当前位置，不监听事件，不需要辅助功能权限；
/// 要权限的是全局事件监听（而且只限键盘事件）。
/// @see https://developer.apple.com/documentation/appkit/nsevent/mouselocation
/// @see https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
@MainActor
enum DundunMouse {
    /// CPU 测量（DEBUG）换成合成的位置，绝不动真鼠标
    static var location: () -> CGPoint = { NSEvent.mouseLocation }
}

/// 一只盾盾的调度：持有 DundunPlayer，按它给的时刻醒来、提交帧、采样鼠标
@MainActor
final class DundunDriver: ObservableObject {
    @Published private(set) var shown: DundunRender
    /// 在过渡窗口里（TimelineView 只在这时候跑）
    @Published private(set) var animating = false
    private(set) var player: DundunPlayer
    var scale: DundunScale { player.scale }
    var screenCenter: () -> CGPoint? = { nil }
    var onReasonsChange: (() -> Void)?

    private var visible = false
    private var task: Task<Void, Never>?
    private var wake: Double?
    private var mouseTimer: Timer?
    private var reasons: [String?] = []

    static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    /// settled：一开始就停在这个状态的停留帧（「关于」页一直开心）
    init(scale: DundunScale, look: DundunLook, settled: Bool = false) {
        let t = Self.now()
        var p = DundunPlayer(scale: scale, look: look, at: settled ? t - 60 : t, seed: UInt64.random(in: 1...UInt64.max))
        p.setVisible(false, at: t)
        player = p
        shown = p.render(at: t)
    }

    deinit {
        task?.cancel()
        mouseTimer?.invalidate()
    }

    func render(at date: Date) -> DundunRender { player.render(at: date.timeIntervalSinceReferenceDate) }

    func setLook(_ l: DundunLook) { player.setLook(l, at: Self.now()); pump() }
    func setReduceMotion(_ on: Bool) { player.setReduceMotion(on, at: Self.now()); pump() }
    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        player.setVisible(on, at: Self.now())
        pump()
    }

    // MARK: 「触发小动作」

    func microDisabledReason() -> String? {
        visible ? player.microDisabledReason(at: Self.now()) : "现在看不见（窗口收起、被挡住或刘海展开着）"
    }
    func blinkDisabledReason() -> String? {
        visible ? player.blinkDisabledReason(at: Self.now()) : "现在看不见（窗口收起、被挡住或刘海展开着）"
    }
    @discardableResult func trigger(_ m: DundunMicro) -> Bool {
        guard visible, player.trigger(m, at: Self.now()) else { return false }
        pump()
        return true
    }
    @discardableResult func triggerBlink() -> Bool {
        guard visible, player.triggerBlink(at: Self.now()) else { return false }
        pump()
        return true
    }

    // MARK: 调度

    private func pump() {
        let t = Self.now()
        if let c = player.advance(to: t) {
            // 显式提交：不带任何隐式动画（Jason 的约定：时间只由 DundunCore 决定）
            // @see https://developer.apple.com/documentation/swiftui/withtransaction(_:_:)
            // @see https://developer.apple.com/documentation/swiftui/transaction/init(animation:)
            withTransaction(Transaction(animation: nil)) { shown = c.render }
            DundunStats.shared.committed(c.kind)
        }
        let inTransition = player.transition?.isActive(at: t) ?? false
        if inTransition != animating {
            withTransaction(Transaction(animation: nil)) { animating = inTransition }
        }
        schedule(at: inTransition ? player.transition?.end : player.nextWake(after: t))
        updateMouse()
        let r = DundunMicro.allCases.map { _ in microDisabledReason() } + [blinkDisabledReason()]
        if r != reasons {
            reasons = r
            onReasonsChange?()
        }
    }

    /// 睡到下一次要变的时刻。§10 允许 Task.sleep(until:) 代替 TimelineView(.explicit)：
    /// 环顾、眨眼、小动作是随机抽的，抽中的时刻要在醒来那一刻改调度，显式日期表做不到
    /// @see https://developer.apple.com/documentation/swift/task/sleep(for:tolerance:clock:)
    private func schedule(at next: Double?) {
        guard next != wake || task == nil else { return }
        task?.cancel()
        task = nil
        wake = next
        guard let next else { return }
        task = Task { @MainActor [weak self] in
            let delay = next - DundunDriver.now()
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.wake = nil
            self.pump()
        }
    }

    /// 只在空闲、看得见、没开减弱动态效果时 10Hz 采样鼠标（§4.1、§7.4）；熄屏和锁屏时 visible 已经是 false
    /// @see https://developer.apple.com/documentation/foundation/timer
    private func updateMouse() {
        let want = visible && player.look == .idle && !player.reduceMotion
        if want && mouseTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                // 加在主运行循环上，回调就在主线程
                // @see https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:)
                MainActor.assumeIsolated { self?.sampleMouse() }
            }
            RunLoop.main.add(timer, forMode: .common)
            mouseTimer = timer
        } else if !want, let timer = mouseTimer {
            timer.invalidate()
            mouseTimer = nil
        }
    }

    private func sampleMouse() {
        let t = Self.now()
        guard player.wantsMouse(at: t), let c = screenCenter() else { return }
        let m = DundunMouse.location()
        DundunStats.shared.sampled()
        player.mouse(CGPoint(x: m.x - c.x, y: c.y - m.y), at: t)
        pump()
    }

    var isSamplingMouse: Bool { mouseTimer != nil }
}

/// 「状态测试」里的「触发小动作」：发给左耳（20pt）和预览（40pt）两只盾盾，各播一次。只在内存里
@MainActor
final class DundunTriggers: ObservableObject {
    static let shared = DundunTriggers()

    enum Action: String, CaseIterable, Identifiable {
        case turn, pitch, roll, blink
        var id: Self { self }
        var title: String {
            switch self {
            case .turn: return "转身"
            case .pitch: return "上下翻"
            case .roll: return "左右翻"
            case .blink: return "眨眼"
            }
        }
        var micro: DundunMicro? {
            switch self {
            case .turn: return .turn
            case .pitch: return .pitch
            case .roll: return .roll
            case .blink: return nil
            }
        }
    }

    struct Target {
        let label: String
        weak var driver: DundunDriver?
    }

    /// 任一目标的「能不能播」变了就加一，面板跟着刷新
    @Published private(set) var revision = 0
    private(set) var targets: [Target] = []

    func register(_ d: DundunDriver, label: String) {
        targets.removeAll { $0.driver == nil || $0.driver === d }
        targets.append(Target(label: label, driver: d))
        targets.sort { $0.label < $1.label }
        d.onReasonsChange = { [weak self] in self?.revision += 1 }
        revision += 1
    }

    func unregister(_ d: DundunDriver) {
        d.onReasonsChange = nil
        targets.removeAll { $0.driver == nil || $0.driver === d }
        revision += 1
    }

    func reason(_ a: Action, for d: DundunDriver) -> String? {
        a.micro == nil ? d.blinkDisabledReason() : d.microDisabledReason()
    }

    /// 能播的目标各播一次；返回播了几只
    @discardableResult
    func fire(_ a: Action) -> Int {
        targets.compactMap(\.driver).filter { d in
            if let m = a.micro { return d.trigger(m) }
            return d.triggerBlink()
        }.count
    }
}

/// 谁参加「触发小动作」：nil 不参加，否则是面板里显示的名字
private struct DundunTriggerTargetKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var dundunTriggerTarget: String? {
        get { self[DundunTriggerTargetKey.self] }
        set { self[DundunTriggerTargetKey.self] = newValue }
    }
}

/// 重画计数（CPU 测量和自检用）。Canvas 的绘制闭包不保证在哪个隔离域里调，所以用锁
final class DundunStats: @unchecked Sendable {
    static let shared = DundunStats()
    private let lock = NSLock()
    private var counts = (draws: 0, steps: 0, transitions: 0, samples: 0)
    private var drawCPU = 0.0

    /// 本线程用掉的 CPU 秒数（POSIX clock_gettime，`man 3 clock_gettime`），只用来量画一帧花多少 CPU
    static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    func drew(since t0: Double) {
        let dt = Self.threadCPU() - t0
        lock.withLock { counts.draws += 1; drawCPU += dt }
    }
    var drawSeconds: Double { lock.withLock { drawCPU } }
    func committed(_ k: DundunCommit.Kind) { lock.withLock { if k == .step { counts.steps += 1 } else { counts.transitions += 1 } } }
    func sampled() { lock.withLock { counts.samples += 1 } }
    var snapshot: (draws: Int, steps: Int, transitions: Int, samples: Int) { lock.withLock { counts } }
}

/// 「状态测试」强制显示时为 true：照给的状态画，不让晕、犯困盖掉（强制 idle 不会自己睡着）
/// @see https://developer.apple.com/documentation/swiftui/environmentkey
private struct DundunLiteralKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dundunLiteral: Bool {
        get { self[DundunLiteralKey.self] }
        set { self[DundunLiteralKey.self] = newValue }
    }
}

/// 盾盾在屏幕上的位置和所在窗口。面板不是 key window，SwiftUI 的 hover 只在视图范围内有坐标，
/// 眼睛要跟着整块屏幕上的鼠标走，只能拿全局鼠标位置和视图的屏幕坐标比。
@MainActor
final class ScreenAnchor {
    fileprivate(set) weak var view: NSView?

    /// 身体圆心的屏幕坐标（锚点视图就是身体外框，原点在左下、y 向上）
    /// @see https://developer.apple.com/documentation/appkit/nswindow/converttoscreen(_:)
    func screenCenter() -> CGPoint? {
        guard let view, let window = view.window else { return nil }
        let r = window.convertToScreen(view.convert(view.bounds, to: nil))
        return CGPoint(x: r.midX, y: r.midY)
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
        // 和窗口遮挡（windowVisible，看 occlusionState）照样会让盾盾停掉所有计时器。
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

// MARK: - 右耳（dundun-final-spec.md §2.4、ear-dundun-spec.md）

/// 错误没看过：进入 error 起 30 分钟内右耳亮红点，展开过刘海（看过面板）就灭（§2.4「未读」）
@MainActor
final class DundunEarState: ObservableObject {
    static let shared = DundunEarState()
    static let unreadFor: TimeInterval = 30 * 60

    @Published private(set) var errorUnread = false
    private var expiry: Task<Void, Never>?
    private var last: DundunLook?

    /// 耳朵每次出现都会报一次当前状态；只有真的从别的状态进入 error 才算新的未读
    func entered(_ look: DundunLook) {
        defer { last = look }
        guard look == .error, last != .error else { return }
        errorUnread = true
        expiry?.cancel()
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.unreadFor))
            guard !Task.isCancelled else { return }
            self?.errorUnread = false
        }
    }

    func markRead() {
        expiry?.cancel()
        expiry = nil
        errorUnread = false
    }
}

/// 右耳的指示：44 宽、刘海高的画布，圆点圆心 (44 − 17.5, H/2)
struct DundunEarView: View {
    let look: DundunLook
    let height: CGFloat

    @StateObject private var driver = EarDriver()
    @ObservedObject private var director = DundunDirector.shared
    @ObservedObject private var earState = DundunEarState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var anchor = ScreenAnchor()
    @State private var windowVisible = false
    @State private var appeared = false

    private var indicator: EarIndicator { .for(look, errorUnread: earState.errorUnread) }
    private var visible: Bool { appeared && windowVisible && !director.paused }

    var body: some View {
        let w = NotchLayout.earWidth
        EarFrameView(driver: driver, dot: CGPoint(x: w - NotchLayout.earDotInset, y: height / 2),
                     dots: CGPoint(x: w - NotchLayout.earDotInset - NotchLayout.earDotsShift, y: height / 2))
            .frame(width: w, height: height)
            .background { ScreenAnchorView(anchor: anchor, windowVisible: $windowVisible) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
                guard let window = note.object as? NSWindow, window === anchor.view?.window else { return }
                windowVisible = window.occlusionState.contains(.visible)
            }
            .onChange(of: reduceMotion, initial: true) { _, on in driver.setReduceMotion(on) }
            .onChange(of: indicator, initial: true) { _, i in driver.set(i) }
            .onChange(of: visible, initial: true) { _, v in driver.setVisible(v) }
            .onAppear { appeared = true }
            .onDisappear { appeared = false }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct EarFrameView: View {
    @ObservedObject var driver: EarDriver
    let dot: CGPoint
    let dots: CGPoint

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.9 / 60, paused: !driver.animating)) { timeline in
            EarPaint(render: driver.animating ? driver.render(at: timeline.date) : driver.shown, dot: dot, dots: dots)
                .equatable()
        }
    }
}

private struct EarPaint: View, Equatable {
    let render: EarRender
    let dot: CGPoint
    let dots: CGPoint

    var body: some View {
        Canvas { ctx, _ in
            guard !render.layers.isEmpty else { return }
            let t0 = DundunStats.threadCPU()
            EarPainter.draw(render, dotCenter: dot, dotsCenter: dots, in: ctx)
            DundunStats.shared.drew(since: t0)
        }
    }
}

/// 右耳的调度：同 DundunDriver，只在 0.2s 过渡里开 TimelineView，危险脉冲按 nextRedraw 步进
@MainActor
final class EarDriver: ObservableObject {
    @Published private(set) var shown = EarRender(layers: [])
    @Published private(set) var animating = false
    private var player = DundunEarPlayer()
    private var task: Task<Void, Never>?
    private var wake: Double?

    init() { player.setVisible(false, at: DundunDriver.now()) }
    deinit { task?.cancel() }

    func render(at date: Date) -> EarRender { player.render(at: date.timeIntervalSinceReferenceDate) }
    func set(_ i: EarIndicator) { player.set(i, at: DundunDriver.now()); pump() }
    func setReduceMotion(_ on: Bool) { player.setReduceMotion(on, at: DundunDriver.now()); pump() }
    func setVisible(_ on: Bool) {
        guard on != player.visible else { return }
        player.setVisible(on, at: DundunDriver.now())
        pump()
    }

    private func pump() {
        let t = DundunDriver.now()
        player.advance(to: t)
        let inTransition = player.visible && (player.transitionEnd.map { t < $0 } ?? false)
        let r = player.render(at: t)
        withTransaction(Transaction(animation: nil)) {
            if r != shown { shown = r }
            if inTransition != animating { animating = inTransition }
        }
        let next = !player.visible ? nil : inTransition ? player.transitionEnd : player.nextRedraw(after: t)
        guard next != wake || task == nil else { return }
        task?.cancel()
        task = nil
        wake = next
        guard let next else { return }
        task = Task { @MainActor [weak self] in
            let delay = next - DundunDriver.now()
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.wake = nil
            self.pump()
        }
    }
}
