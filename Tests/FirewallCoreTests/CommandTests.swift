import Testing
@testable import FirewallCore

let boot = "B5E97D3E-1F68-4627-B43C-2257F22F12DB"
func at(_ seconds: Int64, boot session: String? = boot) -> Moment {
    Moment(bootSession: session, now: MonotonicTime(milliseconds: seconds * 1000))
}

@Suite struct Commands {
    @Test func enableStartsATwoMinuteTrial() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(s.mode == .trial(deadline: MonotonicTime(milliseconds: 220_000)))
    }

    /// 状态机只有 off → trial 这一条开启的路：试运行中再点开启不能把截止时间往后推
    @Test func enableOnlyFromOff() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(throws: FirewallCommandError.notOff) { try s.enable(at: at(150)) }
        #expect(s.mode == .trial(deadline: MonotonicTime(milliseconds: 220_000)))
    }

    @Test func keepBeforeDeadlineTurnsOn() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        try s.keep(at: at(219))
        #expect(s.mode == .on)
    }

    /// 到期必回滚：守护进程还没来得及跑这一轮时点「保留」，也不能救回过期的试运行
    @Test func keepAtDeadlineIsRefusedAndRollsBack() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(throws: FirewallCommandError.notInTrial) { try s.keep(at: at(220)) }
        #expect(s.mode == .off)
    }

    @Test func keepWhenOffIsRefused() {
        var s = FirewallState(bootSession: boot)
        #expect(throws: FirewallCommandError.notInTrial) { try s.keep(at: at(100)) }
        #expect(s.mode == .off)
    }

    /// 开机时 trial 一律当 off：上一次开机的试运行，截止时间按新开机的单调时钟看可能还没到，也不能保留
    @Test func keepATrialFromThePreviousBootIsRefused() throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        #expect(throws: FirewallCommandError.notInTrial) { try s.keep(at: at(5, boot: "OTHER-BOOT")) }
        #expect(s.mode == .off)
        #expect(s.bootSession == "OTHER-BOOT")
    }

    /// 命令不读引用列表：开机后旧 token 一律作废，不能配上新的开机标识落盘（关闭时释放失败、重启后再开启就会这样）
    @Test func commandAfterBootDropsTheOldToken() throws {
        var s = FirewallState(bootSession: boot)
        s.reference = .held(token: "1864012227745836441")
        try s.enable(at: at(5, boot: "OTHER-BOOT"))
        #expect(s.reference == nil)
    }

    /// 读不出开机标识时开启、保留都报错（下一轮反正会把试运行当 off，悄悄回滚用户看不出为什么）；
    /// 不动引用和记下的开机标识：还活着的引用丢了就再也释放不了
    @Test func commandsRefuseAnUnreadableBootSession() throws {
        var s = FirewallState(bootSession: boot)
        s.reference = .held(token: "1864012227745836441")
        #expect(throws: FirewallCommandError.bootSessionUnknown) { try s.enable(at: at(100, boot: nil)) }
        #expect(s.mode == .off)
        #expect(s.reference == .held(token: "1864012227745836441"))
        #expect(s.bootSession == boot)
        try s.enable(at: at(100))
        #expect(throws: FirewallCommandError.bootSessionUnknown) { try s.keep(at: at(110, boot: nil)) }
        #expect(s.mode == .off)
    }

    @Test(arguments: [false, true])
    func disableTurnsOffFromTrialOrOn(kept: Bool) throws {
        var s = FirewallState(bootSession: boot)
        try s.enable(at: at(100))
        if kept { try s.keep(at: at(110)) }
        s.disable()
        #expect(s.mode == .off)
    }
}
