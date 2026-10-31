import Foundation
import FirewallCore
@testable import firewalld

/// 假的 pf：照本机实测的输出格式（docs/firewall.md §6）回应 pfctl、ifconfig、launchctl，记下每一次调用
final class FakePF: @unchecked Sendable {
    var anchor = ""
    var references: [String] = []
    var nextToken = 1_864_012_227_745_836_441 as UInt64
    var evaluations: UInt64 = 0
    var mainRules = "scrub-anchor \"com.apple/*\" all fragment reassemble\nanchor \"com.apple/*\" all\n"
    var interfaces = "lo0 en0 utun1024\n"
    var calls: [[String]] = []
    var enabled = true
    /// 让某条命令失败：参数里含这个串的那次调用返回 1
    var failing: String?
    /// 每次调用前看一眼（测「拿到 token 后立刻落盘」用）
    var onCall: ([String]) -> Void = { _ in }

    func run(_ executable: String, _ arguments: [String], _ input: String?) -> Output {
        let call = [executable] + arguments
        onCall(call)
        calls.append(call)
        if let failing, call.contains(failing) { return Output(status: 1, stdout: "", stderr: "pfctl: failed\n") }
        let noise = "No ALTQ support in kernel\nALTQ related functions disabled\n"
        switch call {
        case ["/sbin/pfctl", "-a", FirewallPaths.anchor, "-sr"]:
            return Output(status: 0, stdout: anchor, stderr: noise)
        case ["/sbin/pfctl", "-a", FirewallPaths.anchor, "-vsr"]:
            evaluations += 100
            let rules = anchor.split(separator: "\n").map { "\($0)\n  [ Evaluations: \(evaluations)  Packets: 0 ]\n" }.joined()
            return Output(status: 0, stdout: rules, stderr: noise)
        case ["/sbin/pfctl", "-a", FirewallPaths.anchor, "-f", "-"]:
            anchor = input ?? ""
            return Output(status: 0, stdout: "", stderr: noise)
        case ["/sbin/pfctl", "-a", FirewallPaths.anchor, "-F", "rules"]:
            anchor = ""
            return Output(status: 0, stdout: "", stderr: noise + "rules cleared\n")
        case ["/sbin/pfctl", "-E"]:
            enabled = true
            let token = String(nextToken)
            nextToken += 1
            references.append(token)
            return Output(status: 0, stdout: "", stderr: noise + "pf enabled\nToken : \(token)\n")
        case ["/sbin/pfctl", "-sr"]:
            return Output(status: 0, stdout: mainRules, stderr: noise)
        case ["/sbin/pfctl", "-s", "References"]:
            let rows = (["12184426722627826779"] + references).map { "49256    pfd                          \($0)     0 days 00:00:12\n" }
            return Output(status: 0, stdout: "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\n" + rows.joined(),
                          stderr: noise)
        case ["/sbin/pfctl", "-s", "info"]:
            return Output(status: 0, stdout: enabled ? "Status: Enabled for 0 days 00:00:12           Debug: Urgent\n" : "Status: Disabled\n",
                          stderr: noise)
        case ["/sbin/ifconfig", "-l"]:
            return Output(status: 0, stdout: interfaces, stderr: "")
        case ["/bin/launchctl", "kickstart", "system/\(FirewallPaths.label)"]:
            return Output(status: 0, stdout: "", stderr: "")
        default:
            if call.count == 3, call[0] == "/sbin/pfctl", call[1] == "-X", let i = references.firstIndex(of: call[2]) {
                references.remove(at: i)
                return Output(status: 0, stdout: "", stderr: noise + "disable request successful.\n")
            }
            return Output(status: 1, stdout: "", stderr: "unexpected call\n")
        }
    }
}

/// 临时目录 + 假 pf + 手动拨的时钟
final class Rig: @unchecked Sendable {
    let pf = FakePF()
    let directory: URL
    var seconds: Int64 = 100
    var bootSession = "B5E97D3E-1F68-4627-B43C-2257F22F12DB"
    var lockTimeout: TimeInterval = 30
    var system: FirewallSystem {
        FirewallSystem(directory: directory,
                       moment: { Moment(bootSession: self.bootSession, now: MonotonicTime(milliseconds: self.seconds * 1000)) },
                       now: { Date(timeIntervalSince1970: 1_793_419_500 + TimeInterval(self.seconds)) },
                       run: { self.pf.run($0, $1, $2) }, lockTimeout: lockTimeout)
    }
    let rules = FirewallRules(tunnel: "utun1024")!

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("firewalld-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func round(scope: FirewallRules.Scope = .everyone) -> FirewallStatus? {
        Helper.round(system, Helper.RoundConfig(tunnel: "utun1024", scope: scope)!)
    }

    var state: FirewallState.Restored {
        FirewallState.restore(from: try? Data(contentsOf: directory.appendingPathComponent(FirewallState.fileName)))
    }

    var status: FirewallStatus? {
        (try? Data(contentsOf: directory.appendingPathComponent(FirewallStatus.fileName))).flatMap { try? FirewallStatus.decode($0) }
    }
}
