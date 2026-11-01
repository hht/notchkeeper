import CryptoKit
import FirewallCore
import Foundation

/// 回答：防火墙装没装、此刻怎么样，App 里怎么装、卸、开启、保留、关闭（docs/firewall.md §4「特权部分」「App」）。每个改变都经系统的管理员密码框。
/// 装：包里的辅助程序和安装脚本拷到 /private/tmp（提权进程读不了 ~/Documents，TCC），经管理员密码框以 root 跑；
/// root 那边把脚本拷进自己的目录、核对哈希，辅助程序由安装脚本核对，拷出来之后被换过就停。
/// 卸：同样的办法跑恢复脚本（和断网时在终端里跑的是同一份）。开启、保留、关闭：提权调已装好的辅助程序（root 的文件，别人换不了）。
/// App 不常驻任何特权代码，只读状态摘要
enum FirewallInstaller {
    /// 和两份脚本里的路径一致（`RescueScriptTests` 比脚本之间的，这里只用来判断装没装）
    static let plist = URL(fileURLWithPath: "/Library/LaunchDaemons/com.notchkeeper.firewall.plist")
    static let helper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/notchkeeper-firewall")
    /// root 0644，守护进程每轮写（`FirewallStatus`）
    static let statusFile = URL(fileURLWithPath: "/Library/Application Support/Notchkeeper").appendingPathComponent(FirewallStatus.fileName)
    /// 开启时辅助程序从这里读一次运行时配置和 GeoIP 库，拍放行表（docs/firewall.md §4）
    static let clashVerge = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")

    /// 装了任何一样都算装着，卸载就是把它们全清掉。root 的目录也算：只剩防火墙状态文件这类东西时，安装脚本拒绝装，App 得给出「卸载」
    static var isInstalled: Bool {
        [plist, helper, statusFile.deletingLastPathComponent()].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 此刻怎么样，和摘要是哪一轮写的（命令之后等守护进程跑完那一轮用）
    static func reading(now: Date) -> (reading: FirewallReading, checkedAt: Date?) {
        let summary: FirewallReading.Summary
        var checkedAt: Date?
        do {
            let status = try FirewallStatus.decode(Data(contentsOf: statusFile))
            summary = .read(status)
            checkedAt = status.checkedAt
        } catch CocoaError.fileReadNoSuchFile {
            summary = .missing
        } catch {
            summary = .unreadable
        }
        return (FirewallReading(installed: isInstalled, summary: summary, now: now), checkedAt)
    }

    static func enable() async throws -> Outcome {
        guard FileManager.default.fileExists(atPath: clashVerge.path) else {
            throw Failure(errorDescription: String(localized: "找不到 Clash Verge 的配置目录：开启时要从那里读节点和国内 IP 段"))
        }
        return try await privileged(helperCommand(["enable", "--clash", clashVerge.path]),
                                    prompt: String(localized: "Pip 要开启防火墙，先试运行 2 分钟。"))
    }

    static func keep() async throws -> Outcome {
        try await privileged(helperCommand(["keep"]), prompt: String(localized: "Pip 要保留防火墙：之后一直开着，重启也开着。"))
    }

    static func disable() async throws -> Outcome {
        try await privileged(helperCommand(["disable"]), prompt: String(localized: "Pip 要关闭防火墙。"))
    }

    /// 拷到 /private/tmp 的一套，连同拷出来时的哈希：root 只跑和它对得上的
    struct Staged: Sendable {
        let directory: URL
        let helper: URL
        let helperSHA256: String
        let installScript: URL
        let installSHA256: String
        let rescueScript: URL
        let rescueSHA256: String
    }

    enum Outcome: Sendable {
        case done
        /// 用户在密码框里点了取消
        case cancelled
    }

    static func stage() throws -> Staged {
        guard let bundledHelper = Bundle.main.url(forAuxiliaryExecutable: "firewalld"),
              let scripts = Bundle.main.resourceURL?.appendingPathComponent("firewall", isDirectory: true),
              FileManager.default.fileExists(atPath: scripts.appendingPathComponent("install-firewall.sh").path)
        else { throw Failure(errorDescription: String(localized: "这个构建不含防火墙，要用 scripts/run.sh 打包")) }
        // 0700：别的用户换不了里面的文件；同一个用户换得了，所以 root 那边还要核对哈希
        let dir = URL(fileURLWithPath: "/private/tmp/notchkeeper-firewall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fm = FileManager.default
        let helper = dir.appendingPathComponent("firewalld")
        try fm.copyItem(at: bundledHelper, to: helper)
        let install = dir.appendingPathComponent("install-firewall.sh")
        try fm.copyItem(at: scripts.appendingPathComponent("install-firewall.sh"), to: install)
        let rescue = dir.appendingPathComponent("firewall-rescue.sh")
        try fm.copyItem(at: scripts.appendingPathComponent("firewall-rescue.sh"), to: rescue)
        return Staged(directory: dir, helper: helper, helperSHA256: try sha256(of: helper), installScript: install, installSHA256: try sha256(of: install),
                      rescueScript: rescue, rescueSHA256: try sha256(of: rescue))
    }

    /// 用完就删；删不掉只是 /private/tmp 里留一个目录，重启会清
    static func discard(_ staged: Staged) {
        do { try FileManager.default.removeItem(at: staged.directory) } catch { Log.write("防火墙：删不掉临时目录：\(error.localizedDescription)") }
    }

    static func install(_ s: Staged, tunnel: String) async throws -> Outcome {
        try await privileged(privilegedCommand(script: s.installScript, sha256: s.installSHA256,
                                               arguments: ["--tunnel", tunnel, "--helper", s.helper.path, "--expect-sha256", s.helperSHA256, "--yes"]),
                             prompt: String(localized: "Pip 要安装防火墙（装完是关着的，什么都不拦）。"))
    }

    static func uninstall(_ s: Staged) async throws -> Outcome {
        try await privileged(privilegedCommand(script: s.rescueScript, sha256: s.rescueSHA256, arguments: []),
                             prompt: String(localized: "Pip 要卸载防火墙：清掉守护进程、规则和文件。"))
    }

    /// 已装好的辅助程序是 root 的文件，别人换不了，直接跑
    private static func helperCommand(_ arguments: [String]) -> String {
        "/usr/bin/env -i \(cleanEnvironment) " + ([helper.path] + arguments).map(quoted).joined(separator: " ")
    }

    /// root 跑的那一行 shell：脚本是普通文件才读（不跟符号链接、不在 FIFO 上等、至多 1 MB），拷进 root 自己的临时目录（别人换不了）、核对哈希，对上了才跑，跑完删掉。
    /// 在 /private/tmp 里跑：提权进程进不了 ~/Documents（TCC）
    /// 整段先换进干净的环境再跑：核对哈希的 shasum 是 Perl 脚本，会读 PERL5OPT
    static func privilegedCommand(script: URL, sha256: String, arguments: [String]) -> String {
        let args = arguments.map(quoted).joined(separator: " ")
        let inner = """
            d=$(/usr/bin/mktemp -d /private/tmp/notchkeeper-firewall-root.XXXXXX) || exit 1
            trap '/bin/rm -rf "$d"' EXIT
            s=\(quoted(script.path))
            [ -f "$s" ] && [ ! -L "$s" ] || { echo "脚本不是普通文件，没有执行" >&2; exit 1; }
            /usr/bin/head -c 1048576 "$s" > "$d/script.sh" || exit 1
            [ "$(/usr/bin/shasum -a 256 "$d/script.sh" | /usr/bin/cut -c 1-64)" = \(quoted(sha256)) ] || { echo "脚本拷出来之后被换过，没有执行" >&2; exit 1; }
            cd /private/tmp && /bin/bash --noprofile --norc "$d/script.sh" \(args)
            """
        return "exec /usr/bin/env -i \(cleanEnvironment) /bin/sh -c " + quoted(inner)
    }

    /// root 跑的东西不继承 Pip 的环境：同一个用户能用 `launchctl setenv` 往之后启动的 Pip 里塞 `BASH_ENV`、`DYLD_*`
    private static let cleanEnvironment = "PATH=/usr/bin:/bin:/usr/sbin:/sbin"

    /// 单引号包起来，里面的单引号写成 '\''
    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// 弹系统的管理员密码框。命令和提示从 argv 传进 AppleScript，不用拼进脚本源码、不用转义；
    /// `without altering line endings`：不然输出里的换行都变成 \r
    /// @see https://developer.apple.com/library/archive/technotes/tn2065/_index.html
    private static func privileged(_ command: String, prompt: String) async throws -> Outcome {
        let (status, out, err) = try await run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges without altering line endings",
            "-e", "end run", command, prompt,
        ])
        if status == 0 { return .done }
        // 用户取消是 -128（userCanceledErr）
        if err.contains("(-128)") { return .cancelled }
        // 恢复脚本失败时每一步做了什么在 stdout 里：一起给人看
        throw Failure(errorDescription: [out, err].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// 后台跑完一个进程，拿 stdout、stderr
    private static func run(_ path: String, _ args: [String]) async throws -> (Int32, String, String) {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            // 两个管道同时读：只读一个时另一个写满了缓冲区，子进程就卡住
            async let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            let stdout = await o
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }.value
    }
}
