import Foundation
import Darwin

/// 被动、只读地发现最近活跃的编程会话。
/// - 只读文件，从不写入、移动或加锁。
/// - 只提取元数据（cwd、类型、时间戳）；对话内容不会被保存、显示或写入日志。
struct AgentSession: Identifiable, Equatable {
    enum State: Equatable { case running, idle }
    let id: String          // 文件路径
    let agent: AgentKind
    let project: String
    let state: State
    let lastActivity: Date
    let turnStart: Date?
}

struct ProcessCounts: Equatable {
    var claude = 0

    static func current() -> ProcessCounts {
        var r = ProcessCounts()
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return r }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return r }
        var buf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(got)) where pid > 0 {
            if proc_name(pid, &buf, UInt32(buf.count)) > 0 {
                let name = String(cString: buf)
                if name == "claude" { r.claude += 1 }      // CLI（桌面 App 名为 "Claude"，不计入）
            }
        }
        return r
    }
}

enum SessionScanner {
    /// 默认 30 分钟；仅用于自检时可用环境变量 NK_SESSION_WINDOW_MIN 放宽（正常启动不会设置）。
    static let recentWindow: TimeInterval = {
        if let v = ProcessInfo.processInfo.environment["NK_SESSION_WINDOW_MIN"], let m = Double(v), m > 0 { return m * 60 }
        return 30 * 60
    }()
    static let maxSessions = 8

    static func scan(now: Date = Date()) -> [AgentSession] {
        var all = scanClaude(now: now) + scanCodex(now: now)
        all.sort {
            if ($0.state == .running) != ($1.state == .running) { return $0.state == .running }
            return $0.lastActivity > $1.lastActivity
        }
        return Array(all.prefix(maxSessions))
    }

    // MARK: Claude Code: ~/.claude/projects/<编码路径>/<session>.jsonl（不进入 subagents/ 子目录）

    static func scanClaude(now: Date) -> [AgentSession] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [AgentSession] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let m = mtime(f), now.timeIntervalSince(m) < recentWindow else { continue }
                if let s = parseClaude(f, mtime: m, now: now) { out.append(s) }
            }
        }
        return out
    }

    private enum Phase { case unknown, working, ended }

    static func parseClaude(_ url: URL, mtime: Date, now: Date) -> AgentSession? {
        var cwd: String?
        var phase = Phase.unknown
        var turnStart: Date?
        var sawMain = false
        for line in tailLines(url, bytes: 192 * 1024) {
            guard let d = json(line) else { continue }
            if (d["isSidechain"] as? Bool) == true { continue }   // 子 agent 侧链
            sawMain = true
            if let c = d["cwd"] as? String { cwd = c }
            let type = d["type"] as? String
            switch type {
            case "user":
                let isPrompt = d["toolUseResult"] == nil && d["isMeta"] == nil && d["sourceToolUseID"] == nil
                if isPrompt {
                    phase = .working
                    turnStart = date(d["timestamp"]) ?? turnStart
                }
            case "assistant":
                let stop = (d["message"] as? [String: Any])?["stop_reason"] as? String
                phase = (stop == "end_turn") ? .ended : .working
            case "system":
                let sub = d["subtype"] as? String
                if sub == "turn_duration" || sub == "stop_hook_summary" { phase = .ended }
            default: break
            }
        }
        guard sawMain else { return nil }
        let age = now.timeIntervalSince(mtime)
        let running = phase != .ended && age < 120
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? decodeProjectDir(url.deletingLastPathComponent().lastPathComponent)
        return AgentSession(id: url.path, agent: .claudeCode, project: project,
                            state: running ? .running : .idle, lastActivity: mtime,
                            turnStart: running ? turnStart : nil)
    }

    private static func decodeProjectDir(_ s: String) -> String {
        s.split(separator: "-").last.map(String.init) ?? s
    }

    // MARK: Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl（今天 + 昨天）

    static func scanCodex(now: Date) -> [AgentSession] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var out: [AgentSession] = []
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for f in files where f.pathExtension == "jsonl" && f.lastPathComponent.hasPrefix("rollout-") {
                guard let m = mtime(f), now.timeIntervalSince(m) < recentWindow else { continue }
                if let s = parseCodex(f, mtime: m, now: now) { out.append(s) }
            }
        }
        return out
    }

    /// Codex 子 agent：session_meta.payload.source 是 {"subagent": {...}}；主会话是 "cli" / "vscode" 等字符串
    static func isCodexSubagent(meta: [String: Any]) -> Bool {
        guard let p = meta["payload"] as? [String: Any] else { return false }
        if let src = p["source"] as? [String: Any], src["subagent"] != nil { return true }
        return false
    }

    static func parseCodex(_ url: URL, mtime: Date, now: Date) -> AgentSession? {
        guard let first = firstLine(url), let meta = json(first), (meta["type"] as? String) == "session_meta" else { return nil }
        if isCodexSubagent(meta: meta) { return nil }
        let cwd = (meta["payload"] as? [String: Any])?["cwd"] as? String
        var phase = Phase.unknown
        var turnStart: Date?
        for line in tailLines(url, bytes: 128 * 1024) {
            // 先做廉价的子串判断，避免解析大块内容
            guard line.contains("\"event_msg\""), let d = json(line),
                  let p = d["payload"] as? [String: Any], let t = p["type"] as? String else { continue }
            switch t {
            case "task_started", "turn_started":
                phase = .working
                turnStart = date(d["timestamp"])
            case "task_complete", "turn_complete", "turn_aborted":
                phase = .ended
            default: break
            }
        }
        let age = now.timeIntervalSince(mtime)
        let running: Bool
        switch phase {
        case .working: running = age < 600
        case .ended: running = false
        case .unknown: running = age < 30
        }
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
        return AgentSession(id: url.path, agent: .codex, project: project,
                            state: running ? .running : .idle, lastActivity: mtime,
                            turnStart: running ? turnStart : nil)
    }

    // MARK: 文件工具（只读）

    private static func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func tailLines(_ url: URL, bytes: Int) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return [] }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8)
                ?? String(data: data.dropFirst(min(4, data.count)), encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // 半行
        return lines
    }

    private static func firstLine(_ url: URL, limit: Int = 4 * 1024 * 1024) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var buf = Data()
        while buf.count < limit {
            guard let chunk = try? h.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            if let nl = chunk.firstIndex(of: 0x0A) {
                buf.append(chunk[chunk.startIndex..<nl])
                return String(data: buf, encoding: .utf8)
            }
            buf.append(chunk)
        }
        return String(data: buf, encoding: .utf8)
    }

    private static func json(_ s: Substring) -> [String: Any]? { json(String(s)) }
    private static func json(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
}
