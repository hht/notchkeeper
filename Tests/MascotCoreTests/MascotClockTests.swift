import Testing
@testable import MascotCore

/// 所有 Pip 共用的时钟：除了眨眼和小动作（IdleDirectorTests），还管注视回正、犯困、晕（docs/mascot.md §2、§5）
@Suite struct MascotClockTests {
    /// 鼠标 120s 没靠近刘海就睡着；一靠近就醒
    @Test func drowsyAfterMouseStaysAway() {
        var c = MascotClock(seed: 1, now: 0)
        #expect(c.nextWake <= MascotClock.drowsyAfter)
        _ = c.tick(now: MascotClock.drowsyAfter - 1, mouseNear: false)
        #expect(!c.drowsy)
        _ = c.tick(now: MascotClock.drowsyAfter, mouseNear: false)
        #expect(c.drowsy)
        c.mouseMoved(near: true, looking: false, now: 200)
        #expect(!c.drowsy)
        // 醒来后从这一刻重新算
        _ = c.tick(now: 200 + MascotClock.drowsyAfter - 1, mouseNear: false)
        #expect(!c.drowsy)
    }

    /// 鼠标一直停在刘海旁边不动（没有移动事件）也不算走开
    @Test func stillMouseNearNotchKeepsAwake() {
        var c = MascotClock(seed: 1, now: 0)
        _ = c.tick(now: MascotClock.drowsyAfter, mouseNear: true)
        #expect(!c.drowsy)
        #expect(c.nextWake <= 2 * MascotClock.drowsyAfter)
    }

    /// 远处动鼠标不算靠近
    @Test func farMovesDoNotCount() {
        var c = MascotClock(seed: 1, now: 0)
        c.mouseMoved(near: false, looking: true, now: 100)
        _ = c.tick(now: MascotClock.drowsyAfter, mouseNear: false)
        #expect(c.drowsy)
    }

    /// 睡着以后不再为犯困醒来
    @Test func noDrowsyWakeWhileAsleep() {
        var c = MascotClock(seed: 1, now: 0)
        _ = c.tick(now: MascotClock.drowsyAfter, mouseNear: false)
        for _ in 0..<5 { _ = c.tick(now: c.nextWake, mouseNear: false) }
        #expect(c.drowsy)
    }

    /// 在看鼠标时：停下 4s 后回正；这期间不做小动作
    @Test func gazeRestsAfterMouseStops() {
        var c = MascotClock(seed: 1, now: 0)
        c.mouseMoved(near: false, looking: true, now: 1)
        #expect(c.nextWake <= 1 + Choreography.gazeRestAfter)
        #expect(!c.tick(now: 1 + Choreography.gazeRestAfter - 0.01, mouseNear: false).gazeRested)
        let t = c.tick(now: 1 + Choreography.gazeRestAfter, mouseNear: false)
        #expect(t.gazeRested)
        #expect(!t.cues.contains { if case .idle = $0 { true } else { false } })
        // 回正只发一次
        #expect(!c.tick(now: 1 + Choreography.gazeRestAfter + 0.1, mouseNear: false).gazeRested)
    }

    /// 关掉跟随鼠标：不再等回正
    @Test func endGazeCancelsRest() {
        var c = MascotClock(seed: 1, now: 0)
        c.mouseMoved(near: false, looking: true, now: 1)
        c.endGaze()
        #expect(!c.tick(now: 1 + Choreography.gazeRestAfter, mouseNear: false).gazeRested)
    }

    /// 点一下 Pip 晕 1.6s
    @Test func pokeMakesDizzyForAWhile() {
        var c = MascotClock(seed: 1, now: 0)
        c.poke(now: 10)
        #expect(c.dizzy)
        #expect(c.nextWake <= 10 + MascotClock.dizzyFor)
        _ = c.tick(now: 10 + MascotClock.dizzyFor - 0.01, mouseNear: false)
        #expect(c.dizzy)
        _ = c.tick(now: 10 + MascotClock.dizzyFor, mouseNear: false)
        #expect(!c.dizzy)
    }

    /// 晕的时候再点：从这一下重新算
    @Test func pokeAgainExtends() {
        var c = MascotClock(seed: 1, now: 0)
        c.poke(now: 10)
        c.poke(now: 11)
        _ = c.tick(now: 10 + MascotClock.dizzyFor, mouseNear: false)
        #expect(c.dizzy)
    }

    /// 晕着时 Pip 都看不见了（收起时不画左耳的 Pip）：时钟停掉前晕就算过去，不留到下次看得见时还盖着别的造型
    @Test func suspendEndsDizzy() {
        var c = MascotClock(seed: 1, now: 0)
        c.poke(now: 10)
        c.suspend()
        #expect(!c.dizzy)
    }

    /// 时钟按 nextWake 醒，眨眼照常发
    @Test func blinksStillCome() {
        var c = MascotClock(seed: 1, now: 0)
        var blinks = 0
        while c.nextWake < 30 {
            blinks += c.tick(now: c.nextWake, mouseNear: true).cues.filter { if case .blink = $0 { true } else { false } }.count
        }
        #expect(blinks >= 4)
    }
}

/// 晕、睡着叠在插件给的造型上（docs/mascot.md §2「优先级」）：守卫 > 晕 > agent > 睡着 > 空闲
@Suite struct MascotOverlay {
    @Test func dizzyBeatsAgentAndSleep() {
        for look in [Look.idle, .working, .longTurn, .question, .approval, .finished] {
            #expect(look.shown(drowsy: true, dizzy: true) == .dizzy)
        }
    }

    /// 告示造型（守卫的、出错卡上的）不被晕盖掉
    @Test func signsBeatDizzy() {
        for look in [Look.danger, .shielded, .mismatch, .stale, .offline, .error] {
            #expect(look.shown(drowsy: true, dizzy: true) == look)
        }
    }

    /// 只有空闲时才睡着
    @Test func onlyIdleFallsAsleep() {
        #expect(Look.idle.shown(drowsy: true, dizzy: false) == .sleeping)
        #expect(Look.working.shown(drowsy: true, dizzy: false) == .working)
        #expect(Look.idle.shown(drowsy: false, dizzy: false) == .idle)
    }
}
