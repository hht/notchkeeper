import AgentCore
import AppKit
import Combine
import MascotCore
import GuardCore
import GuardWatch
import NotchCore

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store = ConfigStore.shared

    /// 最近一次读到的 guard-state.json（guardd 写，App 只读）
    @Published private(set) var display: GuardDisplay
    /// 由 display 和用户关掉的是哪一次算出来（`ViolationAlert`），界面只看它
    @Published private(set) var presentation: GuardPresentation
    /// 面板列的会话（AgentCore 判定的、活着的终端 claude）
    @Published private(set) var sessions: [Session] = []
    /// Claude Code 各会话合起来此刻是什么（AgentCore 判定）；没有要画的是 nil
    @Published private(set) var agentActivity: AgentActivity?

    /// Pip 画哪个（docs/mascot.md §2「优先级」）：守卫的事 > agent > 空闲。晕、睡着在外面叠，完整的优先级第 4 步归 NotchCore
    var look: Look { presentation.look != .idle ? presentation.look : agentActivity.map(Look.init) ?? .idle }

    private var violationAlert: ViolationAlert

    /// 每次读完都调用（不论有没有变化），参数是红卡要做的事
    var onAlertAction: ((ViolationAlert.Action) -> Void)?
    /// AgentCore 判定的事件，连同同一次更新的会话列表
    var onAgentEvents: (([AgentEvent], [Session]) -> Void)?
    /// 订阅 guard-state 显示流的长任务；`stopWatchingGuard()` / deinit 取消，流随之结束、监听关掉
    private var guardTask: Task<Void, Never>?
    private var agentWatcher: AgentWatcher?

    init() {
        let d = GuardStateReader.display(data: nil, now: Date())
        display = d
        violationAlert = ViolationAlert(d)
        presentation = violationAlert.presentation
    }

    func start() {
        // 不轮询：GuardStateWatcher 监听目录，guardd 写文件后马上读；checkedAt 过期也由它到点重读（docs/egress-guard.md）
        watchGuard(GuardStateWatcher(directory: GuardPaths.directory).displays())
        let watcher = AgentWatcher { update in
            DispatchQueue.main.async { AppState.shared.applyAgent(update) }
        }
        watcher.start()
        agentWatcher = watcher
    }

    /// 每来一个显示就 apply 一次。参数是流，测试可以喂假的；再调一次会先取消旧的订阅
    func watchGuard(_ displays: AsyncStream<GuardDisplay>) {
        guardTask?.cancel()
        guardTask = Task { [weak self] in
            for await d in displays { self?.apply(d) }
        }
    }

    func stopWatchingGuard() {
        guardTask?.cancel()
        guardTask = nil
    }

    deinit { guardTask?.cancel() }

    func apply(_ d: GuardDisplay) {
        if d != display { display = d }
        let action = violationAlert.read(d, autoAlert: store.config.autoAlert)
        publishPresentation()
        onAlertAction?(action)
    }

    private func publishPresentation() {
        let old = presentation, new = violationAlert.presentation
        guard new != old else { return }
        presentation = new
        // 日志不记录 IP
        if new.title != old.title { Log.write("出口守卫：\(new.title)") }
    }

    private func applyAgent(_ update: AgentWatcher.Update) {
        if update.activity != agentActivity { agentActivity = update.activity }
        if update.sessions != sessions { sessions = update.sessions }
        for event in update.events {
            switch event {
            case .turnDone(let pid): Log.write("agent：回合做完（pid \(pid)）")
            case .turnFailed(let pid): Log.write("agent：回合出错（pid \(pid)）")
            case .needsYou(let need, let pid): Log.write("agent：需要你介入，\(need)（pid \(pid)）")
            case .needsYouEnded(let pid): Log.write("agent：介入结束（pid \(pid)）")
            }
        }
        if !update.events.isEmpty { onAgentEvents?(update.events, update.sessions) }
    }

    /// 用户关掉了红卡（或非常驻红卡到时收起）
    func dismissViolation() {
        violationAlert.dismiss()
        publishPresentation()
    }

    /// scripts/demo.sh alert
    func demoAlert() { onAlertAction?(violationAlert.demo()) }

    /// 允许列表用 GuardCore 的 IPv4 校验，和 guardd 解析 config.json 的规则一致
    @discardableResult
    func addAllowed(_ raw: String) -> Bool {
        let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4(ip) != nil, !store.config.allowlist.contains(ip) else { return false }
        store.config.allowlist.append(ip)
        Log.write("允许列表：新增 1 项")
        return true
    }

    func removeAllowed(_ ip: String) {
        store.config.allowlist.removeAll { $0 == ip }
        Log.write("允许列表：移除 1 项")
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Notchkeeper/notchkeeper.log")
    /// 本地时间 + 时区偏移，例如 2026-10-28 14:03:21 -07:00
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss xxxxx"
        return f
    }()

    /// 主线程和 `AgentWatcher` 的队列都会写：串行起来，行不串、`formatter` 不被同时用
    private static let queue = DispatchQueue(label: "com.notchkeeper.log")

    static func write(_ msg: String) {
        queue.sync {
            // 带 pid：同时有两个实例时分得清是谁写的
            let line = "\(formatter.string(from: Date())) [pid \(getpid())] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}

extension Look {
    init(_ activity: AgentActivity) {
        switch activity {
        case .finished: self = .finished
        case .working: self = .working
        case .longTurn: self = .longTurn
        case .question: self = .question
        case .approval: self = .approval
        }
    }
}
