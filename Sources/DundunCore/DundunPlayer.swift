import CoreGraphics

// 盾盾的调度器：纯值类型，显式时间（秒，单调时钟），随机数可注入。
// App 只做三件事：在 nextWake 的时刻调 advance、空闲时 10Hz 把鼠标位移喂给 mouse、状态变了调 setLook。
// 状态内部一步一跳（第 7 节第 1 条）；状态之间按 3A 过渡，过渡帧单独统计（3A.5）。

/// 确定性的随机数（测试可复现）
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func uniform(_ a: Double, _ b: Double) -> Double {
        a + (b - a) * Double(next() >> 11) / Double(1 << 53)
    }
}

/// 一次重画
public struct DundunCommit: Equatable, Sendable {
    public enum Kind: Sendable { case step, transition }
    public var time: Double
    public var kind: Kind
    public var render: DundunRender
}

public struct DundunPlayer: Sendable {
    /// 第 8 节：步进重画任意 1s 窗口最多 12 次（过渡帧不算）
    public static let budget = 12
    /// 第 8 节：鼠标不动时空闲任意 1s 窗口最多 8 次（小动作 6 + 紧挨着的一次眨眼 2）
    public static let stillBudget = 8
    /// 4.4：眨眼 110ms
    public static let blinkDuration = 0.11

    public let scale: DundunScale
    public private(set) var look: DundunLook
    public private(set) var reduceMotion = false
    public private(set) var visible = true
    /// 新状态的 0ms（过渡结束时刻，3A.1）
    private var stateStart: Double
    public private(set) var transition: DundunTransition?
    private var transitionEnd = -Double.infinity
    private var rng: SplitMix64

    private var gaze: CGPoint = .zero
    private var pendingGaze: CGPoint?
    private var lastMouse: CGPoint?
    private var lastMove = -Double.infinity
    private var nextLook: Double?
    private var nextBlink: Double?
    private var blinkEnd: Double?
    private var nextMicro: Double?
    private struct Playing: Sendable {
        let kind: DundunMicro
        let start: Double
        let side: CGFloat
    }
    private var micro: Playing?
    private var last: DundunRender?
    private var stepTimes: [Double] = []

    public init(scale: DundunScale, look: DundunLook = .idle, at t: Double, seed: UInt64 = 0x5EED, reduceMotion: Bool = false) {
        self.scale = scale
        self.look = look
        self.reduceMotion = reduceMotion
        stateStart = t
        rng = SplitMix64(seed: seed)
        schedule(from: t)
    }

    private var track: Track { Tracks.track(look, scale) }

    // MARK: 输入

    public mutating func setLook(_ new: DundunLook, at t: Double) {
        guard new != look else { return }
        let snapshot = render(at: t)
        let old = look
        look = new
        micro = nil          // 3A.4：过渡优先，小动作立即中止，不播回正帧
        blinkEnd = nil
        gaze = .zero
        pendingGaze = nil
        lastMouse = nil
        if visible {
            let tr = DundunTransition(from: snapshot, to: new, at: t, scale: scale, reduceMotion: reduceMotion)
            transition = tr
            transitionEnd = tr.end
            stateStart = tr.end
        } else {
            // 7.4：看不见就不播过渡，直接到新状态
            transition = nil
            stateStart = t
        }
        // stale → mismatch 是同一件事升级，不重播 ▲! 闪烁，直接停在停留帧
        if old == .stale && new == .mismatch { stateStart -= Tracks.track(.mismatch, scale).hold }
        // 眨眼计时从过渡结束起重新抽（3A.4）
        schedule(from: max(t, stateStart))
    }

    public mutating func setReduceMotion(_ on: Bool, at t: Double) {
        guard on != reduceMotion else { return }
        reduceMotion = on
        transition = nil
        micro = nil
        blinkEnd = nil
        gaze = .zero
        pendingGaze = nil
        schedule(from: t)
    }

    public mutating func setVisible(_ on: Bool, at t: Double) {
        guard on != visible else { return }
        visible = on
        transition = nil
        micro = nil
        blinkEnd = nil
        lastMouse = nil
        if on { schedule(from: t) }
    }

    /// 只在空闲、看得见、没开减弱动态效果、不在过渡里时采样鼠标（4.1、7.4、第 10 节）
    public func wantsMouse(at t: Double) -> Bool {
        look == .idle && visible && !reduceMotion && !(transition?.isActive(at: t) ?? false)
    }

    /// 10Hz 采样一次。delta = 鼠标相对身体圆心的屏幕位移（pt，+y 向下）
    public mutating func mouse(_ delta: CGPoint, at t: Double) {
        guard wantsMouse(at: t) else { return }
        guard delta != lastMouse else { return }
        lastMouse = delta
        lastMove = t
        let q = Gaze.quantize(delta, scale: scale)
        if q != (pendingGaze ?? gaze) { setGaze(q, at: t) }
    }

    /// 「触发小动作」按钮为什么不能按；nil = 可以
    public func microDisabledReason(at t: Double) -> String? {
        if reduceMotion { return "减弱动态效果打开时不播动画" }
        if look != .idle { return "小动作只在空闲时播" }
        if transition?.isActive(at: t) ?? false { return "正在切换状态" }
        if micro != nil { return "正在播另一个小动作" }
        return nil
    }

    public func blinkDisabledReason(at t: Double) -> String? {
        if reduceMotion { return "减弱动态效果打开时不眨眼" }
        if !look.blinks { return "这个状态不眨眼（只有空闲、工作、等你回答、mismatch 会眨）" }
        if transition?.isActive(at: t) ?? false { return "正在切换状态" }
        if micro != nil { return "小动作期间不眨眼" }
        if t - stateStart < track.hold { return "进入动画播完才眨眼" }
        return nil
    }

    @discardableResult
    public mutating func trigger(_ m: DundunMicro, at t: Double) -> Bool {
        guard microDisabledReason(at: t) == nil else { return false }
        start(m, at: t)
        return true
    }

    @discardableResult
    public mutating func triggerBlink(at t: Double) -> Bool {
        guard blinkDisabledReason(at: t) == nil else { return false }
        blinkEnd = t + Self.blinkDuration
        return true
    }

    // MARK: 输出

    /// t 时刻屏幕上应该是哪一帧
    public func render(at t: Double) -> DundunRender {
        if let tr = transition, tr.isActive(at: t) {
            return tr.render(at: t, target: DundunRender(frame(at: tr.end), scale: scale))
        }
        return DundunRender(frame(at: t), scale: scale)
    }

    /// 步进帧（不含过渡）
    public func frame(at t: Double) -> DundunFrame {
        if reduceMotion {
            let k = Tracks.rest(look, scale)
            return DundunFrame(look: look, dx: k.dx, dy: k.dy, rotation: k.rot, eyes: .shape(look.eyes, lx: 0, ly: 0), deco: k.deco)
        }
        let k = track.key(at: max(0, t - stateStart))
        var dx = k.dx
        var eyes = DundunEyes.shape(look.eyes, lx: gaze.x, ly: gaze.y)
        if let m = micro {
            if m.kind == .peek {
                dx += m.side
                eyes = .shape(look.eyes, lx: m.side, ly: gaze.y)
            } else if let s = Micros.steps(m.kind, scale).last(where: { $0.t <= t - m.start + Track.eps }) {
                eyes = .flip(left: s.left, right: s.right)
            }
        } else if let be = blinkEnd, t < be {
            eyes = .shape(.blink, lx: gaze.x, ly: gaze.y)
        }
        return DundunFrame(look: look, dx: dx, dy: k.dy, rotation: k.rot, eyes: eyes, deco: k.deco)
    }

    /// 推进到 t：处理到期的计时器，帧变了就返回这次重画，没变返回 nil（7.2：同一帧不重画）
    public mutating func advance(to t: Double) -> DundunCommit? {
        guard visible else { return nil }
        process(upTo: t)
        if let tr = transition, !tr.isActive(at: t) { transition = nil }
        let r = render(at: t)
        guard r != last else { return nil }
        last = r
        let kind: DundunCommit.Kind = t <= transitionEnd + Track.eps ? .transition : .step
        if kind == .step { stepTimes.append(t) }
        stepTimes.removeAll { $0 <= t - 1 }
        return DundunCommit(time: t, kind: kind, render: r)
    }

    /// t 之后最早需要醒来的时刻；nil = 静止，什么都不调度（7.6）
    public func nextWake(after t: Double) -> Double? {
        guard visible else { return nil }
        if let tr = transition, let n = tr.nextRedraw(after: t) { return n }
        var c: [Double?] = [nextBlink, blinkEnd, nextLook, nextMicro]
        if !reduceMotion {
            let e = t - stateStart
            c.append(e < 0 ? stateStart : track.nextStep(after: e).map { stateStart + $0 })
        }
        if let m = micro {
            let me = t - m.start
            let times = (m.kind == .peek ? [] : Micros.steps(m.kind, scale).map(\.t)) + [Micros.end(m.kind)]
            c.append(times.first { $0 > me + Track.eps }.map { m.start + $0 })
        }
        if pendingGaze != nil && micro == nil, let oldest = stepTimes.first { c.append(oldest + 1 + 1e-6) }
        return c.compactMap { $0 }.filter { $0 > t + Track.eps }.min()
    }

    /// 当前 1s 窗口里的步进重画次数（测试和状态测试面板用）
    public func stepsInWindow(endingAt t: Double) -> Int { stepTimes.filter { $0 > t - 1 && $0 <= t }.count }

    // MARK: 内部

    private mutating func schedule(from t: Double) {
        let animates = !reduceMotion
        nextBlink = animates && look.blinks ? max(t, stateStart + track.hold) + rng.uniform(3, 7) : nil
        if animates && look == .idle {
            nextLook = t + rng.uniform(2.5, 6)
            nextMicro = t + rng.uniform(20, 40)
        } else {
            nextLook = nil
            nextMicro = nil
        }
    }

    private func canSpend(at t: Double) -> Bool {
        stepTimes.filter { $0 > t - 1 }.count < Self.budget
    }

    /// 空闲时自发的事件（眨眼、环顾、小动作）要再花 cost 次重画：鼠标 1s 内没动过时，
    /// 加上过去 1s 已经画的不能超过 8；鼠标在动时只受每秒 12 次的硬上限
    private func spontaneousFits(_ cost: Int, at t: Double) -> Bool {
        guard look == .idle, t - lastMove >= 1 else { return true }
        // 正在眨的眼还欠一次睁眼重画
        let owed = (blinkEnd.map { $0 > t } ?? false) ? 1 : 0
        return stepTimes.filter { $0 > t - 1 }.count + owed + cost <= Self.stillBudget
    }

    private mutating func setGaze(_ q: CGPoint, at t: Double) {
        // 小动作期间注视顺延；超出每秒预算也顺延到窗口腾出来
        if micro != nil || !canSpend(at: t) {
            pendingGaze = q
        } else {
            gaze = q
            pendingGaze = nil
        }
    }

    private mutating func start(_ m: DundunMicro, at t: Double) {
        var side: CGFloat = 0
        if m == .peek {
            let g = pendingGaze ?? gaze
            side = g.x != 0 ? (g.x < 0 ? -1 : 1) : (rng.next() & 1 == 0 ? -1 : 1)
        }
        micro = Playing(kind: m, start: t, side: side)
        blinkEnd = nil
    }

    /// 按时间顺序处理到期事件
    private mutating func process(upTo t: Double) {
        if transition?.isActive(at: t) ?? false { return }
        while true {
            var due: [(Double, Int)] = []
            if let b = blinkEnd, b <= t { due.append((b, 0)) }
            if let m = micro, m.start + Micros.end(m.kind) <= t { due.append((m.start + Micros.end(m.kind), 1)) }
            if let n = nextBlink, n <= t { due.append((n, 2)) }
            if let n = nextLook, n <= t { due.append((n, 3)) }
            if let n = nextMicro, n <= t { due.append((n, 4)) }
            guard let (time, ev) = due.min(by: { $0.0 < $1.0 }) else { break }
            switch ev {
            case 0:
                blinkEnd = nil
            case 1:
                micro = nil
                if let p = pendingGaze { setGaze(p, at: time) }
            case 2:
                nextBlink = time + rng.uniform(3, 7)
                // 4.4：小动作在播时这一次眨眼跳过
                if micro == nil && spontaneousFits(2, at: time) { blinkEnd = time + Self.blinkDuration }
            case 3:
                nextLook = time + rng.uniform(2.5, 6)
                if time - lastMove > 4 && spontaneousFits(1, at: time) { lookAround(at: time) }
            default:
                let busy = micro != nil || (blinkEnd.map { $0 > time } ?? false)
                let kind = DundunMicro.allCases[Int(rng.next() % 4)]
                if busy || !spontaneousFits(Micros.stepCount(kind, scale), at: time) {
                    // 刚眨过眼 / 刚环顾过：1s 后再试，不丢掉这一次
                    nextMicro = time + 1
                } else {
                    nextMicro = time + rng.uniform(20, 40)
                    start(kind, at: time)
                }
            }
        }
        if let p = pendingGaze, micro == nil, canSpend(at: t) {
            gaze = p
            pendingGaze = nil
        }
    }

    /// 4.2：加权随机换一格，不重复当前格
    private mutating func lookAround(at t: Double) {
        let current = pendingGaze ?? gaze
        let cells = GazeCell.allCases.filter { $0.offset != current }
        let total = cells.reduce(0) { $0 + $1.weight }
        var x = rng.uniform(0, total)
        var pick = cells[cells.count - 1]
        for c in cells {
            if x < c.weight { pick = c; break }
            x -= c.weight
        }
        setGaze(pick.offset, at: t)
    }
}
