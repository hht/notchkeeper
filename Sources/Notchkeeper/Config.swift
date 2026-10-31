import AppKit
import Combine
import GuardCore
import NotchCore

/// 持久化到 ~/Library/Application Support/Notchkeeper/config.json。
/// 缺失的字段用默认值，未知字段忽略；字段类型不对就整份解不开，由 `ConfigStore` 保留原文件。
struct NKConfig: Codable, Equatable {
    // 通用
    var soundEnabled = true
    var hoverExpand = true
    /// Pip 的眼睛和身体跟着鼠标走、鼠标到刘海上时探头（docs/mascot.md §5）
    var mascotFollowsMouse = true
    // 出口守卫
    // 不内置任何真实出口：空列表时 guardd 判不了出口（unknown），设置页会提示
    var allowlist: [String] = []
    var autoAlert = true
    var alertPersistent = true
    // 通知
    var cardAutoDismissSeconds = 6.0
    /// 卡片上「打开 URL」除 https 外还放行的 scheme（`URLPolicy`）
    var urlSchemes: [String] = []
    // 插件：内置的按 `PluginID`，外部的按 `plugins/<id>/` 的目录名。没写的插件开着、每段最多露 5 行
    var plugins: [String: PluginSettings] = [:]
    /// 面板里各段的顺序（出口守卫固定在顶上，不在这里）；没排过的跟在后面
    var pluginOrder: [String] = []
    /// 都平静时收起态显示谁（docs/ui.md「面板布局」）；空串是不常驻
    var residentPlugin = PluginID.exitGuard
    /// 收起时左耳画 Pip；关掉后什么都没有要显示时就是一块纯黑的刘海（照 boring.notch 的空闲脸选项）
    var showsEarMascot = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NKConfig()
        func v<T: Decodable>(_ key: CodingKeys, _ def: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? def
        }
        soundEnabled = try v(.soundEnabled, d.soundEnabled)
        hoverExpand = try v(.hoverExpand, d.hoverExpand)
        mascotFollowsMouse = try v(.mascotFollowsMouse, d.mascotFollowsMouse)
        allowlist = try v(.allowlist, d.allowlist)
        autoAlert = try v(.autoAlert, d.autoAlert)
        alertPersistent = try v(.alertPersistent, d.alertPersistent)
        cardAutoDismissSeconds = min(10, max(2, try v(.cardAutoDismissSeconds, d.cardAutoDismissSeconds)))
        urlSchemes = try v(.urlSchemes, d.urlSchemes)
        plugins = try v(.plugins, d.plugins)
        pluginOrder = try v(.pluginOrder, d.pluginOrder)
        residentPlugin = try v(.residentPlugin, d.residentPlugin)
        showsEarMascot = try v(.showsEarMascot, d.showsEarMascot)
    }

    func isEnabled(_ plugin: String) -> Bool { plugins[plugin]?.enabled ?? true }
    func maxRows(_ plugin: String) -> Int { plugins[plugin]?.maxRows ?? PluginSettings().maxRows }
    var resident: String? { residentPlugin.isEmpty ? nil : residentPlugin }

    mutating func setEnabled(_ on: Bool, for plugin: String) { plugins[plugin, default: PluginSettings()].enabled = on }
    mutating func setMaxRows(_ n: Int, for plugin: String) { plugins[plugin, default: PluginSettings()].maxRows = PluginSettings.clamp(n) }

    /// 排过的在前、没排过的按 `available` 原来的顺序跟在后面；排过但已经不在 `available` 里的不出现
    func ordered(_ available: [String]) -> [String] {
        let listed = pluginOrder.filter(available.contains)
        return listed + available.filter { !listed.contains($0) }
    }

    /// 上移（-1）或下移（+1）一格；到头了不动。存下整份当前顺序
    mutating func move(_ plugin: String, by offset: Int, in available: [String]) {
        var order = ordered(available)
        guard let i = order.firstIndex(of: plugin), order.indices.contains(i + offset) else { return }
        order.swapAt(i, i + offset)
        pluginOrder = order
    }
}

struct PluginSettings: Codable, Equatable {
    var enabled = true
    /// 面板里这一段最多露几行，多的在段里滚
    var maxRows = 5

    static let rowRange = 1...5
    static func clamp(_ n: Int) -> Int { min(rowRange.upperBound, max(rowRange.lowerBound, n)) }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        maxRows = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .maxRows) ?? 5)
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: NKConfig {
        didSet { if config != oldValue && !applyingExternal { scheduleSave() } }
    }

    let url: URL
    /// 磁盘上的文件读不了或解不开：这时不写盘，免得默认值盖掉手改的内容（CLAUDE.md 准则 5）。改好后热加载会清掉它
    @Published private(set) var fileUnreadable = false
    private let log: (String) -> Void
    private var applyingExternal = false
    private var lastData: Data?
    private var lastMTime: Date?
    private var saveWork: DispatchWorkItem?
    private var pollTimer: Timer?

    init(url: URL = GuardPaths.configFile, log: @escaping (String) -> Void = Log.write) {
        self.url = url
        self.log = log
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        config = NKConfig()
        switch read() {
        case .missing:
            saveNow()
        case .unreadable:
            break
        case let .loaded(c, data):
            config = c
            lastData = data
        }
        lastMTime = mtime()
        // 热加载：轮询修改时间（兼容各种编辑器的原子写入 / 原地写入）
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadIfChanged() }
        }
    }

    private enum File {
        case missing, unreadable
        case loaded(NKConfig, Data)
    }

    /// 只有这里写 `fileUnreadable`
    private func read() -> File {
        do {
            let data = try Data(contentsOf: url)
            let file = File.loaded(try JSONDecoder().decode(NKConfig.self, from: data), data)
            fileUnreadable = false
            return file
        } catch CocoaError.fileReadNoSuchFile {
            fileUnreadable = false
            return .missing
        } catch {
            fileUnreadable = true
            // 坏着时内存里的改动不算「和文件一致」：文件原样改回时也要重新载入
            lastData = nil
            log("配置文件\(Self.problem(error))，先用当前设置，不改文件")
            return .unreadable
        }
    }

    /// 只说哪个键坏了，不带值：值里可能有 IP（CLAUDE.md「日志不记 IP」）
    private static func problem(_ error: Error) -> String {
        let path: [CodingKey]
        switch error as? DecodingError {
        case let .typeMismatch(_, c)?, let .valueNotFound(_, c)?, let .keyNotFound(_, c)?, let .dataCorrupted(c)?:
            path = c.codingPath
        case nil:
            return "读不了"
        @unknown default:
            return "解不开"
        }
        return path.isEmpty ? "不是合法的 JSON" : "里 \(path.map(\.stringValue).joined(separator: ".")) 这一项解不开"
    }

    private func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func saveNow() {
        // 外部刚改过、轮询还没看到：先读进来，免得盖掉；读进来了就是外部的赢，内存和文件已经一致
        if reloadIfChanged() { return }
        guard !fileUnreadable else {
            log("配置文件解不开，这次改动只在内存里，改好文件后会被文件内容取代")
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config), data != lastData else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastData = data
            lastMTime = mtime()
        } catch {
            log("配置写入失败：\(error.localizedDescription)")
        }
    }

    /// 返回是否载入了外部的新内容
    @discardableResult
    func reloadIfChanged() -> Bool {
        let m = mtime()
        guard m != lastMTime else { return false }
        lastMTime = m
        guard case let .loaded(c, data) = read(), data != lastData else { return false }
        lastData = data
        guard c != config else { return true }
        applyingExternal = true
        config = c
        applyingExternal = false
        log("已热加载配置文件")
        return true
    }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openFile() { NSWorkspace.shared.open(url) }
}
