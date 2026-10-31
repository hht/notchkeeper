import Foundation
import Testing

/// 一次 zsh 会话：临时目录里搭出 `plugins/terminal/notchkeeper.zsh` 和假的 `bin/nk`（把参数逐行写进 `calls/`），
/// 交互式 zsh 读 stdin 里的命令。`pty` 时套 `script` 给它一个终端，才有 `$TTY`
private struct Session {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-plugin-\(UUID().uuidString)")
    var calls: URL { root.appendingPathComponent("calls") }

    init() throws {
        let fm = FileManager.default
        let plugin = root.appendingPathComponent("plugins/terminal")
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
        try fm.createDirectory(at: calls, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/plugins/terminal/notchkeeper.zsh")
        try fm.copyItem(at: source.standardized, to: plugin.appendingPathComponent("notchkeeper.zsh"))
        let nk = root.appendingPathComponent("bin/nk")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/../calls/$(date +%s%N)-$$\"\n".write(to: nk, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nk.path)
    }

    /// 跑完这些命令，等到假 nk 被调够 `expecting` 次（后台调用），返回每次的参数
    func run(_ commands: [String], expecting: Int, pty: Bool = false) throws -> [[String]] {
        let script = (["notchkeeper_min_seconds=0.3", "source \(root.path)/plugins/terminal/notchkeeper.zsh"] + commands + ["exit"])
            .joined(separator: "\n") + "\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pty ? "/usr/bin/script" : "/bin/zsh")
        // 关掉行编辑（+Z）：zle 起来时会丢掉已经写进终端的输入
        p.arguments = pty ? ["-q", "/dev/null", "/bin/zsh", "-fi", "+Z"] : ["-fi"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        // 等它自己 exit 再关：`script` 读到 stdin 的 EOF 就收场，后面的命令来不及跑
        p.waitUntilExit()
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        var names: [String] = []
        repeat {
            names = try FileManager.default.contentsOfDirectory(atPath: calls.path).sorted()
            if names.count >= expecting { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        // 多等一下：不该有的调用也要来得及出现
        Thread.sleep(forTimeInterval: 0.2)
        names = try FileManager.default.contentsOfDirectory(atPath: calls.path).sorted()
        defer { try? FileManager.default.removeItem(at: root) }  // 每个 Session 只跑一次；删不掉只是留在临时目录里
        return try names.map { try String(contentsOf: calls.appendingPathComponent($0), encoding: .utf8).split(separator: "\n").map(String.init) }
    }
}

private func value(_ args: [String], _ option: String) -> [String] {
    args.indices.filter { args[$0] == option && $0 + 1 < args.count }.map { args[$0 + 1] }
}

@Suite(.serialized) struct TerminalPlugin {
    @Test func failedLongCommand() throws {
        let s = try Session()
        let calls = try s.run(["sleep 0.4; false"], expecting: 1)
        try #require(calls.count == 1)
        let args = calls[0]
        #expect(args.first == "notify")
        #expect(value(args, "--plugin") == ["terminal"])
        #expect(value(args, "--title") == ["sleep 失败了"])
        #expect(value(args, "--outcome") == ["failed"])
        #expect(value(args, "--value") == ["0 秒"])
        #expect(value(args, "--fact").first == "退出码=1")
        #expect(value(args, "--fact").count == 2)
    }

    @Test func successfulLongCommand() throws {
        let s = try Session()
        let calls = try s.run(["sleep 0.4"], expecting: 1)
        try #require(calls.count == 1)
        #expect(value(calls[0], "--title") == ["sleep 跑完了"])
        #expect(value(calls[0], "--outcome") == ["done"])
        #expect(value(calls[0], "--fact").first == "退出码=0")
    }

    /// 短的、忽略表里的不弹；最后一条长命令用来确认钩子在跑
    @Test func shortAndIgnoredCommandsStaySilent() throws {
        let s = try Session()
        let calls = try s.run(["true", "false", "vim() { sleep 0.4 }", "vim x", "sleep 0.4"], expecting: 1)
        #expect(calls.map { value($0, "--title") } == [["sleep 跑完了"]])
    }

    /// 只交出命令名：参数、环境变量赋值不出 shell（用户定）
    @Test func onlyCommandNameLeavesShell() throws {
        let s = try Session()
        let calls = try s.run(["SECRET_TOKEN=abc env sleep 0.4 && echo password123"], expecting: 1)
        try #require(calls.count == 1)
        #expect(value(calls[0], "--title") == ["sleep 跑完了"])
        #expect(!calls[0].joined(separator: " ").contains("abc"))
        #expect(!calls[0].joined(separator: " ").contains("password123"))
        #expect(!calls[0].joined(separator: " ").contains("0.4"))
    }

    /// 前缀和它们带值的选项都跳过：选项的值也是参数，不能当成命令名交出去
    /// 合写的选项（-iu alice）看带值的那个字母在不在最后；值贴在选项上（-ualice、-uroot）就不再跳下一个词
    @Test(arguments: ["sudo -u alice sleep 0.4", "sudo -iu alice sleep 0.4", "sudo -ualice sleep 0.4", "sudo -uroot sleep 0.4",
                      "env -u FOO sleep 0.4", "nice -n 5 sleep 0.4", "( sleep 0.4 )", "{ sleep 0.4 }", "command sleep 0.4"])
    func prefixesSkipped(_ line: String) throws {
        let s = try Session()
        // 测试里不真的 sudo：同名函数只跑最后两个词（sleep 0.4）
        let calls = try s.run(["sudo() { \"${@[-2,-1]}\" }", line], expecting: 1)
        #expect(calls.map { value($0, "--title") } == [["sleep 跑完了"]])
    }

    /// 用户 shell 的选项不影响插件：shwordsplit 下标题不被拆开，ksharrays 下忽略表照样生效
    @Test func userOptionsDoNotLeakIn() throws {
        let s = try Session()
        let calls = try s.run(["setopt shwordsplit ksharrays", "vim() { sleep 0.4 }", "vim", "sleep 0.4"], expecting: 1)
        #expect(calls.map { value($0, "--title") } == [["sleep 跑完了"]])
    }

    /// 有终端时：同一个终端同组，点了跳回它
    @Test func terminalIdentity() throws {
        let s = try Session()
        let calls = try s.run(["sleep 0.4"], expecting: 1, pty: true)
        try #require(calls.count == 1)
        let tty = value(calls[0], "--tty")
        #expect(tty.count == 1 && tty[0].hasPrefix("/dev/tty"))
        #expect(value(calls[0], "--group") == tty.map { "tty:" + $0 })
        #expect(value(calls[0], "--pid").count == 1 && Int32(value(calls[0], "--pid")[0]) != nil)
        #expect(value(calls[0], "--cwd").count == 1)
    }
}
