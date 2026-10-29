import CoreGraphics
@testable import DundunCore

/// 模拟 App 的驱动：只在 nextWake 的时刻醒来，空闲时按 10Hz 网格采样鼠标
struct Sim {
    var player: DundunPlayer
    var commits: [DundunCommit] = []
    var t: Double

    init(_ p: DundunPlayer, at t: Double) {
        player = p
        self.t = t
        if let c = player.advance(to: t) { commits.append(c) }
    }

    /// 跑到 end；mouse 给出每次采样的鼠标位移；switches 是 (时刻, 新状态)
    mutating func run(until end: Double, mouse: ((Double) -> CGPoint)? = nil, switches: [(Double, DundunLook)] = [], wakes: inout Int) {
        var pending = switches.sorted { $0.0 < $1.0 }
        while t < end {
            var next = player.nextWake(after: t) ?? .infinity
            if mouse != nil && player.wantsMouse(at: t) {
                let k = (t * 10 + 1e-6).rounded(.down) + 1
                next = min(next, k / 10)
            }
            if let s = pending.first { next = min(next, s.0) }
            guard next <= end else { t = end; break }
            t = next
            wakes += 1
            if let s = pending.first, s.0 <= t + 1e-12 {
                pending.removeFirst()
                player.setLook(s.1, at: t)
            }
            if let mouse, player.wantsMouse(at: t) { player.mouse(mouse(t), at: t) }
            if let c = player.advance(to: t) { commits.append(c) }
        }
    }

    mutating func run(until end: Double, mouse: ((Double) -> CGPoint)? = nil, switches: [(Double, DundunLook)] = []) {
        var w = 0
        run(until: end, mouse: mouse, switches: switches, wakes: &w)
    }

    func steps(in range: ClosedRange<Double>) -> [DundunCommit] {
        commits.filter { $0.kind == .step && range.contains($0.time) }
    }

    func transitions(in range: ClosedRange<Double>) -> [DundunCommit] {
        commits.filter { $0.kind == .transition && range.contains($0.time) }
    }

    /// 任意 1s 窗口里步进重画的最大次数
    func maxWindow(from: Double = -.infinity) -> Int {
        let ts = commits.filter { $0.kind == .step && $0.time >= from }.map(\.time)
        var best = 0
        for (i, a) in ts.enumerated() {
            best = max(best, ts[i...].prefix { $0 < a + 1 - 1e-9 }.count)
        }
        return best
    }
}

/// 进入空闲并让过渡走完、不触发任何随机事件的玩家
func settledIdle(_ scale: DundunScale, seed: UInt64 = 1) -> (DundunPlayer, Double) {
    var p = DundunPlayer(scale: scale, look: .idle, at: 0, seed: seed)
    _ = p.advance(to: 0)
    return (p, 0.01)
}
