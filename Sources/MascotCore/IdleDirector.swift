/// 空闲时盾盾什么时候眨眼、什么时候做哪个小动作。全 App 只有一个，左耳和面板里的盾盾同步。
/// 不知道现在是不是空闲、看不看得见、鼠标在哪（App 决定要不要问它、问到的提示播不播），也不知道动作长什么样（`Choreography`）。
/// 时间和随机数都从参数进来：同一个种子、同一串调用，结果完全一样。
public struct IdleDirector: Sendable {
    private var nextBlink: Double
    private var nextMotion: Double
    private var rng: SplitMix64
    private var last: IdleMotion?

    /// docs/mascot.md §5：眨眼间隔 2.5–6s，15% 连眨两次；小动作每 8–20s 一个
    static let blinkGap = 2.5...6.0
    static let doubleBlink = 0.15
    static let motionGap = 8.0...20.0

    public init(seed: UInt64, now: Double) {
        rng = SplitMix64(seed: seed)
        nextBlink = 0
        nextMotion = 0
        resume(at: now)
    }

    public var nextWake: Double { min(nextBlink, nextMotion) }

    /// 到 now 为止该发的提示；发过的按 now 重新排下一次
    public mutating func cues(at now: Double) -> [Cue] {
        var out: [Cue] = []
        if now >= nextBlink {
            out.append(.blink(double: Double.random(in: 0..<1, using: &rng) < Self.doubleBlink))
            nextBlink = now + Double.random(in: Self.blinkGap, using: &rng)
        }
        if now >= nextMotion {
            let m = pick()
            last = m
            out.append(.idle(m))
            nextMotion = now + Double.random(in: Self.motionGap, using: &rng)
        }
        return out
    }

    /// 鼠标在动、盾盾在看鼠标时不做小动作：停下以后至少再等最短间隔
    public mutating func postponeMotions(until t: Double) {
        nextMotion = max(nextMotion, t + Self.motionGap.lowerBound)
    }

    /// 看不见一段时间后回来：不补发攒下的提示，从现在重新排
    public mutating func resume(at now: Double) {
        nextBlink = now + Double.random(in: Self.blinkGap, using: &rng)
        nextMotion = now + Double.random(in: Self.motionGap, using: &rng)
    }

    /// 按权重抽，不和上一个重复
    private mutating func pick() -> IdleMotion {
        let pool = IdleMotion.allCases.filter { $0 != last }
        var r = Double.random(in: 0..<pool.reduce(0) { $0 + $1.weight }, using: &rng)
        for m in pool {
            r -= m.weight
            if r < 0 { return m }
        }
        return pool[pool.count - 1]
    }
}

public enum Cue: Equatable, Sendable {
    case blink(double: Bool)
    case idle(IdleMotion)
}

/// docs/mascot.md §5 的空闲小动作
public enum IdleMotion: CaseIterable, Sendable {
    /// 东张西望
    case lookAround
    /// 歪头好奇
    case curiousTilt
    /// 侧身探看
    case peekSide
    /// 原地小跳
    case hop
    /// 抖一抖
    case shake
    /// 偶尔转一圈
    case spin

    /// 权重，合计 100：转一圈约 5%
    var weight: Double {
        switch self {
        case .lookAround: return 30
        case .curiousTilt: return 20
        case .peekSide, .hop, .shake: return 15
        case .spin: return 5
        }
    }
}

/// 可复现的随机数（SplitMix64）
/// @see https://prng.di.unimi.it/splitmix64.c
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
