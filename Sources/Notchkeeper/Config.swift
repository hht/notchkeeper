import AppKit
import Combine
import GuardCore

/// 持久化到 ~/Library/Application Support/Notchkeeper/config.json。
/// 解码时缺失的字段一律用默认值，手动改坏一个字段不会丢掉整份配置。
struct NKConfig: Codable, Equatable {
    // 通用
    var soundEnabled = true
    var hoverExpand = true
    /// 盾盾的眼睛和身体跟着鼠标走、鼠标到刘海上时探头（docs/dundun.md §5）
    var dundunFollowsMouse = true
    // 出口守卫
    // 不内置任何真实出口：空列表时 guardd 判不了出口（unknown），设置页会提示
    var allowlist: [String] = []
    var autoAlert = true
    var alertPersistent = true
    // 通知
    var cardAutoDismissSeconds = 6.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NKConfig()
        func v<T: Decodable>(_ key: CodingKeys, _ def: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? def
        }
        soundEnabled = v(.soundEnabled, d.soundEnabled)
        hoverExpand = v(.hoverExpand, d.hoverExpand)
        dundunFollowsMouse = v(.dundunFollowsMouse, d.dundunFollowsMouse)
        allowlist = v(.allowlist, d.allowlist)
        autoAlert = v(.autoAlert, d.autoAlert)
        alertPersistent = v(.alertPersistent, d.alertPersistent)
        cardAutoDismissSeconds = min(10, max(2, v(.cardAutoDismissSeconds, d.cardAutoDismissSeconds)))
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published var config: NKConfig {
        didSet { if config != oldValue && !applyingExternal { scheduleSave() } }
    }

    let url = GuardPaths.configFile
    private var applyingExternal = false
    private var lastData: Data?
    private var lastMTime: Date?
    private var saveWork: DispatchWorkItem?
    private var pollTimer: Timer?

    init() {
        try? FileManager.default.createDirectory(at: GuardPaths.directory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(NKConfig.self, from: data) {
            config = c
            lastData = data
        } else {
            config = NKConfig()
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
