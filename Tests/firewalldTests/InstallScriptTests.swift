import Foundation
import Testing
import FirewallCore

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
/// `swift test` 先编出来的辅助程序：App 装的就是包里这样一份现成的，不在 root 下编译
private let helper = root.appendingPathComponent(".build/debug/firewalld")

/// 跑安装脚本（不要 root：只用 --dry-run，或在 root 检查之前就该停下的参数）
private func install(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [root.appendingPathComponent("scripts/install-firewall.sh").path] + args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return (p.terminationStatus, o, e)
}

private func sha256(_ url: URL) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    p.arguments = ["-a", "256", url.path]
    let out = Pipe()
    p.standardOutput = out
    try p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return String(text.prefix(64))
}

/// App 里装正式规则：给一份现成的辅助程序和它的哈希，不在 root 下编译；哈希对不上就停
@Suite(.serialized) struct InstallScript {
    @Test func officialRulesDryRunWithPrebuiltHelper() throws {
        let hash = try sha256(try #require(FileManager.default.fileExists(atPath: helper.path) ? helper : nil))
        let r = try install(["--helper", helper.path, "--expect-sha256", hash, "--dry-run"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("sha256 \(hash)"))
        // 正式规则：最后一条整机拦截，没有测试表；LaunchDaemon 不带 --test-rules
        #expect(r.out.contains("block return out quick all"))
        #expect(!r.out.contains("<test>") && !r.out.contains("--test-rules") && !r.out.contains(FirewallRules.testTableFile))
        #expect(!r.out.contains("编译"))
    }

    @Test func hashMismatchStops() throws {
        let r = try install(["--helper", helper.path, "--expect-sha256", String(repeating: "0", count: 64), "--dry-run"])
        #expect(r.status != 0)
        #expect(r.err.contains("哈希"))
        #expect(!r.out.contains("规则语法正确"))
    }

    /// root 读 --helper 时不跟符号链接：链到别的文件也不读它
    @Test func symlinkedHelperRefused() throws {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("helper-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)
        defer { try? FileManager.default.removeItem(at: link) }
        let r = try install(["--helper", link.path, "--expect-sha256", try sha256(helper), "--dry-run"])
        #expect(r.status != 0 && r.err.contains("不是普通文件"))
    }

    @Test func testRulesStillAvailable() throws {
        let hash = try sha256(helper)
        let r = try install(["--test-rules", "--test-address", "198.51.100.7", "--helper", helper.path, "--expect-sha256", hash, "--dry-run"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("<test>") && r.out.contains("--test-rules"))
    }

    /// 不问 yes 只在调用方钉住了哈希时才行
    @Test(arguments: [["--yes", "--helper", "/x"], ["--test-address", "198.51.100.7"], ["--expect-sha256", "abc", "--helper", "/x"],
                      ["--test-rules"]])
    func badArguments(_ args: [String]) throws {
        let r = try install(args + ["--dry-run"])
        #expect(r.status != 0)
        #expect(!r.out.contains("规则语法正确"))
    }
}
