import Foundation
import Testing
@testable import firewalld

@Suite struct RunProcess {
    /// 规则从 stdin 进、输出从 stdout / stderr 出、退出码照实
    @Test func passesInputAndCollectsOutput() {
        let out = FirewallSystem.runProcess("/bin/sh", ["-c", "cat; echo oops >&2; exit 3"], "pass all\n", timeout: 5)
        #expect(out.status == 3)
        #expect(out.stdout == "pass all\n")
        #expect(out.stderr == "oops\n")
    }

    /// 卡住的子命令到时就结束它、当失败，一轮总会结束
    @Test func killsACommandThatHangs() {
        let started = ContinuousClock.now
        let out = FirewallSystem.runProcess("/bin/sleep", ["30"], nil, timeout: 0.2)
        #expect(out.status == -1)
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
