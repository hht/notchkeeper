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
// Modified for Notchkeeper. 本文件有一部分是从带这份声明的旧 Mascot/DundunView.swift 原样搬来的（犯困、熄屏锁屏），
// 按 CLAUDE.md 的过渡期规则保留，第 4 步重写这些代码时一起删掉。

import AppKit
import QuartzCore
import MascotCore

/// 所有盾盾共用的一份：唯一的时钟（眨眼、空闲小动作，左耳和面板同步）、鼠标、犯困、熄屏锁屏暂停。
/// 不知道盾盾怎么画、动作长什么样；什么时候做什么由 `IdleDirector` 定，这里只按它给的时刻醒来、把提示发给看得见的盾盾。
/// 一只都看不见、或者熄屏锁屏时，时钟和犯困计时器都停掉（docs/mascot.md §5「渲染」）。
@MainActor
final class MascotDirector: ObservableObject {
    static let shared = MascotDirector()

    @Published private(set) var drowsy = false
    /// 熄屏或锁屏。没有视图读它，所以不发布：每只盾盾由 `set(asleep:locked:)` 逐个通知
    private(set) var paused = false

    static let nearDistance: CGFloat = 150
    static let drowsyAfter: TimeInterval = 120

    private var notchRect: () -> NSRect = { .zero }
    private var lastNear = Date()
    private var screensAsleep = false
    private var locked = false
    private var drowsyTimer: Timer?

    private var views: [Weak] = []
    private var idle = IdleDirector(seed: UInt64.random(in: 1...UInt64.max), now: CACurrentMediaTime())
    private var clock: Timer?
    /// 鼠标停下后这一刻眼睛回正；nil = 没在看鼠标
    private var restAt: CFTimeInterval?
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
        // @see https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification
        // @see https://developer.apple.com/documentation/appkit/nsworkspace/screensdidwakenotification
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MascotDirector.shared.set(asleep: true) }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MascotDirector.shared.set(asleep: false) }
        }
        // 锁屏没有公开的 API 通知；这两个名字是系统发出的分布式通知，Apple 文档里没有列出。
        // 万一哪个系统版本不再发，也只是少了锁屏这一路：熄屏和窗口遮挡照样会让盾盾停下。
        // @see https://developer.apple.com/documentation/foundation/distributednotificationcenter
        let dn = DistributedNotificationCenter.default()
        dn.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MascotDirector.shared.set(locked: true) }
        }
        dn.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MascotDirector.shared.set(locked: false) }
        }
    }

    private func set(asleep: Bool? = nil, locked: Bool? = nil) {
        if let asleep { screensAsleep = asleep }
        if let locked { self.locked = locked }
        let p = screensAsleep || self.locked
        guard p != paused else { return }
        paused = p
        views.forEach { $0.view?.refreshActive() }
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

    // MARK: 盾盾登记

    func attach(_ v: MascotLayerView) {
        views.removeAll { $0.view == nil || $0.view === v }
        views.append(Weak(view: v))
    }

    func detach(_ v: MascotLayerView) {
        views.removeAll { $0.view == nil || $0.view === v }
        activityChanged()
    }

    /// 有盾盾变得看得见或看不见、熄屏锁屏：时钟和犯困计时器跟着开停
    func activityChanged() {
        let wasRunning = clock != nil
        clock?.invalidate()
        clock = nil
        let on = !live.isEmpty
        if on != (drowsyTimer != nil) {
            drowsyTimer?.invalidate()
            drowsyTimer = nil
            if on {
                let t = Timer(timeInterval: 2, repeats: true) { _ in
                    MainActor.assumeIsolated { MascotDirector.shared.checkDrowsy(mouse: NSEvent.mouseLocation, now: Date()) }
                }
                t.tolerance = 0.5
                RunLoop.main.add(t, forMode: .common)
                drowsyTimer = t
            }
        }
        guard on else { return }
        if !wasRunning { idle.resume(at: CACurrentMediaTime()) }
        schedule()
    }

    // MARK: 时钟

    private func schedule() {
        let wake = min(idle.nextWake, restAt ?? .infinity)
        let t = Timer(fire: Date(timeIntervalSinceNow: max(0, wake - CACurrentMediaTime())), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { MascotDirector.shared.tick() }
        }
        // 眨眼、小动作差几十毫秒看不出来，让系统合并唤醒
        // @see https://developer.apple.com/documentation/foundation/timer/tolerance
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    private func tick() {
        clock = nil
        let now = CACurrentMediaTime()
        let views = live
        // 看得见的盾盾没走 refreshActive 就没了：时钟和犯困计时器一起停
        guard !views.isEmpty else { return activityChanged() }
        if let r = restAt, now >= r {
            restAt = nil
            // 看不见的也要回正：它们只记下目标，回来时不会斜眼看着旧位置
            all.forEach { $0.follow(mouse: nil) }
        }
        for cue in idle.cues(at: now) { views.forEach { $0.perform(cue) } }
        schedule()
    }

    /// 「播放动作」：看得见的盾盾各播一次，不管当前造型
    func play(_ cue: Cue) {
        live.forEach { $0.perform(cue, force: true) }
    }

    // MARK: 鼠标

    /// 关掉时眼睛回正、不再探头，鼠标事件直接丢掉
    func setFollowsMouse(_ on: Bool) {
        guard on != followsMouse else { return }
        followsMouse = on
        guard !on else { return }
        restAt = nil
        for v in all {
            v.follow(mouse: nil)
            v.setPeeking(false)
        }
    }

    /// NotchController 的全局鼠标监听转过来（屏幕坐标）。盾盾看鼠标、鼠标在刘海上时探头；
    /// 有盾盾在看鼠标时不做小动作，鼠标停下 4s 后回正（docs/mascot.md §5「跟随鼠标」）
    func mouseMoved(to p: NSPoint) {
        guard followsMouse else { return }
        let views = live
        guard !views.isEmpty else { return }
        let peek = Self.distance(from: p, to: notchRect()) == 0
        for v in views {
            v.follow(mouse: p)
            v.setPeeking(peek)
        }
        guard views.contains(where: \.isLooking) else { return }
        let now = CACurrentMediaTime()
        let wasResting = restAt == nil
        restAt = now + Choreography.gazeRestAfter
        idle.postponeMotions(until: now + Choreography.gazeRestAfter)
        if wasResting {
            clock?.invalidate()
            schedule()
        }
    }
}
