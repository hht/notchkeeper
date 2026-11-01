import AppKit
import Darwin
import PluginCore
import PluginStore

/// 回答：收件箱里来了哪些外部插件的卡和活动。
/// 只做 I/O：建目录（0700，别的用户写不进来）、监听 `inbox/new/`、读完即删、读插件登记；
/// 解不解得开、放不放、放成哪张卡全归 PluginCore（`Message`、`Manifest`、`InboxGate`）。可变状态只在 `queue` 上读写，所以标 `@unchecked Sendable`。
/// 消息是外部数据：日志里只记丢的原因（PluginCore 的枚举、errno）和计数，不记内容和文件名（CLAUDE.md 准则 5）。
final class InboxWatcher: @unchecked Sendable {
    /// 一次扫描收下的：卡、活动，和这时读到的插件登记
    struct Batch: Sendable {
        var cards: [InboxGate.Admitted] = []
        var activities: [ActivityUpdate] = []
        var plugins: [String: Manifest]
    }

    private let onBatch: @Sendable (Batch) -> Void
    private let queue = DispatchQueue(label: "com.notchkeeper.inbox")
    private var gate = InboxGate()
    /// 只看目录：照 Maildir 文件是 rename 进来的，不会原地改
    private lazy var inbox = WatchedDirectory(PluginPaths.new, watchesFiles: false, queue: queue) { [weak self] in self?.scan() }
    private var dropped = 0
    /// 删不掉的文件：不再读，免得每次有动静都再弹一次
    private var stuck: Set<String> = []
    /// 解不开的登记文件：只在第一次记日志
    private var badManifests: Set<String> = []

    /// `tmp/` 里这么久的是写到一半崩了的（照 Maildir）
    private static let staleTmp: TimeInterval = 36 * 3600

    /// `onBatch` 在内部队列上调用，只在收下了卡或活动时调用
    init(onBatch: @escaping @Sendable (Batch) -> Void) {
        self.onBatch = onBatch
    }


    func start() {
        queue.async { [self] in
            do {
                for dir in [PluginPaths.inbox, PluginPaths.tmp, PluginPaths.new, PluginPaths.plugins] {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                }
            } catch {
                Log.write("插件：建不了收件箱目录（\(Self.code(error))），不收外部插件的卡")
                return
            }
            pruneTmp()
            guard inbox.open() else {
                Log.write("插件：打不开收件箱（errno \(errno)），不收外部插件的卡")
                return
            }
            scan()
        }
    }

    /// 清不掉不影响收卡：记一行，下次启动再清
    private func pruneTmp() {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: PluginPaths.tmp.path)
        } catch {
            Log.write("插件：读不了收件箱的 tmp/（\(Self.code(error))），这次不清理")
            return
        }
        for name in names {
            let url = PluginPaths.tmp.appendingPathComponent(name)
            // 不跟随符号链接；刚被 pipctl rename 走的查不到，跳过
            var info = stat()
            guard lstat(url.path, &info) == 0,
                  -Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)).timeIntervalSinceNow > Self.staleTmp else { continue }
            remove(url)
        }
    }

    private func scan() {
        let names: Set<String>
        do {
            names = try inbox.list()
        } catch {
            Log.write("插件：读收件箱失败（\(Self.code(error))），不收外部插件的卡")
            return
        }
        var messages: [Message] = []
        for name in names.subtracting(stuck) {
            let url = inbox.url.appendingPathComponent(name)
            let data: Data
            do {
                data = try PluginStore.readRegularFile(url)
            } catch POSIXError.ENOENT {
                continue
            } catch {
                drop("读不了（errno \(error.code.rawValue)）")
                remove(url)
                continue
            }
            remove(url)
            guard data.count <= Message.maxBytes else {
                drop("太大")
                continue
            }
            do {
                messages.append(try Message.parse(data))
            } catch {
                drop("解不开（\(error)）")
            }
        }
        guard !messages.isEmpty else { return }
        // 每次有消息时现读（插件只有几个），装上、卸掉不用重启 App
        let plugins = Self.manifests { dir, error in
            if badManifests.insert(dir).inserted { Log.write("插件：\(Self.safe(dir)) 的 manifest.json 读不了或解不开（\(error)），算没登记") }
        }
        badManifests.subtract(plugins.keys) // 修好了的：再坏时再记
        let now = Date()
        var batch = Batch(plugins: plugins)
        for m in messages.sorted(by: { $0.at < $1.at }) {
            do {
                if m.activity == nil {
                    batch.cards.append(try gate.admit(m, plugins: plugins, now: now))
                } else {
                    batch.activities.append(try gate.admitActivity(m, plugins: plugins, now: now))
                }
            } catch .unregistered {
                drop("插件 \(m.plugin) 没登记") // id 已按格式校验过，可以进日志
            } catch {
                drop("插件 \(m.plugin)：\(error)")
            }
        }
        if !batch.cards.isEmpty || !batch.activities.isEmpty { onBatch(batch) }
    }

    /// 已登记的外部插件。读不了的交给 `onBad`，算没登记；设置页也用它列插件。
    /// 图标名系统里没有的（装好后登记被改过）换成拼图块：照样收卡，卡上不会空一块
    static func manifests(onBad: (String, Error) -> Void = { _, _ in }) -> [String: Manifest] {
        PluginStore().manifests { dir, error in
            guard let dir else { return Log.write("插件：读不了插件目录（\(code(error))），都算没登记") }
            onBad(dir, error)
        }.mapValues { m in
            guard !symbolExists(m.symbol) else { return m }
            var fixed = m
            fixed.symbol = "puzzlepiece.extension"
            return fixed
        }
    }

    /// 每次新建一个 NSImage、不跨线程共用：Apple 允许在别的线程创建（Thread Safety Summary「NSImage Restrictions」），收件箱队列上也调
    /// @see https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html
    @Sendable static func symbolExists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// 目录名是外部的：只留字母、数字、连字符，截短再记
    private static func safe(_ dir: String) -> String {
        String(String.UnicodeScalarView(dir.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") }).prefix(32))
    }

    private func drop(_ why: String) {
        dropped += 1
        Log.write("插件：丢掉一条消息，\(why)（共丢 \(dropped) 条）")
    }

    /// 只删这一项：是符号链接就删链接本身
    private func remove(_ url: URL) {
        guard unlink(url.path) != 0, errno != ENOENT else { return }
        stuck.insert(url.lastPathComponent)
        Log.write("插件：收件箱里有文件删不掉（errno \(errno)），不再读它")
    }

    /// 只带错误码：Foundation 的错误描述里有路径，路径里有外部写的文件名
    private static func code(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code)"
    }
}
