import AppKit
import Combine

/// 持久化到 ~/Library/Application Support/Notchkeeper/config.json。
/// 解码时缺失的字段一律用默认值，手动改坏一个字段不会丢掉整份配置。
struct NKConfig: Codable, Equatable {
    // 通用
    var launchAtLogin = false
    var soundEnabled = true
    var hoverExpand = true
    var dundunFeelsTheMac = true
    // 出口守卫
    // 不内置任何真实出口：空列表时 guardd 判不了出口（unknown），设置页会提示
    var allowlist: [String] = []
    var autoAlert = true
    var alertPersistent = true
    // 通知
    var cardAutoDismissSeconds = 6.0
    var suppressWhenHostFrontmost = true
    var agents: [String: Bool] = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0.rawValue, true) })

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NKConfig()
        func v<T: Decodable>(_ key: CodingKeys, _ def: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? def
        }
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        soundEnabled = v(.soundEnabled, d.soundEnabled)
        hoverExpand = v(.hoverExpand, d.hoverExpand)
        dundunFeelsTheMac = v(.dundunFeelsTheMac, d.dundunFeelsTheMac)
        allowlist = v(.allowlist, d.allowlist)
        autoAlert = v(.autoAlert, d.autoAlert)
        alertPersistent = v(.alertPersistent, d.alertPersistent)
        cardAutoDismissSeconds = min(10, max(2, v(.cardAutoDismissSeconds, d.cardAutoDismissSeconds)))
        suppressWhenHostFrontmost = v(.suppressWhenHostFrontmost, d.suppressWhenHostFrontmost)
        agents = d.agents.merging(v(.agents, [String: Bool]())) { _, new in new }
    }

    func agentEnabled(_ a: AgentKind) -> Bool { agents[a.rawValue] ?? true }
}

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: NKConfig {
        didSet { if config != oldValue && !applyingExternal { scheduleSave() } }
    }

    let directory: URL
    let url: URL
    private var applyingExternal = false
    private var lastData: Data?
    private var lastMTime: Date?
    private var saveWork: DispatchWorkItem?
    private var pollTimer: Timer?

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchkeeper", isDirectory: true)
        url = directory.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(NKConfig.self, from: data) {
            config = c
            lastData = data
        } else {
            var c = NKConfig()
            // 从 M1 的 UserDefaults 迁移
            if let list = UserDefaults.standard.stringArray(forKey: "allowlist") { c.allowlist = list }
            if let a = UserDefaults.standard.object(forKey: "autoAlert") as? Bool { c.autoAlert = a }
            config = c
            saveNow()
        }
        lastMTime = mtime()
        // 热加载：轮询修改时间（兼容各种编辑器的原子写入 / 原地写入）
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in ConfigStore.shared.reloadIfChanged() }
        }
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
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config), data != lastData else { return }
        do {
            try data.write(to: url, options: .atomic)
            lastData = data
            lastMTime = mtime()
        } catch {
            Log.write("配置写入失败：\(error.localizedDescription)")
        }
    }

    func reloadIfChanged() {
        let m = mtime()
        guard m != lastMTime else { return }
        lastMTime = m
        guard let data = try? Data(contentsOf: url), data != lastData else { return }
        guard let c = try? JSONDecoder().decode(NKConfig.self, from: data) else {
            Log.write("配置文件 JSON 格式错误，保留当前设置")
            return
        }
        lastData = data
        if c != config {
            applyingExternal = true
            config = c
            applyingExternal = false
            Log.write("已热加载配置文件")
        }
    }

    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openFile() { NSWorkspace.shared.open(url) }
}
