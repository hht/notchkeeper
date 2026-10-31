import AppKit
import QuartzCore
import MascotCore

/// 所有 Pip 共用的一份：登记看得见的 Pip、按 `MascotClock` 给的时刻醒来把提示发给它们、转发鼠标、熄屏锁屏时停下。
/// 什么时候眨眼、做小动作、回正、犯困、晕完都由 `MascotClock` 定；不知道 Pip 怎么画、动作长什么样。
/// 一只都看不见、或者熄屏锁屏时，时钟停掉（docs/mascot.md §5「渲染」）。
@MainActor
final class MascotDirector: ObservableObject {
    static let shared = MascotDirector()

    /// `MascotClock` 的镜像，变了才发布：视图按它们叠晕和睡着（`shown`）
    @Published private(set) var drowsy = false
    @Published private(set) var dizzy = false
    /// 熄屏或锁屏。没有视图读它，所以不发布：每只 Pip 由 `refreshActive` 逐个看
    var paused: Bool { !away.isEmpty }
    /// 熄屏或锁屏变了：卡片队列跟着停、跟着放（docs/ui.md「卡片」8）
    var onPausedChange: ((Bool) -> Void)?

    /// 鼠标离刘海这么近算靠近（不犯困）
    static let nearDistance: CGFloat = 150

    private enum Away { case screensAsleep, locked }
    private var away: Set<Away> = []

    private var notchRect: () -> NSRect = { .zero }
    private var views: [Weak] = []
    private var clock = MascotClock(seed: UInt64.random(in: 1...UInt64.max), now: CACurrentMediaTime())
    private var timer: Timer?
    /// 定时器定在哪一刻醒；nil = 停着
    private var timerAt: CFTimeInterval?
    /// 设置里的「跟随鼠标」
    private var followsMouse = true

    private struct Weak {
        weak var view: MascotLayerView?
    }

    private var all: [MascotFigureView] { views.compactMap { $0.view as? MascotFigureView } }
    private var live: [MascotFigureView] { all.filter(\.active) }

    /// App 启动时调用一次，传入刘海在屏幕上的位置
    func start(notchRect: @escaping () -> NSRect) {
        self.notchRect = notchRect
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        // 锁屏没有公开的通知；com.apple.screenIsLocked / Unlocked 是系统发的分布式通知，Apple 文档没列出。
        // 哪个系统版本不再发，也只是少了锁屏这一路：熄屏和窗口遮挡照样让 Pip 停下
        // @see https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification
        // @see https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification
        // @see https://developer.apple.com/documentation/foundation/distributednotificationcenter
        let sources: [(NotificationCenter, Notification.Name, Away, Bool)] = [
            (ws, NSWorkspace.screensDidSleepNotification, .screensAsleep, true),
            (ws, NSWorkspace.screensDidWakeNotification, .screensAsleep, false),
            (dn, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (dn, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
        ]
        for (center, name, reason, on) in sources {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MascotDirector.shared.set(reason, on) }
            }
        }
    }

    private func set(_ reason: Away, _ on: Bool) {
        let was = paused
        if on { away.insert(reason) } else { away.remove(reason) }
        guard paused != was else { return }
        views.forEach { $0.view?.refreshActive() }
        onPausedChange?(paused)
    }

    /// 实际画哪个造型：晕、睡着叠在给的造型上
    func shown(_ look: Look) -> Look { look.shown(drowsy: drowsy, dizzy: dizzy) }

    /// 点到矩形的距离，点在矩形里为 0
    nonisolated static func distance(from p: NSPoint, to r: NSRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    private func mouseNear(_ p: NSPoint) -> Bool { Self.distance(from: p, to: notchRect()) <= Self.nearDistance }

    // MARK: Pip 登记

    func attach(_ v: MascotLayerView) {
        views.removeAll { $0.view == nil || $0.view === v }
        views.append(Weak(view: v))
    }

    func detach(_ v: MascotLayerView) {
        views.removeAll { $0.view == nil || $0.view === v }
        activityChanged()
    }

    /// 有 Pip 变得看得见或看不见、熄屏锁屏：时钟跟着开停
    func activityChanged() {
        let on = !live.isEmpty
        guard on != (timerAt != nil) else { return }
        if on {
            clock.resume(at: CACurrentMediaTime())
            schedule()
        } else if !clock.dizzy {
            // 晕着先不停（最多再跑 1.6 秒）：这里常在 SwiftUI 更新视图时被调（`playing` 变了），
            // 晕留给到点的 tick 收，镜像的发布就只在定时器回调里
            timer?.invalidate()
            stopClock()
        }
    }

    /// 停时钟。到点的 tick 发现 Pip 都看不见了时晕可能还在：一起收掉（`MascotClock.suspend`），镜像跟着变
    private func stopClock() {
        timer = nil
        timerAt = nil
        clock.suspend()
        clockChanged()
    }

    // MARK: 时钟

    private func schedule() {
        timer?.invalidate()
        let at = clock.nextWake
        let t = Timer(fire: Date(timeIntervalSinceNow: max(0, at - CACurrentMediaTime())), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { MascotDirector.shared.tick() }
        }
        // 眨眼、小动作差几十毫秒看不出来，让系统合并唤醒
        // @see https://developer.apple.com/documentation/foundation/timer/tolerance
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerAt = at
    }

    /// 时钟改完：镜像跟上；在跑并且要早于定好的时刻醒就改定时器（推迟的不用改：到点 tick 会按新的时刻再定）
    private func clockChanged() {
        if drowsy != clock.drowsy { drowsy = clock.drowsy }
        if dizzy != clock.dizzy { dizzy = clock.dizzy }
        if let at = timerAt, clock.nextWake < at { schedule() }
    }

    private func tick() {
        let views = live
        // 看得见的 Pip 没走 refreshActive 就没了：时钟停掉
        guard !views.isEmpty else { return stopClock() }
        let t = clock.tick(now: CACurrentMediaTime(), mouseNear: mouseNear(NSEvent.mouseLocation))
        if t.gazeRested { all.forEach { $0.follow(mouse: nil) } }
        for cue in t.cues { views.forEach { $0.perform(cue) } }
        clockChanged()
        schedule()
    }

    /// 「播放动作」：看得见的 Pip 各播一次，不管当前造型
    func play(_ cue: Cue) {
        live.forEach { $0.perform(cue, force: true) }
    }

    /// 点了面板里的 Pip：晕一会儿
    func poke() {
        clock.poke(now: CACurrentMediaTime())
        clockChanged()
    }

    // MARK: 鼠标

    /// 关掉时眼睛回正、不再探头，之后只看鼠标近不近刘海（犯困）
    func setFollowsMouse(_ on: Bool) {
        guard on != followsMouse else { return }
        followsMouse = on
        guard !on else { return }
        clock.endGaze()
        for v in all {
            v.follow(mouse: nil)
            v.setPeeking(false)
        }
    }

    /// NotchController 的全局鼠标监听转过来（屏幕坐标）。Pip 看鼠标、鼠标在刘海上时探头（docs/mascot.md §5「跟随鼠标」）
    func mouseMoved(to p: NSPoint) {
        var looking = false
        if followsMouse {
            let peek = Self.distance(from: p, to: notchRect()) == 0
            for v in live {
                v.follow(mouse: p)
                v.setPeeking(peek)
                looking = looking || v.isLooking
            }
        }
        clock.mouseMoved(near: mouseNear(p), looking: looking, now: CACurrentMediaTime())
        clockChanged()
    }
}
