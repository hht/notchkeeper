import AgentCore
import Foundation

/// 回答：`~/.claude/projects` 下最近在动的主会话有哪些，各自尾部的记录说明它处在哪一步。
/// 只读：只列目录、读文件 mtime、读每个文件最后一小段，不读整个文件，不写任何东西，不碰 ~/.claude 的设置。
/// 不决定要不要提醒（`SessionEvent`），也不知道 UI。
///
/// 目录结构（Claude Code 2.1.x 实测）：主会话是 `<编码后的项目路径>/<会话 id>.jsonl`；
/// 子 agent 在 `<编码后的项目路径>/<会话 id>/subagents/*.jsonl`，只列两层就不会进去，`ClaudeSubagentFilter` 再兜一层。
public struct ClaudeSessionFiles: Sendable {
    public struct File: Sendable, Equatable {
        public var id: String
        public var url: URL
        public var mtime: Date
    }

    public struct Scan: Sendable, Equatable {
        public var sessions: [AgentSession]
        /// 解析不了的行数（不含窗口开头被截断的半行），只用来观察格式有没有变
        public var malformedLines: Int
    }

    public var root: URL
    /// 只看这段时间内写过的会话
    public var recentWindow: TimeInterval
    public var maxFiles: Int

    /// 先读尾部 64KB。窗口里没有一条能参与判定的主会话记录时（典型情况：最后一条记录超过 64KB，窗口里只剩它的残片），
    /// 放大到 1MB 再读一次；1MB 里仍然没有，这次扫描就不报这个会话。从不读整个文件。
    static let tailSizes = [64 * 1024, 1024 * 1024]

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
                recentWindow: TimeInterval = 30 * 60, maxFiles: Int = 16) {
        self.root = root
        self.recentWindow = recentWindow
        self.maxFiles = maxFiles
    }

    /// 最近修改的主会话文件，新的在前。
    public func mainSessionFiles(now: Date) throws -> [File] {
        let fm = FileManager.default
        var out: [File] = []
        for dir in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        where (try dir.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                  options: [.skipsHiddenFiles])
            where url.pathExtension == "jsonl"
                && !ClaudeSubagentFilter.isSubagentFile(relativePath: "\(dir.lastPathComponent)/\(url.lastPathComponent)") {
                let v = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard v.isRegularFile == true, let m = v.contentModificationDate, now.timeIntervalSince(m) < recentWindow else { continue }
                out.append(File(id: url.deletingPathExtension().lastPathComponent, url: url, mtime: m))
            }
        }
        return Array(out.sorted { $0.mtime > $1.mtime }.prefix(maxFiles))
    }

    /// 读不了的目录或文件（会话目录不存在、文件刚被删）当作没有会话，不崩。
    public func scan(now: Date) -> Scan {
        var result = Scan(sessions: [], malformedLines: 0)
        guard let files = try? mainSessionFiles(now: now) else { return result }
        for f in files {
            for size in Self.tailSizes {
                guard let lines = try? Self.tailLines(of: f.url, bytes: size) else { break }
                let records = lines.compactMap { ClaudeRecord(jsonLine: $0) }
                if let s = AgentSession(claudeSessionID: f.id, records: records) {
                    result.malformedLines += lines.count - records.count
                    result.sessions.append(s.resolved(now: now, lastWrite: f.mtime))
                    break
                }
            }
        }
        return result
    }

    /// 文件最后 `bytes` 字节按行切开；不是从文件开头读的话，第一段是半行，丢掉。
    static func tailLines(of url: URL, bytes: Int) throws -> [Data] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = try h.seekToEnd()
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try h.seek(toOffset: start)
        let data = try h.readToEnd() ?? Data()
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.map { Data($0) }
    }
}

/// 回答：什么时候重新扫描、把扫描结果和上一次比出事件、交给 UI。App 进程内直接用，不经过 guardd。
/// 2 秒轮询一次：会话文件少（几十个），每次只 stat 加读尾部，代价很小；扫描在后台跑，结果回主线程。
/// 扫描一个接一个跑，不会重叠；以后要换 FSEvents，只替换 `start()` 里的触发方式，`tick()` 不变。
@MainActor
public final class ClaudeSessionWatcher {
    /// 每次扫描后在主线程调用：当前全部主会话（新的在前），和这次扫描新产生的事件（多数时候为空）
    public var onUpdate: (([AgentSession], [SessionEvent]) -> Void)?

    private let files: ClaudeSessionFiles
    private let interval: Duration
    private let clock: @Sendable () -> Date
    private var previous: [AgentSession] = []
    private var loop: Task<Void, Never>?

    public init(files: ClaudeSessionFiles = ClaudeSessionFiles(), interval: Duration = .seconds(2),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.files = files
        self.interval = interval
        self.clock = clock
    }

    /// 立刻扫一次，之后每 `interval` 一次；重复调用无副作用。
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self, interval] in
            while !Task.isCancelled {
                guard await self?.tick() != nil else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// 停止后不再调用 `onUpdate`，正在跑的那次扫描结果也丢掉。再次 `start()` 时第一次扫描不产生事件之外的重放（沿用上次的结果比较）。
    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// 扫一次（在后台）并在主线程上比较、回调。测试直接调用，时间由 `clock` 注入。
    @discardableResult
    func tick() async -> [SessionEvent] {
        let files = self.files, now = clock()
        let current = await Task.detached(priority: .utility) { files.scan(now: now).sessions }.value
        guard !Task.isCancelled else { return [] }
        let events = SessionEvent.diff(old: previous, new: current)
        previous = current
        onUpdate?(current, events)
        return events
    }
}
