import AgentCore
import AppKit
import Combine
import MascotCore
import GuardCore
import GuardWatch
import NotchCore
import PluginCore

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
    /// 已登记的外部插件（`plugins/<id>/manifest.json`）
    @Published private(set) var manifests: [String: Manifest] = [:]
    /// 外部插件开着的活动
    @Published private(set) var activities = ActivityBoard()
    private var activityExpiry: DispatchWorkItem?

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
        // 关掉 Claude Code 插件：照常判定，只是不弹卡
        if !update.events.isEmpty, store.config.isEnabled(PluginID.claudeCode) { onAgentEvents?(update.events, update.sessions) }
    }

    // MARK: 插件

    /// 面板里各段的插件，按用户排的顺序：Claude Code 和登记了的外部插件，开没开都在。出口守卫固定在顶上，不在这里
    var sectionPlugins: [String] {
        store.config.ordered([PluginID.claudeCode] + manifests.keys.sorted())
    }

    /// 开着的插件各自的状态：守卫在前，其余按段的顺序（一样急时排在前面的上位）
    var statuses: [PluginStatus] {
        let c = store.config
        var all: [PluginStatus] = c.isEnabled(PluginID.exitGuard) ? [PluginStatus(guard: presentation)] : []
        for id in sectionPlugins where c.isEnabled(id) {
            all.append(id == PluginID.claudeCode ? PluginStatus(agent: agentActivity) : PluginStatus(external: id, urgency: activities.urgency(for: id)))
        }
        return all
    }

    /// 收起时 Pip 和右耳画谁（docs/ui.md「面板布局」）；nil：Pip 空闲、右耳空着
    var lead: PluginStatus? { PluginStatus.lead(statuses, resident: store.config.resident) }
    /// Pip 画哪个（docs/mascot.md §2「优先级」换成了插件的紧急程度）。晕、睡着由 `MascotDirector.shown` 叠上去
    var look: Look { lead?.look ?? .idle }

    /// 面板里开着的段和它们的行（空的段也在，画不画由面板定）
    var sections: [PanelSection] {
        let c = store.config
        return sectionPlugins.filter(c.isEnabled).map { id in
            PanelSection(plugin: id, rows: id == PluginID.claudeCode ? sessions.map(PanelRow.init) : activities.rows(for: id), maxRows: c.maxRows(id))
        }
    }

    /// 设置页上插件的名字：外部的用它登记的名字，登记读不到时用 id
    func pluginName(_ id: String) -> String {
        switch id {
        case PluginID.exitGuard: return String(localized: "出口守卫")
        case PluginID.claudeCode: return "Claude Code"
        default: return manifests[id]?.name ?? id
        }
    }

    /// 重读插件登记：启动、装卸终端插件、打开设置页时
    func reloadManifests() {
        let m = InboxWatcher.manifests()
        if m != manifests { manifests = m }
    }

    /// 收件箱收下的一批：记下当时的登记，活动记上面板，返回要弹或要刷新的卡（App 交给刘海）
    func applyInbox(_ batch: InboxWatcher.Batch) -> [ActivityBoard.CardChange] {
        if batch.plugins != manifests { manifests = batch.plugins }
        guard !batch.activities.isEmpty else { return [] }
        let now = Date()
        let changes = batch.activities.compactMap { activities.apply($0, now: now) }
        scheduleActivityExpiry()
        return changes
    }

    /// 设置里关掉一个外部插件：它的行撤掉
    func removeActivities(of plugin: String) {
        activities.remove(plugin: plugin)
        scheduleActivityExpiry()
    }

    /// 活动过期的时刻一次性定时（最长 8 小时一次），到点撤行
    private func scheduleActivityExpiry() {
        activityExpiry?.cancel()
        guard let at = activities.deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activities.expire(now: Date())
            self.scheduleActivityExpiry()
        }
        activityExpiry = work
        // 墙钟：睡眠期间也算时间，开盖后过了期的马上撤（`deadline:` 按开机时长算，睡眠时不走）
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
    }

    /// 开关出口守卫插件（关的是提醒，不是判定）：关掉撤红卡，打开按最近一份状态读一次
    func setGuardEnabled(_ on: Bool) {
        onAlertAction?(violationAlert.setEnabled(on, autoAlert: store.config.autoAlert))
        Log.write("出口守卫插件：\(on ? "打开" : "关掉")")
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
