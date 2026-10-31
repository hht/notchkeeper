import Foundation
import Testing
import FirewallCore
@testable import firewalld

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// 恢复脚本不依赖辅助程序，名字是各写一份的：跑它的 --dry-run（不要 root、不改东西），看辅助程序会留下的每样东西它都清
@Suite struct RescueScript {
    @Test func cleansEverythingTheHelperLeaves() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/firewall-rescue.sh").path, "--dry-run"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(text.contains("launchctl bootout system/\(FirewallPaths.label)"))
        #expect(text.contains("pfctl -a \(FirewallPaths.anchor) -F rules"))
        let dir = FirewallPaths.directory.path
        for name in [FirewallState.fileName, FirewallStatus.fileName, FirewallPaths.lockFile,
                     ".\(FirewallState.fileName).tmp", ".\(FirewallStatus.fileName).tmp"] {
            #expect(text.contains("rm -f \(dir)/\(name)"), "恢复脚本没清 \(name)")
        }
        #expect(text.contains("rm -f /Library/LaunchDaemons/\(FirewallPaths.label).plist"))
    }
}
