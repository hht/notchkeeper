import Darwin
import FirewallCore

/// 回答：防火墙辅助程序收到什么参数做什么（docs/firewall.md §4「特权部分」）。
///
/// - `notchkeeper-firewall round --tunnel <网卡名> [--test-rules]`：LaunchDaemon 每 10 秒跑一次。
///   `--test-rules` 装测试规则（block 只拦 nobody，测试时不真的断网，§7）
/// - `notchkeeper-firewall enable | keep | disable`：App 用 osascript 带管理员权限调
///
/// 只认 root：普通用户跑什么都不做
@main
enum Firewalld {
    static func main() {
        // 往提前退出的子进程 stdin 写东西时不能被 SIGPIPE 杀掉，root 守护进程半路死了这一轮就没做完
        signal(SIGPIPE, SIG_IGN)
        let args = Array(CommandLine.arguments.dropFirst())
        guard geteuid() == 0 else { fail("要用 root 运行", code: 1) }
        if args.count == 1, let command = Helper.Command(rawValue: args[0]) {
            do {
                try Helper.command(command, .live)
            } catch {
                fail(message(error), code: 1)
            }
            return
        }
        guard let config = roundConfig(args) else {
            fail("用法：notchkeeper-firewall round --tunnel <网卡名> [--test-rules] | enable | keep | disable", code: 64)
        }
        if Helper.round(.live, config) == nil { exit(75) } // EX_TEMPFAIL：没拿到锁，下一轮再来
    }

    /// `round --tunnel <网卡名> [--test-rules]`，多一个少一个都不认
    static func roundConfig(_ args: [String]) -> Helper.RoundConfig? {
        switch args.count {
        case 3 where args[0] == "round" && args[1] == "--tunnel":
            Helper.RoundConfig(tunnel: args[2], scope: .everyone)
        case 4 where args[0] == "round" && args[1] == "--tunnel" && args[3] == "--test-rules":
            Helper.RoundConfig(tunnel: args[2], scope: .testUser)
        default:
            nil
        }
    }

    private static func message(_ failure: Helper.Failure) -> String {
        switch failure {
        case .command(.notOff): "防火墙已经开着"
        case .command(.notInTrial): "不在试运行中（可能已到期回滚），没有可保留的"
        case .command(.bootSessionUnknown): "读不出开机标识（kern.bootsessionuuid），分不清是不是重启过，不能开启或保留"
        case .stateUnreadable: "状态文件读不出来；先跑 sudo scripts/firewall-rescue.sh 再重新安装"
        case .busy: "另一个操作正在进行，稍后再试"
        case .io(let m): m
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        fputs("notchkeeper-firewall: \(message)\n", stderr)
        exit(code)
    }
}
