import AppKit
import Combine
import GuardCore
import GuardWatch

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store = ConfigStore.shared

    /// 最近一次读到的 guard-state.json（guardd 写，App 只读）
    @Published private(set) var display = GuardStateReader.display(data: nil, now: Date())
    /// 由 display 和 dismissedViolationSince 算出来，界面只看它
    @Published private(set) var presentation = GuardPresentation(verdict: .unknown, unknownReason: nil, lastVerdict: nil,
                                                                 violatedSince: nil, dismissedViolationSince: nil)
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var processes = ProcessCounts()

    /// 用户关掉的是哪一次违规（按 violatedSince 记）。只在内存：App 重启后红卡再出现一次，宁可多提醒
    private var dismissedViolationSince: Date??

    /// 每次读完都调用（不论有没有变化），参数是这次读到的显示
    var onPresentation: ((GuardPresentation) -> Void)?
    /// 订阅 guard-state 显示流的长任务；`stopWatchingGuard()` / deinit 取消，流随之结束、监听关掉
    private var guardTask: Task<Void, Never>?
    private var sessionTimer: Timer?
    private var scanning = false

    init() {}

    func start() {
        // 不轮询：GuardStateWatcher 监听目录，guardd 写文件后马上读；checkedAt 过期也由它到点重读（docs/egress-guard.md）
        watchGuard(GuardStateWatcher(directory: GuardPaths.directory).displays())
        scanSessions()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in AppState.shared.scanSessions() }
        }
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
        if d.verdict == .healthy { dismissedViolationSince = nil }
        let old = presentation
        let new = GuardPresentation(d, dismissedViolationSince: dismissedViolationSince)
        if d != display { display = d }
        if new != old {
            presentation = new
            // 日志不记录 IP
            if new.title != old.title { Log.write("出口守卫：\(new.title)") }
        }
        onPresentation?(new)
    }

    /// 用户关掉了红卡（或非常驻红卡到时收起）。只在违规还挂着时记下，演示红卡关掉不算
    func dismissViolation() {
        guard presentation.holdsViolation else { return }
        dismissedViolationSince = .some(display.violatedSince)
        apply(display)
    }

    /// 后台线程只读扫描会话文件；结果只含项目名 / agent / 状态 / 时间
    func scanSessions() {
        guard !scanning else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let s = SessionScanner.scan()
            let p = ProcessCounts.current()
            await MainActor.run { AppState.shared.applyScan(s, p) }
        }
    }

    private func applyScan(_ s: [AgentSession], _ p: ProcessCounts) {
        scanning = false
        if s != sessions { sessions = s }
        if p != processes { processes = p }
    }

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

    static func write(_ msg: String) {
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
