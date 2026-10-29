import AppKit
import SwiftUI
import GuardCore
import GuardWatch

// MARK: - 支持的 agent

enum AgentKind: String, CaseIterable, Codable, Identifiable {
    case claudeCode = "claude-code"
    case codex
    case zcode
    case grokBot = "grok-bot"
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
        case .grokBot: return "Grok Bot"
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
        case .claudeCode: return "apple.terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .zcode: return "z.square"
        case .grokBot: return "bubble.left"
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
        case .claudeCode: return Color(white: 0.62)
        case .codex: return Color(red: 0.36, green: 0.55, blue: 0.98)
        case .zcode: return .indigo
        case .grokBot: return .gray
        case .opencode: return .teal
        case .dsh: return .mint
        case .devin: return .cyan
        case .antigravity: return .purple
        case .cursorAgent: return Color(white: 0.55)
        case .trae: return .green
        case .droid: return .orange
        }
    }

    /// 刘海展开后的会话列表目前能被动读取的 agent
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

        case .grokBot, .opencode, .trae:
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

@MainActor
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        let cfg = NKConfig()
        func check(_ name: String, _ cond: Bool) {
            print("\(cond ? "PASS" : "FAIL")  \(name)")
            if !cond { ok = false }
        }
        // 隔离前提：没在临时 HOME 里就什么都不跑，免得写到真实 ~/Library（依次求值，前一个不过就不碰后面的）
        let paths: [() -> URL] = [{ Log.url }, { GuardPaths.directory }, { ConfigStore.shared.url }]
        let isolated = paths.allSatisfy { !TestHome.isUnderRealHome($0()) }
        check("隔离：日志、guard-state、配置都不在真实主目录下", isolated)
        guard isolated else { return false }
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
        let dec = { (j: String) in try? JSONDecoder().decode(NKConfig.self, from: Data(j.utf8)) }
        check("完成卡时长：默认 6 秒，超出 2–10 被夹住",
              dec("{}")?.cardAutoDismissSeconds == 6 && dec(#"{"cardAutoDismissSeconds":15}"#)?.cardAutoDismissSeconds == 10
              && dec(#"{"cardAutoDismissSeconds":1}"#)?.cardAutoDismissSeconds == 2)
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
        print("INFO  进程: claude×\(procs.claude)")
        print("INFO  开机启动状态: \(LoginItem.statusText)")
        check("配置：默认允许列表为空（代码里不内置真实出口 IP）", NKConfig().allowlist.isEmpty)
        check("配置：空的 config.json 解出来每个字段都等于默认值（含空允许列表）",
              (try? JSONDecoder().decode(NKConfig.self, from: Data("{}".utf8))) == NKConfig())
        guardTests(check)
        singleInstanceTests(check)
        notchEarTests(check)
        stateTestTests(check)
        let delegate = AppDelegate()  // 菜单项的 target 是弱引用
        let menu = delegate.buildMainMenu()
        let comma = menu.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }
        check("⌘, 打开设置（齿轮走的也是 openSettings）", comma?.action == #selector(AppDelegate.openSettings) && comma?.target === delegate)
        // 盾盾（mascot-port-batch1.md、Emily 2026-10-28）
        check("盾盾：守卫状态压过晕和犯困", DundunState.shown(base: .guardViolated, dizzy: true, drowsy: true) == .guardViolated)
        check("盾盾：晕压过犯困", DundunState.shown(base: .idle, dizzy: true, drowsy: true) == .dizzy)
        check("盾盾：idle 且犯困 → 睡着", DundunState.shown(base: .idle, dizzy: false, drowsy: true) == .sleeping)
        check("盾盾：红盾回到正常 → 头像不另外开心，开心跟着恢复卡", !DundunState.celebrates(from: .guardViolated, to: .idle))
        check("盾盾：恢复卡出场开心，红卡不开心", NotchCard.recovered.mascotEmote == .cheer && NotchCard.exitAlert().mascotEmote == .none)
        check("盾盾：黄盾回到正常 → 开心", DundunState.celebrates(from: .guardMismatch, to: .idle))
        check("盾盾：灰盾回到正常 → 不庆祝", !DundunState.celebrates(from: .guardUnknown, to: .idle))
        check("盾盾：红盾变灰盾 → 不庆祝", !DundunState.celebrates(from: .guardViolated, to: .guardUnknown))
        check("盾盾：鼠标在刘海里距离为 0", DundunDirector.distance(from: NSPoint(x: 5, y: 5), to: NSRect(x: 0, y: 0, width: 10, height: 10)) == 0)
        check("盾盾：鼠标在刘海右下 (3,4) 处距离为 5", DundunDirector.distance(from: NSPoint(x: 13, y: -4), to: NSRect(x: 0, y: 0, width: 10, height: 10)) == 5)
        return ok
    }
}

// MARK: - 出口守卫显示和红卡（Vera 清单）

@MainActor
extension SelfTest {
    /// 第一层测纯函数 GuardPresentation；第二层用真的 GuardStateReader 解 guard-state.json，
    /// 驱动真的 AppState 和 NotchController（不上屏、不出声，声音记进数组）
    static func guardTests(_ check: (String, Bool) -> Void) {
        typealias P = GuardPresentation
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let t1 = t0.addingTimeInterval(600)

        // 第一层：纯函数
        func p(_ v: Verdict, _ r: UnknownReason? = nil, last: Verdict? = nil, since: Date? = nil, dismissed: Date?? = nil) -> P {
            P(verdict: v, unknownReason: r, lastVerdict: last ?? (v == .unknown ? nil : v), violatedSince: since,
              dismissedViolationSince: dismissed)
        }
        check("显示：healthy「出口正常」，无红卡", p(.healthy).title == "出口正常" && p(.healthy).alert == nil)
        check("显示：mismatch 琥珀、无红卡", p(.egressMismatch).tone == .mismatch && p(.egressMismatch).alert == nil
              && p(.egressMismatch).title == "出口 IP 和预期不一致")
        check("显示：unknown offline 灰环 + 文案", p(.unknown, .offline, last: .unknown).tone == .unknown
              && p(.unknown, .offline, last: .unknown).title == "网络不通，暂时没法检查出口")
        check("显示：unknown probeFailed 文案", p(.unknown, .probeFailed, last: .unknown).title == "暂时查不到出口")
        check("显示：missing / unreadable / newerSchema →「守卫没有响应」灰环、无红卡",
              p(.unknown).title == "守卫没有响应" && p(.unknown).tone == .unknown && p(.unknown).alert == nil)
        check("显示：violated 红卡 + Basso", p(.violated, since: t0).alert == P.Alert(detail: P.violatedDetail, sounds: true))
        let held = p(.unknown, last: .violated, since: t0)
        check("显示：stale 且 lastVerdict violated → 红卡保留、新副标题、不响", held.tone == .violated
              && held.alert == P.Alert(detail: P.unresponsiveDetail, sounds: false))
        check("显示：stale 且 lastVerdict healthy →「守卫没有响应」无红卡",
              p(.unknown, last: .healthy).title == "守卫没有响应" && p(.unknown, last: .healthy).alert == nil)
        let dv = p(.violated, since: t0, dismissed: .some(t0))
        check("关掉：同一次违规 → 无红卡、红点", dv.alert == nil && dv.tone == .violated)
        let ds = p(.unknown, last: .violated, since: t0, dismissed: .some(t0))
        check("关掉：同一次违规且守卫不响应 → 无红卡、灰环", ds.alert == nil && ds.tone == .unknown)
        check("关掉：新的 violatedSince → 红卡再弹", p(.violated, since: t1, dismissed: .some(t0)).alert?.sounds == true)
        check("关掉：旧 guardd 没写 violatedSince，关掉记 nil 也算",
              p(.violated, dismissed: .some(nil)).alert == nil && p(.violated).alert != nil)

        // 第二层：真的 reader + AppState + NotchController
        let iso = ISO8601DateFormatter()
        var now = t0
        func file(_ v: String, at: Date? = nil, reason: String? = nil, since: Date? = nil, ip: String? = nil) -> Data {
            var j: [String: Any] = ["schemaVersion": 1, "verdict": v, "checkedAt": iso.string(from: at ?? now), "egressFailures": [String: Int]()]
            if let reason { j["unknownReason"] = reason }
            if let since { j["violatedSince"] = iso.string(from: since) }
            if let ip { j["egressIP"] = ip }
            return try! JSONSerialization.data(withJSONObject: j)
        }
        enum R { case healthy, mismatch, offline, violated(Date), stale(Date), skew(Date), missing }
        @MainActor final class Rig {
            var cfg = NKConfig()
            var sounds: [String] = []
            let state = AppState()
            let notch: NotchController
            init() {
                weak var me: Rig?
                notch = NotchController(config: { me?.cfg ?? NKConfig() }, playSound: { me?.sounds.append($0) }, onScreen: false)
                me = self
                state.onPresentation = { [unowned self] in self.notch.guardChanged(to: $0) }
                notch.onAlertDismissed = { [unowned self] in self.state.dismissViolation() }
            }
            var card: NotchCard.Kind? { notch.visibleCard?.kind }
            var basso: Int { sounds.filter { $0 == "Basso" }.count }
            var glass: Int { sounds.filter { $0 == "Glass" }.count }
        }
        _ = NSApplication.shared
        func shown(_ r: R) -> GuardDisplay {
            now = now.addingTimeInterval(5)
            let data: Data?
            switch r {
            case .healthy: data = file("healthy", ip: "203.0.113.10")
            case .mismatch: data = file("egressMismatch", ip: "203.0.113.99")
            case .offline: data = file("unknown", reason: "offline")
            case .violated(let s): data = file("violated", since: s, ip: "203.0.113.10")
            case .stale(let s): data = file("violated", at: now.addingTimeInterval(-60), since: s)
            case .skew(let s): data = file("violated", at: now.addingTimeInterval(60), since: s)
            case .missing: data = nil
            }
            return GuardStateReader.display(data: data, now: now)
        }
        func read(_ rig: Rig, _ r: R) { rig.state.apply(shown(r)) }
        func run(_ path: [R], rig: Rig? = nil) -> Rig {
            let rig = rig ?? Rig()
            for r in path { read(rig, r) }
            return rig
        }

        let a = run([.violated(t0), .offline])
        check("红卡：违规 → 网络不通，红卡保留", a.card == .alert && a.basso == 1)
        read(a, .healthy)
        check("红卡：违规 → unknown → healthy，红卡撤掉、弹恢复卡", a.card == .recovered)
        let endings: [[R]] = [[.violated(t0), .healthy], [.violated(t0), .offline, .healthy], [.violated(t0), .stale(t0), .healthy],
                              [.violated(t0), .skew(t0), .missing, .healthy], [.stale(t0), .healthy], [.mismatch, .violated(t0), .mismatch, .healthy]]
        check("红卡：任何以 healthy 结尾的序列都没有红卡", endings.allSatisfy { run($0).card != .alert })
        let b = run([.violated(t0), .offline, .violated(t0), .missing, .violated(t0)])
        check("红卡：违规 → unknown → 违规，不重弹、不重响", b.card == .alert && b.basso == 1)
        let c = run([.violated(t0), .healthy, .healthy, .offline, .healthy])
        check("恢复卡：一次恢复只出现一次", c.glass == 1 && c.card == .recovered && c.notch.countdown?.total == NotchCard.recoveredSeconds)
        check("恢复卡：mismatch → healthy 不弹卡（只让盾盾开心）", run([.mismatch, .healthy]).card == nil)
        check("恢复卡：unknown → healthy 什么都不做", run([.offline, .healthy]).sounds.isEmpty && run([.missing, .healthy]).card == nil)
        for (name, r) in [("stale", R.stale(t0)), ("clockSkew", R.skew(t0))] {
            let fresh = run([r])
            check("红卡：\(name) 且 lastVerdict violated → 红卡、新副标题、不响 Basso",
                  fresh.card == .alert && fresh.notch.visibleCard?.detail == P.unresponsiveDetail && fresh.basso == 0)
            let after = run([.violated(t0), r])
            check("红卡：违规后 \(name) → 原红卡换副标题、不重响",
                  after.card == .alert && after.notch.visibleCard?.detail == P.unresponsiveDetail && after.basso == 1)
        }
        let d = run([.violated(t0)])
        d.notch.dismissCurrent()
        read(d, .violated(t0))
        check("关掉：同一次违规不再弹、显示红点", d.card == nil && d.basso == 1 && d.state.presentation.tone == .violated)
        read(d, .stale(t0))
        check("关掉：守卫不响应时不弹、显示灰环", d.card == nil && d.state.presentation.tone == .unknown)
        read(d, .violated(t1))
        check("关掉：新的 violatedSince 不经过 healthy 也再弹", d.card == .alert && d.basso == 2)
        let e = run([.violated(t0)])
        e.notch.dismissCurrent()
        read(e, .healthy)
        check("关掉后 healthy：弹恢复卡", e.card == .recovered)
        read(e, .violated(t0))
        check("healthy 清掉关掉的记录：同一个 violatedSince 也再弹", e.card == .alert && e.basso == 2)
        let f = Rig()
        f.cfg.alertPersistent = false
        read(f, .violated(t0))
        check("非常驻红卡：有倒计时", f.notch.countdown != nil)
        f.notch.dismissCurrent()   // 倒计时到时走的就是这里
        read(f, .violated(t0))
        check("非常驻红卡：到时收起后不每 5 秒重弹重响", f.card == nil && f.basso == 1)
        let g = Rig()
        g.cfg.autoAlert = false
        _ = run([.violated(t0), .healthy], rig: g)
        check("关闭「出口异常时弹出红卡」：不弹红卡，也不弹恢复卡", g.sounds.isEmpty && g.card == nil)
        // 演示路径（App.handleCardNotification，scripts/demo.sh alert）不挡自动撤卡
        let h = Rig()
        h.notch.show(AppDelegate.demoCard(kind: "alert", title: nil, detail: nil))
        read(h, .healthy)
        check("演示红卡：读到 healthy 自动撤掉，不弹恢复卡", h.card == nil && h.glass == 0)
        h.notch.show(AppDelegate.demoCard(kind: "alert", title: nil, detail: nil))
        _ = run([.violated(t0), .healthy], rig: h)
        check("演示红卡挂着时真违规 → healthy：照样撤卡、弹恢复卡", h.card == .recovered && h.basso == 2)

        // 订阅：AppState.watchGuard 消费流，和上面同一个 apply。条件满足就停，最多等 3 秒
        func settle(_ done: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(3)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            return done()
        }
        final class Flag: @unchecked Sendable { var on = false }
        let (feed, push) = AsyncStream.makeStream(of: GuardDisplay.self)
        let ended = Flag()
        push.onTermination = { _ in DispatchQueue.main.async { ended.on = true } }
        let w = Rig()
        w.state.watchGuard(feed)
        push.yield(shown(.violated(t0)))
        check("订阅（假流）：违规 → 红卡", settle { w.card == .alert } && w.basso == 1)
        push.yield(shown(.offline))
        push.yield(shown(.healthy))
        check("订阅（假流）：违规 → unknown → healthy，红卡撤掉、弹恢复卡", settle { w.card == .recovered } && w.glass == 1)
        push.yield(shown(.violated(t1)))
        check("订阅（假流）：新的 violatedSince → 红卡再出现", settle { w.card == .alert } && w.basso == 2)
        w.notch.dismissCurrent()
        push.yield(shown(.violated(t1)))
        push.yield(shown(.violated(t1.addingTimeInterval(60))))
        check("订阅（假流）：关掉后同一次不再弹，又一次新的 violatedSince 再弹", settle { w.card == .alert } && w.basso == 3)
        w.state.stopWatchingGuard()
        check("订阅（假流）：stopWatchingGuard 结束订阅", settle { ended.on })

        // 订阅：真的 GuardStateWatcher 监听隔离 HOME 下的临时目录（guardd 一样用 rename 替换文件）
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("guard-watch-test", isDirectory: true)
        check("订阅（真监听）：目录在隔离 HOME 下", dir.path.hasPrefix(NSHomeDirectory() + "/") && !TestHome.isUnderRealHome(dir))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stateURL = dir.appendingPathComponent(GuardState.fileName)
        let x = Rig()
        x.state.watchGuard(GuardStateWatcher(directory: dir).displays())
        check("订阅（真监听）：没有文件 → unknown、不弹卡", settle { x.state.display.verdict == .unknown } && x.card == nil)
        try? file("violated", at: Date(), since: t0).write(to: stateURL, options: .atomic)
        check("订阅（真监听）：写入违规 → 红卡", settle { x.card == .alert } && x.basso == 1)
        try? file("healthy", at: Date()).write(to: stateURL, options: .atomic)
        check("订阅（真监听）：写入 healthy → 红卡撤掉、弹恢复卡", settle { x.card == .recovered })
        x.state.stopWatchingGuard()
        try? FileManager.default.removeItem(at: dir)

        // 恢复卡 4 秒自动收起、悬停暂停（真的计时器，约 8 秒）
        let k = run([.violated(t0), .healthy])
        func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        wait(1)
        k.notch.setCardHover(true)
        let left = k.notch.countdown?.remaining(at: Date().addingTimeInterval(5)) ?? 0
        check("恢复卡：悬停时倒计时暂停（剩约 3 秒）", k.notch.countdown?.isPaused == true && abs(left - 3) < 0.3)
        wait(3.5)
        check("恢复卡：悬停期间不收起", k.card == .recovered)
        k.notch.setCardHover(false)
        wait(2.5)
        check("恢复卡：移开后接着倒计时", k.card == .recovered)
        wait(0.8)
        check("恢复卡：剩下的时间走完后收起", k.card == nil)
    }
}

// MARK: - 单实例

@MainActor
extension SelfTest {
    static func singleInstanceTests(_ check: (String, Bool) -> Void) {
        let me = SingleInstance.Instance(pid: 200, start: 10)
        check("单实例：更早启动的实例在 → 本实例退出", SingleInstance.olderInstance(than: me, among: [.init(pid: 300, start: 9)])?.pid == 300)
        check("单实例：只有更晚启动的 → 本实例留下", SingleInstance.olderInstance(than: me, among: [.init(pid: 300, start: 11)]) == nil)
        check("单实例：同一时刻启动，pid 小的留下",
              SingleInstance.olderInstance(than: me, among: [.init(pid: 100, start: 10)]) != nil
              && SingleInstance.olderInstance(than: me, among: [.init(pid: 300, start: 10)]) == nil)
        check("单实例：列表里的自己不算", SingleInstance.olderInstance(than: me, among: [me]) == nil)
        check("单实例：自检进程（未打包，prohibited）不算会画界面的实例",
              !SingleInstance.runningGUIInstances().contains { $0.pid == getpid() })
        check("单实例：锁文件不随 HOME 改变（测试实例和正式实例抢同一把锁）",
              SingleInstance.lockURL.map { !$0.path.hasPrefix(NSHomeDirectory() + "/") && !TestHome.isUnderRealHome($0) } ?? false)

        let lock = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("single-instance-test.lock")
        guard case .acquired(let fd) = SingleInstance.lock(at: lock) else { return check("单实例锁：第一个拿到", false) }
        check("单实例锁：同一进程再开一次也拿不到（flock 按打开的文件算）", SingleInstance.lock(at: lock) == .heldByOther)
        check("单实例锁：另一个进程同时启动 → 拿不到、立即退出", probe(lock) == 3)
        close(fd)
        check("单实例锁：持有者关掉后，下一个能拿到", probe(lock) == 0)

        // run.sh 的顺序：pkill（SIGTERM）旧实例，再启动新的。旧进程已退出但还没被回收（僵尸）时也不能挡住新实例
        if let old = spawnHolder(lock) {
            check("重启：旧实例在时新实例退出", probe(lock) == 3)
            kill(old, SIGTERM)
            var info = siginfo_t()
            waitid(P_PID, id_t(old), &info, WEXITED | WNOWAIT)   // 等它退出，但不回收
            check("重启：旧实例刚退出（尚未回收）→ 锁已释放，新实例能启动", probe(lock) == 0)
            check("重启：退出中的旧实例不算在运行", SingleInstance.instance(old) == nil)
            var status: Int32 = 0
            waitpid(old, &status, 0)
        } else {
            check("重启：起旧实例", false)
        }
        // 崩溃：进程被 SIGKILL，锁文件留在磁盘上，但锁随进程消失
        if let crashed = spawnHolder(lock) {
            kill(crashed, SIGKILL)
            var status: Int32 = 0
            waitpid(crashed, &status, 0)
            check("崩溃：留下的锁文件不挡新实例", FileManager.default.fileExists(atPath: lock.path) && probe(lock) == 0)
        } else {
            check("崩溃：起旧实例", false)
        }
    }

    /// 起一个 `--instance-probe <lock> --hold` 子进程，拿到锁、在标准输出说 held 后才返回；
    /// 子进程读标准输入，自检退出时管道断开它就跟着退出，不会遗留
    private static func spawnHolder(_ lock: URL) -> pid_t? {
        var toChild: [Int32] = [0, 0], fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0, pipe(&fromChild) == 0 else { return nil }
        _ = fcntl(toChild[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fromChild[0], F_SETFD, FD_CLOEXEC)
        guard let pid = spawn(["--instance-probe", lock.path, "--hold"], stdin: toChild[0], stdout: fromChild[1]) else { return nil }
        close(toChild[0]); close(fromChild[1])
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(fromChild[0], &buf, buf.count)
        close(fromChild[0])
        guard n > 0, String(decoding: buf.prefix(n), as: UTF8.self).hasPrefix("held") else {
            kill(pid, SIGKILL); var s: Int32 = 0; waitpid(pid, &s, 0)
            return nil
        }
        return pid
    }

    /// 起一个 `--instance-probe <lock>` 子进程抢锁，返回退出码：0 拿到，3 别人持有
    private static func probe(_ lock: URL) -> Int32 {
        guard let pid = spawn(["--instance-probe", lock.path], stdin: nil, stdout: nil) else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    }

    private static func spawn(_ args: [String], stdin: Int32?, stdout: Int32?) -> pid_t? {
        guard let exe = Bundle.main.executablePath else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin { posix_spawn_file_actions_adddup2(&actions, stdin, 0) }
        if let stdout { posix_spawn_file_actions_adddup2(&actions, stdout, 1) }
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, exe, &actions, nil, argv, environ) == 0 ? pid : nil
    }
}

// MARK: - 收起态耳朵和热区（expanded-spec.md「收起态」、ear-dundun-spec.md）

@MainActor
extension SelfTest {
    static func notchEarTests(_ check: (String, Bool) -> Void) {
        let notch = CGSize(width: 185, height: 32)
        check("耳朵：收起宽度 = 刘海 + 2×44，高度 = 刘海高",
              NotchLayout.size(.closed, notch: notch, rows: 0) == CGSize(width: 185 + 88, height: 32))
        let flat = CGSize(width: 180, height: 0)
        check("耳朵：无刘海屏（高 0）不长耳朵，收起尺寸不变",
              !NotchLayout.hasEars(flat) && NotchLayout.size(.closed, notch: flat, rows: 0) == flat)
        check("耳朵：左耳画布在形状左缘 + 外翻 4 + 6，离刘海 6pt",
              NotchLayout.closedFlare + NotchLayout.earCanvasInset + NotchLayout.earCanvas
                + NotchLayout.earCanvasInset == NotchLayout.earWidth)

        _ = NSApplication.shared
        let c = NotchController(onScreen: false)
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        c.place(screen: screen, notch: notch)
        let half = (notch.width + NotchLayout.earWidth) / 2   // 刘海中心到耳朵中心
        let left = NSPoint(x: screen.midX - half, y: screen.maxY - 16)
        let right = NSPoint(x: screen.midX + half, y: screen.maxY - 16)
        let top = NSPoint(x: screen.midX - half, y: screen.maxY)   // 鼠标顶到屏幕最上沿
        check("热区：收起时包含左右两只耳朵（含贴顶的鼠标）",
              c.triggerRect.contains(left) && c.triggerRect.contains(right) && c.triggerRect.contains(top))
        check("热区：收起时耳朵上接收鼠标，点击不漏给菜单栏", c.mode == .closed && c.captures(left) && c.captures(right))
        check("热区：收起时耳朵外、刘海下面的透明区照样穿透", !c.captures(NSPoint(x: screen.midX, y: screen.maxY - 100))
              && !c.captures(NSPoint(x: screen.midX - half - 40, y: screen.maxY - 16)))
        c.place(screen: screen, notch: nil)
        check("热区：无刘海屏收起时一律穿透，热区还是顶端中间 216 宽",
              !c.captures(NSPoint(x: screen.midX, y: screen.maxY - 1)) && c.triggerRect.width == 216)
    }

    /// 状态测试：覆盖只在内存里，不碰守卫显示、红卡和任何文件
    static func stateTestTests(_ check: (String, Bool) -> Void) {
        _ = NSApplication.shared
        let fm = FileManager.default
        let files = [ConfigStore.shared.url, Log.url, GuardPaths.stateFile]
        func stamp() -> [String] {
            files.map { u in
                let a = try? fm.attributesOfItem(atPath: u.path)
                return "\(u.lastPathComponent) \(a != nil) \((a?[.size] as? Int) ?? -1) \((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            }
        }
        let app = AppState.shared
        let before = (app.display, app.presentation, ConfigStore.shared.config, stamp())

        var sounds: [String] = []
        let c = NotchController(config: { NKConfig() }, playSound: { sounds.append($0) }, onScreen: false)
        c.place(screen: NSRect(x: 0, y: 0, width: 1512, height: 982), notch: CGSize(width: 185, height: 32))
        check("状态测试：12 个状态，raw 值对得上清单",
              DundunTestState.allCases.map(\.rawValue) == ["idle", "sleeping", "thinking", "working", "waiting", "done", "error",
                                                            "interrupted", "dizzy", "warning-mismatch", "warning-stale", "danger"])
        var shown = true
        for s in DundunTestState.allCases {
            c.force(s)
            shown = shown && c.overrides.mascot(real: .idle) == s.dundun
        }
        check("状态测试：强制哪个状态，盾盾就显示哪个", shown)
        for p in NotchPin.allCases { c.setPin(p) }
        c.force(.danger)
        check("状态测试：强制「危险」不弹红卡、不响", c.visibleCard == nil && sounds.isEmpty)
        let after = (app.display, app.presentation, ConfigStore.shared.config, stamp())
        check("状态测试：不动 AppState 的守卫显示", after.0 == before.0 && after.1 == before.1)
        check("状态测试：不改配置，也不写 config.json、日志、guard-state.json", after.2 == before.2 && after.3 == before.3)

        c.setPin(.open)
        c.restoreRealState()
        check("恢复真实状态：盾盾和刘海都回到真实（固定方式回到自动、收起）",
              c.overrides.dundun == nil && c.overrides.pin == .auto && c.overrides.isReal && c.mode == .closed
              && c.overrides.mascot(real: .guardMismatch) == .guardMismatch)

        c.setPin(.open)
        check("固定展开：不悬停也展开", c.mode == .dashboard)
        c.setHovering(true)
        c.setPin(.closed)
        check("固定收起：压过悬停", c.mode == .closed)
        c.setHovering(true)
        check("固定收起：再悬停也不展开", c.mode == .closed)
        c.show(AppDelegate.demoCard(kind: "alert", title: nil, detail: nil))
        check("固定收起：真的红卡照常弹出", c.mode == .card && c.visibleCard?.kind == .alert)
        c.restoreRealState()

        // 真的红卡被关掉之后强制「危险」：既不重弹，也不清掉关掉的记录
        sounds = []   // 上面演示红卡响过一次
        let state = AppState()
        let rig = NotchController(config: { NKConfig() }, playSound: { sounds.append($0) }, onScreen: false)
        state.onPresentation = { rig.guardChanged(to: $0) }
        rig.onAlertDismissed = { state.dismissViolation() }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        func violated(_ now: Date) -> GuardDisplay {
            let j: [String: Any] = ["schemaVersion": 1, "verdict": "violated", "checkedAt": iso.string(from: now),
                                    "violatedSince": iso.string(from: t0), "egressFailures": [String: Int]()]
            return GuardStateReader.display(data: try! JSONSerialization.data(withJSONObject: j), now: now)
        }
        state.apply(violated(t0))
        let basso = sounds.filter { $0 == "Basso" }.count
        rig.dismissCurrent()
        rig.force(.danger)
        rig.setPin(.open)
        rig.restoreRealState()
        state.apply(violated(t0.addingTimeInterval(5)))
        check("状态测试：关掉红卡后强制「危险」再恢复，同一次违规不重弹、不重响",
              basso == 1 && rig.visibleCard == nil && sounds.filter { $0 == "Basso" }.count == 1)
    }
}
