import AgentCore
import Foundation
import Testing
@testable import AgentWatch

/// 合成的会话行，不来自真实文件
private func rec(_ type: String, _ at: Date, stop: String? = nil, body: String = "x") -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var o: [String: Any] = ["type": type, "timestamp": f.string(from: at), "cwd": "/tmp/demo-proj", "isSidechain": false,
                            "message": ["content": body]]
    if let stop { o["message"] = ["content": body, "stop_reason": stop] }
    return String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private final class Tree {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nk-agentwatch-\(UUID().uuidString)")
    func write(_ rel: String, _ text: String, mtime: Date = now) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Suite struct SessionFiles {
    @Test func findsMainSessionsOnlyNewestFirst() throws {
        let t = Tree()
        try t.write("-p/a.jsonl", rec("user", now - 100), mtime: now - 100)
        try t.write("-p/b.jsonl", rec("user", now - 10), mtime: now - 10)
        try t.write("-p/b/subagents/agent-1.jsonl", rec("user", now - 5), mtime: now - 5)
        try t.write("-p/old.jsonl", rec("user", now - 7200), mtime: now - 7200)
        try t.write("-p/notes.txt", "x", mtime: now)
        let files = ClaudeSessionFiles(root: t.root, recentWindow: 3600, maxFiles: 10)
        #expect(try files.mainSessionFiles(now: now).map(\.id) == ["b", "a"])
        #expect(try ClaudeSessionFiles(root: t.root, recentWindow: 3600, maxFiles: 1).mainSessionFiles(now: now).map(\.id) == ["b"])
    }

    @Test func missingRootIsEmptyNotACrash() throws {
        let files = ClaudeSessionFiles(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(files.scan(now: now).sessions.isEmpty)
    }

    /// 只读尾部：前面的大块内容（这里是 200KB 的一条 user 记录）不会被读到，判定只看尾部
    @Test func readsOnlyTheTail() throws {
        let t = Tree()
        let huge = rec("user", now - 50, body: String(repeating: "y", count: 200_000))
        try t.write("-p/s.jsonl", rec("user", now - 60) + huge + rec("assistant", now - 40, stop: "tool_use")
                    + rec("user", now - 30) + rec("assistant", now - 20, stop: "end_turn"))
        let files = ClaudeSessionFiles(root: t.root)
        let lines = try ClaudeSessionFiles.tailLines(of: t.root.appendingPathComponent("-p/s.jsonl"), bytes: 64 * 1024)
        #expect(lines.count == 3)   // 半行被丢掉
        #expect(files.scan(now: now).sessions.map(\.state) == [.finished])
        #expect(files.scan(now: now).sessions.first?.turnStartedAt == now - 40)   // 窗口里第一条 working 记录
    }

    /// 尾部 64KB 里只有一条巨大记录的残片时，放大窗口再读一次，仍然不读整个文件
    @Test func widensOnceWhenTailHasNoRecord() throws {
        let t = Tree()
        try t.write("-p/s.jsonl", rec("user", now - 60) + rec("user", now - 50, body: String(repeating: "y", count: 100_000)))
        #expect(ClaudeSessionFiles(root: t.root).scan(now: now).sessions.map(\.state) == [.working])
    }

    @Test func malformedLinesAreCounted() throws {
        let t = Tree()
        try t.write("-p/s.jsonl", "garbage\n" + rec("user", now - 5) + "{\"broken\"\n")
        let r = ClaudeSessionFiles(root: t.root).scan(now: now)
        #expect(r.malformedLines == 2)
        #expect(r.sessions.count == 1)
    }

    @Test func appliesStaleFallbackWithInjectedClock() throws {
        let t = Tree()
        try t.write("-p/s.jsonl", rec("user", now - 200) + rec("assistant", now - 150, stop: "tool_use"), mtime: now - 150)
        #expect(ClaudeSessionFiles(root: t.root).scan(now: now).sessions.map(\.state) == [.stale])
        #expect(ClaudeSessionFiles(root: t.root).scan(now: now - 100).sessions.map(\.state) == [.working])
    }

    @MainActor @Test func watcherEmitsOnTransition() async throws {
        let t = Tree()
        try t.write("-p/s.jsonl", rec("user", now - 10))
        let w = ClaudeSessionWatcher(files: ClaudeSessionFiles(root: t.root), clock: { now })
        var updates: [[AgentSession]] = []
        w.onUpdate = { sessions, _ in updates.append(sessions) }
        #expect(await w.tick().isEmpty)
        try t.write("-p/s.jsonl", rec("user", now - 10) + rec("assistant", now - 1, stop: "end_turn"))
        #expect(await w.tick() == [.finished(sessionID: "s", kind: .claudeCode, project: "demo-proj", duration: .seconds(9))])
        #expect(await w.tick().isEmpty)
        #expect(updates.map { $0.map(\.state) } == [[.working], [.finished], [.finished]])
    }

    /// start() 之后在主线程上反复回调；stop() 之后不再回调
    @MainActor @Test func startDeliversOnMainAndStopHalts() async throws {
        let t = Tree()
        try t.write("-p/s.jsonl", rec("user", now - 10))
        let w = ClaudeSessionWatcher(files: ClaudeSessionFiles(root: t.root), interval: .milliseconds(20), clock: { now })
        var count = 0
        w.onUpdate = { _, _ in MainActor.assertIsolated(); count += 1 }
        w.start()
        w.start()
        for _ in 0..<200 where count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(count >= 3)
        w.stop()
        let stopped = count
        try await Task.sleep(for: .milliseconds(150))
        #expect(count == stopped)
    }
}

/// 实机只读检查：`NOTCHKEEPER_LIVE_AGENTS=1 swift test --filter LiveAgents`。只打印各状态的个数，不打印路径和正文。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NOTCHKEEPER_LIVE_AGENTS"] == "1"))
struct LiveAgents {
    @Test func countsPerState() {
        let r = ClaudeSessionFiles(recentWindow: 7 * 24 * 3600, maxFiles: 200).scan(now: Date())
        var c: [String: Int] = [:]
        for s in r.sessions {
            let k: String
            switch s.state {
            case .working: k = "working"
            case .finished: k = "finished"
            case .error(let e): k = "error(\(e.rawValue))"
            case .interrupted: k = "interrupted"
            case .stale: k = "stale"
            }
            c[k, default: 0] += 1
        }
        print("LIVE " + c.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
              + " sessions=\(r.sessions.count) malformed=\(r.malformedLines)")
    }
}
