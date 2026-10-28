import AppKit
import SwiftUI

// MARK: - 支持的 agent

enum AgentKind: String, CaseIterable, Codable, Identifiable {
    case claudeCode = "claude-code"
    case codex
    case zcode
    case grokBuild = "grok-build"
    case opencode
    case dsh
    case devin
    case antigravity
    case cursorAgent = "cursor-agent"
    case trae
    case droid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .zcode: return "ZCode"
        case .grokBuild: return "Grok Build"
        case .opencode: return "OpenCode"
        case .dsh: return "DSH"
        case .devin: return "Devin"
        case .antigravity: return "Antigravity"
        case .cursorAgent: return "Cursor Agent"
        case .trae: return "Trae"
        case .droid: return "Droid"
        }
    }

    /// 通用图形，不使用任何品牌标志
    var symbol: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .zcode: return "z.square"
        case .grokBuild: return "hammer"
        case .opencode: return "curlybraces"
        case .dsh: return "terminal"
        case .devin: return "person.crop.square"
        case .antigravity: return "arrow.up.circle"
        case .cursorAgent: return "cursorarrow.rays"
        case .trae: return "wind"
        case .droid: return "cpu"
        }
    }

    var tint: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.36, green: 0.55, blue: 0.98)
        case .zcode: return .indigo
        case .grokBuild: return .gray
        case .opencode: return .teal
        case .dsh: return .mint
        case .devin: return .cyan
        case .antigravity: return .purple
        case .cursorAgent: return Color(white: 0.55)
        case .trae: return .green
        case .droid: return .orange
        }
    }

    /// 下一阶段接入方式：每个 agent 只用 1 个“回合结束”钩子
    var hookMechanism: String {
        switch self {
        case .claudeCode: return "Stop hook（不装 SubagentStop）"
        case .codex: return "notify 1 行配置"
        case .grokBuild: return "通知 hook"
        case .opencode: return "session.idle 插件"
        case .cursorAgent: return "stop hook"
        case .antigravity: return "Stop hook（fullyIdle）"
        default: return "Stop hook"
        }
    }

    /// 悬停面板的会话列表目前能被动读取的 agent
    var passiveSessionSupport: Bool { self == .claudeCode || self == .codex }

    /// “宿主 App 在前台时不提示”用到的宿主 bundle id
    var hostBundleIDs: Set<String> {
        let terminals: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
        ]
        switch self {
        case .cursorAgent: return terminals.union(["com.todesktop.230313mzl4w4u92"])
        case .trae: return terminals.union(["com.trae.app"])
        case .antigravity: return terminals.union(["com.google.antigravity"])
        case .codex: return terminals.union(["com.openai.codex", "com.microsoft.VSCode"])
        default: return terminals.union(["com.microsoft.VSCode"])
        }
    }
}

// MARK: - 事件模型（M2 只设计，不接线；不安装任何 hook）

/// 所有来源（hook 收件箱 / 文件尾随）归一成同一种事件。
struct AgentEvent: Equatable {
    enum Kind: String { case completed, failed, aborted, needsInput }
    enum Source: String { case hook, file }

    var agent: AgentKind
    var sessionId: String
    var turnId: String?
    var cwd: String?
    var kind: Kind
    /// 子 agent / 侧链产生的事件，永远不提示
    var isSubagent: Bool
    /// Claude 系 Stop hook 的 stop_hook_active：true 表示是 hook 让它继续后的又一次 Stop，不提示
    var stopHookActive: Bool
    var timestamp: Date
    var source: Source

    var project: String { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—" }
    var dedupKey: String { "\(agent.rawValue)|\(sessionId)|\(turnId ?? "-")" }
}

/// 把各家 hook 的 stdin JSON 解析成 AgentEvent。只读取元数据字段，不读取 / 不记录对话内容。
enum HookPayloadParser {
    /// codexSubagentResolver: 给定 Codex thread id，返回该会话是否子 agent
    /// （读 rollout 首行 session_meta.source 是否为 {"subagent": …}）
    static func parse(agent: AgentKind, json j: [String: Any], now: Date = Date(),
                      codexSubagentResolver: (String) -> Bool = { _ in false }) -> AgentEvent? {
        func s(_ k: String) -> String? { j[k] as? String }
        func b(_ k: String) -> Bool { (j[k] as? Bool) ?? false }

        switch agent {
        case .claudeCode, .zcode, .dsh, .devin, .droid:
            // Claude 兼容格式：只有 hook_event_name == "Stop" 是主会话回合结束；
            // SubagentStop 是独立事件（我们不会安装它，这里也显式过滤）
            let name = s("hook_event_name") ?? "Stop"
            guard name == "Stop" || name == "SubagentStop" else { return nil }
            return AgentEvent(agent: agent, sessionId: s("session_id") ?? "?", turnId: nil, cwd: s("cwd"),
                              kind: .completed, isSubagent: name == "SubagentStop" || b("isSidechain"),
                              stopHookActive: b("stop_hook_active"), timestamp: now, source: .hook)

        case .antigravity:
            // 只有 fullyIdle == true 且 terminationReason == model_stop 才算真正结束
            let idle = b("fullyIdle")
            let reason = s("terminationReason") ?? ""
            guard idle else { return nil }
            return AgentEvent(agent: agent, sessionId: s("session_id") ?? s("conversationId") ?? "?", turnId: nil,
                              cwd: s("cwd"), kind: reason == "model_stop" ? .completed : .aborted,
                              isSubagent: b("isSubagent"), stopHookActive: b("stop_hook_active"),
                              timestamp: now, source: .hook)

        case .codex:
            // notify 载荷：{"type":"agent-turn-complete","thread-id":…,"turn-id":…,"cwd":…}
            guard s("type") == "agent-turn-complete", let thread = s("thread-id") else { return nil }
            return AgentEvent(agent: agent, sessionId: thread, turnId: s("turn-id"), cwd: s("cwd"),
                              kind: .completed, isSubagent: codexSubagentResolver(thread),
                              stopHookActive: false, timestamp: now, source: .hook)

        case .cursorAgent:
            // stop hook：status completed/aborted/error；loop_count > 0 说明是 hook 触发的续跑
            let status = s("status") ?? "completed"
            let loops = (j["loop_count"] as? Int) ?? 0
            let kind: AgentEvent.Kind = status == "completed" ? .completed : (status == "error" ? .failed : .aborted)
            return AgentEvent(agent: agent, sessionId: s("conversation_id") ?? "?", turnId: s("generation_id"),
                              cwd: (j["workspace_roots"] as? [String])?.first, kind: kind,
                              isSubagent: s("hook_event_name") == "subagentStop",
                              stopHookActive: loops > 0, timestamp: now, source: .hook)

        case .grokBuild, .opencode, .trae:
            let kindStr = s("session_kind") ?? s("kind") ?? "main"
            return AgentEvent(agent: agent, sessionId: s("session_id") ?? "?", turnId: s("turn_id"), cwd: s("cwd"),
                              kind: .completed, isSubagent: kindStr == "subagent" || b("isSubagent"),
                              stopHookActive: b("stop_hook_active"), timestamp: now, source: .hook)
        }
    }
}

/// 决定一个事件是否弹绿卡。
enum CompletionFilter {
    enum Decision: Equatable {
        case alert
        case suppress(String)
    }

    static func decide(_ e: AgentEvent, config: NKConfig, frontmostBundleID: String?) -> Decision {
        if e.isSubagent { return .suppress("子 agent") }
        if e.stopHookActive { return .suppress("stop_hook_active（hook 续跑）") }
        if e.kind == .aborted { return .suppress("用户中断") }
        if !config.agentEnabled(e.agent) { return .suppress("该 agent 通知已关闭") }
        if config.suppressWhenHostFrontmost, let fm = frontmostBundleID, e.agent.hostBundleIDs.contains(fm) {
            return .suppress("宿主 App 在前台")
        }
        return .alert
    }
}

/// 同一回合可能同时来自 hook 与文件尾随：3 秒内同 key 只算一次，hook 优先。
final class TurnDeduper {
    private var seen: [String: (Date, AgentEvent.Source)] = [:]
    let window: TimeInterval
    init(window: TimeInterval = 3) { self.window = window }

    func accept(_ e: AgentEvent) -> Bool {
        seen = seen.filter { e.timestamp.timeIntervalSince($0.value.0) < 60 }
        if let (t, src) = seen[e.dedupKey], e.timestamp.timeIntervalSince(t) < window {
            if src == .file && e.source == .hook { seen[e.dedupKey] = (e.timestamp, .hook) }
            return false
        }
        seen[e.dedupKey] = (e.timestamp, e.source)
        return true
    }
}

// MARK: - 自检（scripts/run.sh 之后可运行 `Notchkeeper --selftest`）

enum SelfTest {
    static func run() -> Bool {
        var ok = true
        let cfg = NKConfig()
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "PASS" : "FAIL")  \(name)")
            if !cond { ok = false }
        }
        let main = HookPayloadParser.parse(agent: .claudeCode, json: ["hook_event_name": "Stop", "session_id": "a", "stop_hook_active": false])!
        check("Claude Stop 主会话 → 提示", CompletionFilter.decide(main, config: cfg, frontmostBundleID: nil) == .alert)
        let sub = HookPayloadParser.parse(agent: .claudeCode, json: ["hook_event_name": "SubagentStop", "session_id": "a"])!
        check("Claude SubagentStop → 不提示", CompletionFilter.decide(sub, config: cfg, frontmostBundleID: nil) != .alert)
        let again = HookPayloadParser.parse(agent: .droid, json: ["hook_event_name": "Stop", "session_id": "a", "stop_hook_active": true])!
        check("stop_hook_active → 不提示", CompletionFilter.decide(again, config: cfg, frontmostBundleID: nil) != .alert)
        let cx = HookPayloadParser.parse(agent: .codex, json: ["type": "agent-turn-complete", "thread-id": "t1"],
                                         codexSubagentResolver: { $0 == "t1" })!
        check("Codex 子 agent 线程 → 不提示", CompletionFilter.decide(cx, config: cfg, frontmostBundleID: nil) != .alert)
        let cur = HookPayloadParser.parse(agent: .cursorAgent, json: ["status": "completed", "loop_count": 1])!
        check("Cursor loop_count>0 → 不提示", CompletionFilter.decide(cur, config: cfg, frontmostBundleID: nil) != .alert)
        check("宿主在前台 → 不提示", CompletionFilter.decide(main, config: cfg, frontmostBundleID: "com.apple.Terminal") != .alert)
        let ag = HookPayloadParser.parse(agent: .antigravity, json: ["fullyIdle": false])
        check("Antigravity 未 fullyIdle → 无事件", ag == nil)
        let d = TurnDeduper()
        var f = main; f.source = .file
        check("去重：首个事件通过", d.accept(f))
        check("去重：3 秒内重复被吞", !d.accept(main))

        let sessions = SessionScanner.scan()
        let procs = ProcessCounts.current()
        print("INFO  会话（近 \(Int(SessionScanner.recentWindow / 60)) 分钟，仅主会话）: \(sessions.count)，运行中 \(sessions.filter { $0.state == .running }.count)")
        for s in sessions {   // 只打印 agent / 状态 / 距今分钟，不打印项目名与任何对话内容
            print("INFO    · \(s.agent.displayName) \(s.state == .running ? "运行中" : "空闲") \(Int(Date().timeIntervalSince(s.lastActivity) / 60)) 分钟前")
        }
        for a in [AgentKind.claudeCode, .codex] {
            print("INFO    \(a.displayName): \(sessions.filter { $0.agent == a }.count)")
        }
        print("INFO  进程: claude×\(procs.claude) codex×\(procs.codex)")
        print("INFO  开机启动状态: \(LoginItem.statusText)")
        return ok
    }
}
