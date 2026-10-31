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

    /// root 跑的子命令不继承调用方的环境：sudo 保留用户的 HOME 时，dig 会读用户可写的 ~/.digrc（等于往参数里塞选项）
    @Test func childrenGetAMinimalEnvironment() {
        let out = FirewallSystem.runProcess("/usr/bin/env", [], nil, timeout: 5)
        #expect(out.stdout.split(separator: "\n").sorted() == ["HOME=/var/root", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"])
    }

    /// 卡住的子命令到时就结束它、当失败，一轮总会结束
    @Test func killsACommandThatHangs() {
        let started = ContinuousClock.now
        let out = FirewallSystem.runProcess("/bin/sleep", ["30"], nil, timeout: 0.2)
        #expect(out.status == -1)
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
