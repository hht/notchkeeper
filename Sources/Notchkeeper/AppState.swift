import AppKit
import SwiftUI

enum GuardStatus: String {
    case healthy, unhealthy, unknown

    var nsColor: NSColor {
        switch self {
        case .healthy: return .systemGreen
        case .unhealthy: return .systemRed
        case .unknown: return .systemGray
        }
    }
    var color: Color { Color(nsColor: nsColor) }
    var title: String {
        switch self {
        case .healthy: return "出口正常"
        case .unhealthy: return "出口异常"
        case .unknown: return "出口未知"
        }
    }
    var subtitle: String {
        switch self {
        case .healthy: return "当前出口在允许列表中"
        case .unhealthy: return "当前出口不在允许列表中"
        case .unknown: return "正在检测，或无法获取出口 IP"
        }
    }
    var symbol: String {
        switch self {
        case .healthy: return "checkmark.shield.fill"
        case .unhealthy: return "xmark.shield.fill"
        case .unknown: return "shield.fill"
        }
    }
}

struct LogEntry: Identifiable {
    enum Kind { case info, warn, ok }
    let id = UUID()
    let date: Date
    let text: String
    let kind: Kind
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var status: GuardStatus = .unknown
    @Published private(set) var exitIP: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checking = false
    @Published private(set) var logs: [LogEntry] = []

    @Published var allowlist: [String] {
        didSet { UserDefaults.standard.set(allowlist, forKey: "allowlist"); reevaluate() }
    }
    @Published var autoAlert: Bool {
        didSet { UserDefaults.standard.set(autoAlert, forKey: "autoAlert") }
    }
    /// 调试用：强制视为出口异常，用来看图标变色和红色卡片
    @Published var simulateUnhealthy = false {
        didSet { addLog(simulateUnhealthy ? "开启模拟出口异常" : "关闭模拟出口异常"); reevaluate() }
    }

    var onStatusChange: ((GuardStatus, GuardStatus) -> Void)?
    private var timer: Timer?

    static let defaultAllowlist = ["216.36.90.150", "216.36.90.116"]

    init() {
        allowlist = UserDefaults.standard.stringArray(forKey: "allowlist") ?? AppState.defaultAllowlist
        autoAlert = (UserDefaults.standard.object(forKey: "autoAlert") as? Bool) ?? true
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in AppState.shared.refresh() }
        }
    }

    func refresh() {
        guard !checking else { return }
        checking = true
        Task {
            let ip = await IPProbe.fetch()
            self.checking = false
            self.lastChecked = Date()
            self.exitIP = ip
            self.reevaluate()
        }
    }

    var exitInAllowlist: Bool { exitIP.map { allowlist.contains($0) } ?? false }

    private func reevaluate() {
        let new: GuardStatus
        if simulateUnhealthy { new = .unhealthy }
        else if exitIP == nil { new = lastChecked == nil ? .unknown : .unknown }
        else { new = exitInAllowlist ? .healthy : .unhealthy }
        guard new != status else { return }
        let old = status
        status = new
        // 日志不记录 IP
        switch new {
        case .healthy: addLog("出口检测：在允许列表", .ok)
        case .unhealthy: addLog(simulateUnhealthy ? "出口检测：模拟异常" : "出口检测：不在允许列表", .warn)
        case .unknown: addLog("出口检测：无法获取出口 IP", .warn)
        }
        onStatusChange?(old, new)
    }

    @discardableResult
    func addAllowed(_ raw: String) -> Bool {
        let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPProbe.isIPv4(ip), !allowlist.contains(ip) else { return false }
        allowlist.append(ip)
        addLog("允许列表：新增 1 项")
        return true
    }

    func removeAllowed(_ ip: String) {
        allowlist.removeAll { $0 == ip }
        addLog("允许列表：移除 1 项")
    }

    func addLog(_ text: String, _ kind: LogEntry.Kind = .info) {
        logs.insert(LogEntry(date: Date(), text: text, kind: kind), at: 0)
        if logs.count > 200 { logs.removeLast(logs.count - 200) }
        Log.write(text)
    }

    func clearLogs() { logs.removeAll() }
}

enum IPProbe {
    /// 只用通用 IP 回显服务，不访问任何 Claude/Anthropic 域名
    static let endpoints = [
        "https://api.ipify.org",
        "https://ipinfo.io/ip",
        "https://ifconfig.me/ip",
    ].compactMap(URL.init(string:))

    static func fetch() async -> String? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        for url in endpoints {
            var req = URLRequest(url: url)
            req.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
            guard let result = try? await session.data(for: req) else { continue }
            let (data, resp) = result
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  isIPv4(s) else { continue }
            return s
        }
        return nil
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let n = Int(p) else { return false }
            return n >= 0 && n <= 255
        }
    }
}

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Notchkeeper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notchkeeper.log")
    }()
    private static let formatter = ISO8601DateFormatter()

    static func write(_ msg: String) {
        let line = "\(formatter.string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
