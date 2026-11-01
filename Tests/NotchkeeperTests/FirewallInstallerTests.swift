import Foundation
import Testing
@testable import Notchkeeper

/// 交给管理员密码框的那一行 shell：root 先把脚本拷进自己的临时目录、核对哈希，对上了才跑
@Suite struct FirewallPrivilegedCommand {
    private let hash = String(repeating: "a", count: 64)

    /// 真用 /bin/sh 跑（不提权）：脚本被换过就不执行，没换过就带着参数执行
    @Test func runsOnlyTheScriptThatWasStaged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw cmd '\(UUID().uuidString)'") // 空格和引号
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("s.sh")
        try Data("echo \"ran $1 $2\"\n".utf8).write(to: script)
        let good = try FirewallInstaller.sha256(of: script)

        let ran = try sh(FirewallInstaller.privilegedCommand(script: script, sha256: good, arguments: ["a b", "it's"]))
        #expect(ran.status == 0 && ran.out == "ran a b it's\n")

        let refused = try sh(FirewallInstaller.privilegedCommand(script: script, sha256: hash, arguments: []))
        #expect(refused.status != 0 && !refused.out.contains("ran"))

        // 符号链接不读：哪怕指向的就是那份脚本
        let link = dir.appendingPathComponent("link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: script)
        #expect(try sh(FirewallInstaller.privilegedCommand(script: link, sha256: good, arguments: [])).status != 0)
    }

    /// root 跑的脚本不继承调用方的环境（BASH_ENV 会让 bash 先 source 一个文件）
    @Test func environmentIsCleared() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fw-env-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("s.sh")
        try Data("echo \"bash_env=${BASH_ENV:-} secret=${SECRET:-}\"\n".utf8).write(to: script)
        let injected = dir.appendingPathComponent("inject.sh")
        try Data("echo injected\n".utf8).write(to: injected)
        let r = try sh(FirewallInstaller.privilegedCommand(script: script, sha256: FirewallInstaller.sha256(of: script), arguments: []),
                       environment: ["BASH_ENV": injected.path, "SECRET": "x"])
        #expect(r.status == 0 && r.out == "bash_env= secret=\n")
        // 核对哈希那一步也不能带调用方的环境：/usr/bin/shasum 是 Perl 脚本，会读 PERL5OPT
        let perl = try sh(FirewallInstaller.privilegedCommand(script: script, sha256: FirewallInstaller.sha256(of: script), arguments: []),
                          environment: ["PERL5OPT": "-MNoSuchModuleInjected"])
        #expect(perl.status == 0 && perl.out == "bash_env= secret=\n")
    }

    private func sh(_ command: String, environment: [String: String]? = nil) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }
}
