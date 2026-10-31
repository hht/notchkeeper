import Darwin
import Foundation
import FirewallCore

/// 回答：防火墙辅助程序收到什么参数做什么（docs/firewall.md §4「特权部分」）。
///
/// - `notchkeeper-firewall round --tunnel <网卡名> [--test-rules]`：LaunchDaemon，trial / on 时每 10 秒一轮，回到 off 就退出。
///   `--test-rules` 装测试规则（block 只拦去测试表的流量，测试时不真的断网，§7）
/// - `notchkeeper-firewall enable --clash <Clash Verge 目录> | keep | disable`：App 用 osascript 带管理员权限调
/// - `notchkeeper-firewall rules --tunnel <网卡名> [--test-rules]`：只打印一轮会装的规则，给安装脚本拿去给人看、做语法检查
///
/// 除了打印规则，只认 root：普通用户跑什么都不做
@main
enum Firewalld {
    static let usage = "用法：notchkeeper-firewall round|rules --tunnel <网卡名> [--test-rules] | enable --clash <Clash Verge 目录> | keep | disable"

    /// 参数说要做什么
    enum Invocation: Equatable {
        case round(Helper.RoundConfig)
        case rules(Helper.RoundConfig)
        case command(Helper.Command)
    }

    static func main() {
        // 往提前退出的子进程 stdin 写东西时不能被 SIGPIPE 杀掉，root 守护进程半路死了这一轮就没做完
        signal(SIGPIPE, SIG_IGN)
        guard let invocation = parse(Array(CommandLine.arguments.dropFirst())) else { fail(usage, code: 64) }
        let requireRoot = { if geteuid() != 0 { fail("要用 root 运行", code: 1) } }
        switch invocation {
        case .rules(let config):
            print(config.rules.text, terminator: "")
        case .round(let config):
            requireRoot()
            Helper.serve(.live, config) { sleep(10) }
        case .command(let command):
            requireRoot()
            do {
                if let tables = try Helper.command(command, .live) {
                    print("已开启试运行（2 分钟内不保留就自动关闭）。放行表：<clash> \(tables.clash.count) 条，<cn> \(tables.cn.count) 段")
                }
            } catch {
                fail(message(error), code: 1)
            }
        }
    }

    /// `round|rules --tunnel <网卡名> [--test-rules]`、`enable --clash <绝对路径>`、`keep`、`disable`，多一个少一个都不认
    static func parse(_ args: [String]) -> Invocation? {
        switch (args.first, args.count) {
        case ("keep", 1): return .command(.keep)
        case ("disable", 1): return .command(.disable)
        case ("enable", 3) where args[1] == "--clash" && args[2].hasPrefix("/"):
            return .command(.enable(clash: URL(fileURLWithPath: args[2])))
        case ("round", _): return roundConfig(Array(args.dropFirst())).map(Invocation.round)
        case ("rules", _): return roundConfig(Array(args.dropFirst())).map(Invocation.rules)
        default: return nil
        }
    }

    private static func roundConfig(_ args: [String]) -> Helper.RoundConfig? {
        switch args.count {
        case 2 where args[0] == "--tunnel":
            Helper.RoundConfig(tunnel: args[1], scope: .everyone)
        case 3 where args[0] == "--tunnel" && args[2] == "--test-rules":
            Helper.RoundConfig(tunnel: args[1], scope: .testTable)
        default:
            nil
        }
    }

    private static func message(_ failure: Helper.Failure) -> String {
        switch failure {
        case .command(.notOff): "防火墙已经开着"
        case .command(.notInTrial): "不在试运行中（可能已到期回滚），没有可保留的"
        case .command(.bootSessionUnknown): "读不出开机标识（kern.bootsessionuuid），分不清是不是重启过，不能开启或保留"
        case .stateUnreadable: "防火墙状态文件读不出来；先跑 sudo scripts/firewall-rescue.sh 再重新安装"
        case .snapshot(let f): "没开启：" + snapshotMessage(f)
        case .busy: "另一个操作正在进行，稍后再试"
        case .io(let m): m
        }
    }

    private static func snapshotMessage(_ failure: SnapshotFailure) -> String {
        switch failure {
        case .unreadable(let name): "读不了 Clash Verge 目录里的 \(name)"
        case .config(.proxyProviders): "Clash 配置里有 proxy-providers，节点地址不在配置文件里"
        case .config(.noNodes): "Clash 配置里没有节点"
        case .config(.unsupported(let line)): "Clash 配置第 \(line) 行的写法认不出来"
        case .database(.malformed): "Country.mmdb 不是完整的 GeoIP 库"
        case .database(.unsupportedType(let type)): "不支持 \(type) 类型的 GeoIP 库"
        case .noCountryNetworks: "Country.mmdb 里没有国内网段"
        case .implausibleCountryNetwork: "Country.mmdb 里有大得不像一个国家的国内网段，可能被改过"
        case .table(.tooManyNodes): "Clash 配置里的域名节点超过 \(ClashRuntimeConfig.maxDomainNodes) 个，不像真的订阅"
        case .database(.tooManyNetworks), .table(.tooManyEntries): "放行表超过 \(CountryDatabase.maxTableEntries) 项，pf 装不下"
        case .table(.noResolver): "Clash 配置的 proxy-server-nameserver 里没有能直接问的明文 UDP 上游，查不了节点地址"
        case .table(.unresolved(let node)): "第 \(node) 个节点的地址查不到（Clash 在运行吗？）"
        case .table(.fakeAnswer(let node)): "第 \(node) 个节点查回来的是 fake-ip，不是真地址"
        case .table(.notADomain(let node)): "第 \(node) 个节点的 server 不像域名"
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        fputs("notchkeeper-firewall: \(message)\n", stderr)
        exit(code)
    }
}
