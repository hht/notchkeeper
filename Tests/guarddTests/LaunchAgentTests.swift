import Foundation
import Testing

/// Slice 5 的安装文件。脚本在这里只跑 `--dry-run`，而且 HOME 指向临时目录、PATH 最前面放了会记账的
/// 假 `launchctl` / `swift` / `sudo` / `codesign`：dry-run 哪怕误调了它们，也只会记一笔，不会真装。
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let template = root.appendingPathComponent("Resources/guardd/com.notchkeeper.guardd.plist")
private let label = "com.notchkeeper.guardd"

private struct Sandbox {
    let home: URL
    let shims: URL
    let calls: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nk sandbox \(UUID().uuidString)") // 带空格，测引号
        home = base.appendingPathComponent("home dir")
        shims = base.appendingPathComponent("shims")
        calls = base.appendingPathComponent("calls.log")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        for tool in ["launchctl", "swift", "sudo", "codesign"] {
            let shim = shims.appendingPathComponent(tool)
            try "#!/bin/sh\necho \"\(tool) $*\" >> \"\(calls.path)\"\nexit 1\n".write(to: shim, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        }
    }

    func run(_ script: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/\(script)").path] + arguments
        // UTF-8 locale 和用户的终端一样：bash 3.2 在这个 locale 下会把紧跟 `$VAR` 的中文字符当成变量名的一部分
        p.environment = ["HOME": home.path, "PATH": "\(shims.path):/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// 外部工具一次都没被调用过
    var toolCalls: String { (try? String(contentsOf: calls, encoding: .utf8)) ?? "" }

    func files() -> [String] {
        (FileManager.default.subpaths(atPath: home.path) ?? []).sorted()
    }
}

private func plist(_ data: Data) throws -> [String: Any] {
    try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

/// dry-run 输出里两行标记之间是将要写入的 plist 原文
private func renderedPlist(_ output: String) throws -> [String: Any] {
    let parts = output.components(separatedBy: "----- plist -----\n")
    try #require(parts.count == 2)
    let body = try #require(parts[1].components(separatedBy: "----- end plist -----").first)
    return try plist(Data(body.utf8))
}

@Suite struct LaunchAgentTemplate {
    @Test func isAPerUserAgentThatRestartsOnCrash() throws {
        let p = try plist(Data(contentsOf: template))
        #expect(Set(p.keys) == ["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "ThrottleInterval",
                                "StandardOutPath", "StandardErrorPath"]) // 没有 UserName / GroupName：不是 root 的 daemon
        #expect(p["Label"] as? String == label)
        #expect(p["ProgramArguments"] as? [String] == ["__GUARDD_PATH__"])
        #expect(p["RunAtLoad"] as? Bool == true)
        #expect(p["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(p["ThrottleInterval"] as? Int == 10)
        #expect(p["StandardOutPath"] as? String == "__LOG_PATH__")
        #expect(p["StandardErrorPath"] as? String == "__LOG_PATH__")
    }
}

@Suite struct InstallScripts {
    @Test func installDryRunPrintsPlanAndChangesNothing() throws {
        let box = try Sandbox()
        let r = try box.run("install-guardd.sh", ["--dry-run"])
        #expect(r.status == 0, "\(r.output)")
        #expect(box.toolCalls == "")
        #expect(box.files() == [])
        let home = box.home.path
        let bin = "\(home)/Library/Application Support/Notchkeeper/bin/guardd"
        let p = try renderedPlist(r.output)
        #expect(p["ProgramArguments"] as? [String] == [bin])
        #expect(p["StandardOutPath"] as? String == "\(home)/Library/Logs/Notchkeeper/guardd.log")
        #expect(!r.output.contains("__"))
        #expect(r.output.contains("swift build -c release --product guardd"))
        #expect(r.output.contains("launchctl bootstrap gui/\(getuid())"))
        #expect(r.output.contains("\(home)/Library/LaunchAgents/\(label).plist"))
        #expect(!r.output.contains("sudo"))
    }

    @Test func installDryRunBacksUpExistingPlistFirst() throws {
        let box = try Sandbox()
        let agents = box.home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let existing = agents.appendingPathComponent("\(label).plist")
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        let r = try box.run("install-guardd.sh", ["--dry-run"])
        #expect(r.status == 0)
        let lines = r.output.split(separator: "\n").map(String.init)
        let backup = try #require(lines.firstIndex { $0.hasPrefix("+ cp -p") && $0.contains("backup") })
        let write = try #require(lines.firstIndex { $0.contains("写入") && $0.contains("LaunchAgents") })
        #expect(backup < write)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
        #expect(box.toolCalls == "")
    }

    @Test func uninstallDryRunKeepsLogsAndStateByDefault() throws {
        let box = try Sandbox()
        let r = try box.run("uninstall-guardd.sh", ["--dry-run"])
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("launchctl bootout gui/\(getuid())/\(label)"))
        #expect(r.output.contains("LaunchAgents/\(label).plist"))
        #expect(r.output.contains("Notchkeeper/bin/guardd"))
        #expect(!r.output.contains("Logs/Notchkeeper"))
        #expect(!r.output.contains("guard-state.json"))
        #expect(!r.output.contains("config.json"))
        #expect(box.toolCalls == "")
    }

    @Test func uninstallPurgeAlsoRemovesLogsAndStateButNeverConfig() throws {
        let box = try Sandbox()
        let r = try box.run("uninstall-guardd.sh", ["--dry-run", "--purge"])
        #expect(r.status == 0, "\(r.output)")
        #expect(r.output.contains("Logs/Notchkeeper/guardd.log"))
        #expect(r.output.contains("guard-state.json"))
        #expect(!r.output.contains("rm -rf")) // 日志目录里还有 App 自己的 notchkeeper.log，只删 guardd.log
        #expect(!r.output.contains("config.json"))
        #expect(box.toolCalls == "")
    }

    @Test func installDryRunBacksUpExistingBinaryBeforeReplacingIt() throws {
        let box = try Sandbox()
        let bin = box.home.appendingPathComponent("Library/Application Support/Notchkeeper/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let existing = bin.appendingPathComponent("guardd")
        try "old".write(to: existing, atomically: true, encoding: .utf8)
        let r = try box.run("install-guardd.sh", ["--dry-run"])
        #expect(r.status == 0, "\(r.output)")
        let lines = r.output.split(separator: "\n").map(String.init)
        let backup = try #require(lines.firstIndex { $0.hasPrefix("+ cp -p") && $0.contains("backup/guardd.") })
        let replace = try #require(lines.firstIndex { $0.hasPrefix("+ mv -f") && $0.contains("guardd.new") })
        #expect(backup < replace)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "old")
        #expect(box.toolCalls == "")
    }

    /// 两个脚本只动 guardd 自己的文件：不碰 pf、网络设置、DNS、路由、shell 配置，也不提权
    @Test(arguments: [("install-guardd.sh", ["--dry-run"]), ("uninstall-guardd.sh", ["--dry-run", "--purge"])])
    func dryRunNeverTouchesNetworkOrShellConfig(_ script: String, _ arguments: [String]) throws {
        let box = try Sandbox()
        let r = try box.run(script, arguments)
        #expect(r.status == 0, "\(r.output)")
        for word in ["sudo", "osascript", "pfctl", "anchor", "networksetup", "scutil", "route ", "dscacheutil",
                     ".zshrc", "LaunchDaemons", "config.json", "Clash", "clash"] {
            #expect(!r.output.contains(word), "\(word)")
        }
        #expect(box.toolCalls == "")
    }

    @Test(arguments: ["install-guardd.sh", "uninstall-guardd.sh"])
    func unknownArgumentIsRejected(_ script: String) throws {
        let box = try Sandbox()
        #expect(try box.run(script, ["--bogus"]).status == 64)
        #expect(box.toolCalls == "")
        #expect(box.files() == [])
    }
}
