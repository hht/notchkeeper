import Foundation
import Testing
import FirewallCore
@testable import firewalld

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// 恢复脚本不依赖辅助程序，名字是各写一份的：跑它的 --dry-run（不要 root、不改东西），看辅助程序会留下的每样东西它都清
@Suite struct RescueScript {
    private func dryRun() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/firewall-rescue.sh").path, "--dry-run"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return text
    }

    @Test func cleansEverythingTheHelperLeaves() throws {
        let text = try dryRun()
        #expect(text.contains("launchctl bootout system/\(FirewallPaths.label)"))
        #expect(text.contains("pfctl -a \(FirewallPaths.anchor) -F rules"))
        let dir = FirewallPaths.directory.path
        for name in [FirewallState.fileName, FirewallStatus.fileName, FirewallPaths.lockFile,
                     ".\(FirewallState.fileName).tmp", ".\(FirewallStatus.fileName).tmp",
                     FirewallRules.clashTableFile, FirewallRules.cnTableFile, FirewallRules.testTableFile,
                     ".\(FirewallRules.clashTableFile).tmp", ".\(FirewallRules.cnTableFile).tmp"] {
            #expect(text.contains("rm -f \(dir)/\(name)"), "恢复脚本没清 \(name)")
        }
        #expect(text.contains("rm -f /Library/LaunchDaemons/\(FirewallPaths.label).plist"))
    }

    /// pf 在内核里卡住时（user 规则死锁，docs/firewall.md §5）所有 pfctl 都不返回，launchctl bootout 也可能跟着等：
    /// 先删开机会加载的 plist 和辅助程序（只动文件），这样不管后面卡在哪，重启都一定恢复
    @Test func removesWhatLoadsAtBootBeforeTouchingPF() throws {
        let text = try dryRun()
        let plist = try #require(text.range(of: "rm -f /Library/LaunchDaemons/\(FirewallPaths.label).plist"))
        let helper = try #require(text.range(of: "rm -f /Library/PrivilegedHelperTools/notchkeeper-firewall"))
        let bootout = try #require(text.range(of: "launchctl bootout"))
        let pfctl = try #require(text.range(of: "pfctl -"))
        #expect(plist.lowerBound < bootout.lowerBound && plist.lowerBound < pfctl.lowerBound)
        #expect(helper.lowerBound < bootout.lowerBound && helper.lowerBound < pfctl.lowerBound)
    }

    /// 限时执行：卡住的命令（这里用 sleep 冒充卡在内核里的 pfctl）几秒内放手、返回 124，输出照样拿得到。
    /// 从脚本里原样取出 `limited` 函数来跑，测的就是脚本里那一份
    @Test func limitedGivesUpOnAHungCommand() throws {
        let script = try String(contentsOf: root.appendingPathComponent("scripts/firewall-rescue.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "limited() {"))
        let end = try #require(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
        let function = String(script[start.lowerBound..<end.upperBound])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("limited-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", function + """
            limited 1 "$1" sh -c 'echo started; exec sleep 30'; echo "hung=$?"
            limited 1 "$1" echo done; echo "quick=$? $(cat "$1")"
            """, "limited-test", out]
        let pipe = Pipe()
        p.standardOutput = pipe
        let started = ContinuousClock.now
        try p.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(text.contains("hung=124"))
        #expect(text.contains("quick=0 done"))
    }

    /// 安装脚本的语法检查：从脚本里原样取出 `check_syntax`，用 macOS 自带的 /bin/bash（3.2）跑，喂辅助程序打印的测试规则。
    /// bash 3.2 把 `${…//模式/"替换"}` 的引号原样留下，表文件路径变成 `""/private/tmp/…"`，pfctl 报 cannot load
    @Test func installerSyntaxCheckRunsOnSystemBash() throws {
        let script = try String(contentsOf: root.appendingPathComponent("scripts/install-firewall.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "check_syntax() {"))
        let end = try #require(script.range(of: "\n}\n", range: start.upperBound..<script.endIndex))
        let function = String(script[start.lowerBound..<end.upperBound])
        let rules = try #require(FirewallRules(tunnel: "utun1024", scope: .testTable, directory: FirewallPaths.directory.path)).text
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("syntax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "SUPPORT='\(FirewallPaths.directory.path)'; ANCHOR='\(FirewallPaths.anchor)'\n" + function + "check_syntax \"$1\" \"$2\"",
                       "syntax-test", rules, dir.path]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"] // 同脚本：不靠调用方的 PATH 找 pfctl
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(stderr)")
    }

    /// 安装脚本装下的东西，恢复脚本都得认得；安装脚本见到恢复脚本会删的任何一样都拒绝。两边各写一份，逐行比：
    /// 路径六行，加上 `FILES=(` 到 `)` 的文件清单
    @Test func installerUsesTheRescuePaths() throws {
        func paths(_ script: String) throws -> [Substring] {
            let lines = try String(contentsOf: root.appendingPathComponent("scripts/\(script)"), encoding: .utf8).split(separator: "\n")
            let names = lines.filter { ["LABEL=", "ANCHOR=", "PLIST=", "HELPER=", "SUPPORT=", "STATE="].contains(where: $0.hasPrefix) }
            guard let start = lines.firstIndex(where: { $0.hasPrefix("FILES=(") }),
                  let end = lines[start...].firstIndex(where: { $0.hasSuffix(")") }) else { return names }
            return names + lines[start...end]
        }
        let rescue = try paths("firewall-rescue.sh")
        #expect(rescue.count == 9)
        #expect(try paths("install-firewall.sh") == rescue)
    }
}
