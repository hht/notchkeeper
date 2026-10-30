import Foundation
import Testing
@testable import AgentCore

/// 照 10-29 实测的真实文件拼（docs/agent-integration.md「实测」），只改要测的字段
private func file(_ overrides: [String: Any?] = [:]) -> Data {
    var json: [String: Any] = [
        "pid": 31301, "sessionId": "5d0c7c2e-0000-4000-8000-000000000000", "cwd": "/Users/u/Documents/Projects/notchkeeper",
        "startedAt": 1793296492153, "procStart": "Thu Oct 29 17:54:51 2026", "version": "2.1.296", "peerProtocol": 1,
        "kind": "interactive", "entrypoint": "cli", "pidDomain": "darwin", "name": "不该被读的名字", "nameSource": "user",
        "status": "busy", "statusUpdatedAt": 1793304005799, "updatedAt": 1793304005799,
    ]
    for (k, v) in overrides { json[k] = v }
    return try! JSONSerialization.data(withJSONObject: json)
}

/// 2026-10-29 17:54:51 UTC
private let procStart = Date(timeIntervalSince1970: 1_793_296_491)

@Suite struct SessionFileParsing {
    @Test func busyCLISession() throws {
        #expect(try SessionFile.parse(file()) == Session(
            pid: 31301, processStart: procStart, cwd: "/Users/u/Documents/Projects/notchkeeper",
            state: .working, stateSince: Date(timeIntervalSince1970: 1_793_304_005.799)))
    }
}

@Suite struct SessionStateMapping {
    private func state(_ status: String, waitingFor: String? = nil) throws -> AgentState? {
        try SessionFile.parse(file(["status": status, "waitingFor": waitingFor]))?.state
    }

    @Test func busyIsWorking() throws {
        #expect(try state("busy") == .working)
    }

    /// `shell` 是空闲、但后台挂着 shell 命令（docs/agent-integration.md「实测」6）
    @Test func idleAndShellAreStopped() throws {
        #expect(try state("idle") == .stopped)
        #expect(try state("shell") == .stopped)
    }

    /// 照 Claude Code 自己的归类表：前四个是权限类（docs/agent-integration.md「实测」3）
    @Test(arguments: ["permission prompt", "sandbox request", "worker request", "goal proposal"])
    func permissionKindsNeedApproval(_ waitingFor: String) throws {
        #expect(try state("waiting", waitingFor: waitingFor) == .needsYou(.approval))
    }

    /// `dialog open`、没见过的取值、缺了 waitingFor：都还是需要你介入，归等你回答（用户 10-29）
    @Test(arguments: ["input needed", "dialog open", "something new", nil] as [String?])
    func otherWaitsAreQuestions(_ waitingFor: String?) throws {
        #expect(try state("waiting", waitingFor: waitingFor) == .needsYou(.question))
    }
}

/// 只看终端里开的交互式 claude（用户 10-29）：`claude -p` 的 kind 也是 interactive，要靠 entrypoint 排除
@Suite struct SessionFiltering {
    @Test(arguments: ["sdk-cli", "sdk-ts", "sdk-py", "claude-vscode", "claude-desktop", "remote"])
    func otherEntrypointsAreIgnored(_ entrypoint: String) throws {
        #expect(try SessionFile.parse(file(["entrypoint": entrypoint])) == nil)
    }

    @Test(arguments: ["bg", "daemon", "daemon-worker"])
    func otherKindsAreIgnored(_ kind: String) throws {
        #expect(try SessionFile.parse(file(["kind": kind])) == nil)
    }

    /// 会话刚起来时第一次写的文件没有 status、statusUpdatedAt，过一会儿原地补上（10-29 实测）：还没有状态，先不看，也不算解不开
    @Test func sessionWithoutStatusYetIsIgnored() throws {
        #expect(try SessionFile.parse(file(["status": nil, "statusUpdatedAt": nil, "updatedAt": nil])) == nil)
    }

    /// 不看的会话，别的字段缺了、状态不认识也不算解不开
    @Test func ignoredSessionIsNotValidated() throws {
        #expect(try SessionFile.parse(file(["entrypoint": "sdk-cli", "status": "bogus", "procStart": nil])) == nil)
    }
}

@Suite struct SessionFileBoundary {
    /// ps 的 lstart 日期个位数时前面补空格（%e）
    @Test func singleDigitDayIsSpacePadded() throws {
        let s = try SessionFile.parse(file(["procStart": "Mon Nov  2 03:04:05 2026"]))
        #expect(s?.processStart == Date(timeIntervalSince1970: 1_793_588_645)) // 2026-11-02T03:04:05Z
    }

    @Test(arguments: ["", "Thu Oct 29 2026", "2026-10-29T17:54:51Z"])
    func badProcStartThrows(_ text: String) {
        #expect(throws: (any Error).self) { try SessionFile.parse(file(["procStart": text])) }
    }

    @Test func unknownStatusThrows() {
        #expect(throws: SessionFileError.unknownStatus("thinking")) { try SessionFile.parse(file(["status": "thinking"])) }
    }

    @Test(arguments: ["pid", "procStart", "cwd", "statusUpdatedAt"])
    func missingFieldThrows(_ key: String) {
        #expect(throws: (any Error).self) { try SessionFile.parse(file([key: nil])) }
    }

    /// 写到一半的文件
    @Test func truncatedJSONThrows() {
        #expect(throws: (any Error).self) { try SessionFile.parse(Data(#"{"pid":1,"kind":"interactive""#.utf8)) }
    }
}
