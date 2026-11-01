/// 回答：所有 Pip 共用的时钟下一次什么时候醒、醒来做什么——眨眼和空闲小动作（`IdleDirector`）、鼠标停下后注视回正、
/// 鼠标久不靠近刘海就犯困、点一下晕一会儿（docs/mascot.md §2、§5）。
/// 不知道鼠标在屏幕哪儿（App 说它近不近、Pip 在不在看它）、Pip 看不看得见（看不见时 App 不 tick、先 `suspend`，鼠标照样告诉它：犯困要清）。
/// 时间是单调的秒数，从参数进来；App 按 `nextWake` 起一个定时器，到点调 `tick`
public struct MascotClock: Sendable {
    /// 鼠标这么久没靠近刘海就睡着（docs/mascot.md §2）
    public static let drowsyAfter = 120.0
    /// 点一下晕这么久
    public static let dizzyFor = 1.6

    public private(set) var drowsy = false
    public var dizzy: Bool { dizzyUntil != nil }

    private var idle: IdleDirector
    private var lastNear: Double
    private var dizzyUntil: Double?
    /// 鼠标停下后这一刻眼睛回正；nil = 没在看鼠标
    private var restAt: Double?

    public init(seed: UInt64, now: Double) {
        idle = IdleDirector(seed: seed, now: now)
        lastNear = now
    }

    public var nextWake: Double {
        min(idle.nextWake, restAt ?? .infinity, dizzyUntil ?? .infinity, drowsy ? .infinity : lastNear + Self.drowsyAfter)
    }

    public struct Tick: Equatable, Sendable {
        public var cues: [Cue]
        /// 这一刻该回正：看不见的 Pip 也要回正，回来时不会斜眼看着旧位置
        public var gazeRested: Bool
    }

    /// mouseNear：鼠标此刻在刘海附近。鼠标一直停在那儿不动就没有移动事件，靠这里续上
    public mutating func tick(now: Double, mouseNear: Bool) -> Tick {
        if mouseNear { approached(now) }
        if !drowsy, now >= lastNear + Self.drowsyAfter { drowsy = true }
        if let d = dizzyUntil, now >= d { dizzyUntil = nil }
        var rested = false
        if let r = restAt, now >= r {
            restAt = nil
            rested = true
        }
        return Tick(cues: idle.cues(at: now), gazeRested: rested)
    }

    /// near：鼠标在刘海附近；looking：有 Pip 在看鼠标。在看时不做小动作，停下 4s 后回正
    public mutating func mouseMoved(near: Bool, looking: Bool, now: Double) {
        if near { approached(now) }
        guard looking else { return }
        restAt = now + Choreography.gazeRestAfter
        idle.postponeMotions(until: now + Choreography.gazeRestAfter)
    }

    /// 关掉了跟随鼠标：眼睛已经回正，不用再等
    public mutating func endGaze() { restAt = nil }

    /// 点了一下 Pip；晕着再点从这一下重新算
    public mutating func poke(now: Double) { dizzyUntil = now + Self.dizzyFor }

    /// Pip 都看不见了，时钟要停：晕只有 `tick` 收得掉，停着时留下来会一直盖着别的造型。
    /// 晕是对那一下的反应，看不见了就算过去了
    public mutating func suspend() { dizzyUntil = nil }

    /// 看不见一段时间后回来：不补发攒下的眨眼和小动作
    public mutating func resume(at now: Double) { idle.resume(at: now) }

    private mutating func approached(_ now: Double) {
        lastNear = now
        drowsy = false
    }
}

extension Look {
    /// 晕、睡着叠在插件给的造型上（docs/mascot.md §2「优先级」：守卫 > 晕 > agent > 睡着 > 空闲）。
    /// 告示造型（守卫的、出错卡上的）不被盖掉；只有空闲时才睡着
    public func shown(drowsy: Bool, dizzy: Bool) -> Look {
        if isSign { return self }
        if dizzy { return .dizzy }
        return self == .idle && drowsy ? .sleeping : self
    }
}
