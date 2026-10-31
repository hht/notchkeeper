import AgentCore
import Darwin
import Foundation
import GuardCore

/// 回答：Claude Code 各会话合起来此刻是什么 agent 动态、刚发生了哪些该提醒的事。
/// 只做 I/O：监听 `~/.claude/sessions` 和 mod 写的 `turns/`（docs/agent-integration.md「两个来源」）、读文件、查进程、
/// 挂进程退出通知和一个到点定时器；要不要看、什么状态、回合怎么结束的全归 AgentCore（`SessionFile`、`TurnFile`、`AgentBoard`），
/// 这里不重复任何一条规则。可变状态只在 `queue` 上读写，所以标 `@unchecked Sendable`。
///
/// 三种通知，来了都把两个目录整个重读一遍（会话只有几个，每份不到 1KB）：
/// - 目录 `.write`：新会话加文件、正常退出删文件。
/// - 每份 `.json` 自己的 `.write` / `.extend`：Claude Code 原地重写状态（inode 不变，目录收不到事件，10-29 实测）；
///   文件被删或改名（`.delete` / `.rename`）就关掉它的监听，重读时按目录现状重开。
/// - 每个会话进程的退出通知：`kill -9` 后文件留着、目录不变（docs/agent-integration.md「实测」4）。
/// @see https://developer.apple.com/documentation/dispatch/dispatchsource/makefilesystemobjectsource(filedescriptor:eventmask:queue:)
/// @see https://developer.apple.com/documentation/dispatch/dispatchsource/makeprocesssource(identifier:eventmask:queue:)
final class AgentWatcher: @unchecked Sendable {
    struct Update: Sendable {
        var activity: AgentActivity?
        var sessions: [Session]
        var events: [AgentEvent]
    }

    private let onUpdate: @Sendable (Update) -> Void
    private let queue = DispatchQueue(label: "com.notchkeeper.agent-watcher")
    private var board = AgentBoard(since: Date())
    private lazy var sessionFiles = WatchedDirectory(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true),
                                              queue: queue) { [weak self] in self?.scan() }
    private lazy var turnFiles = WatchedDirectory(GuardPaths.directory.appendingPathComponent("turns", isDirectory: true),
                                           queue: queue) { [weak self] in self?.scan() }
    /// 正在看的会话：pid → 它的退出通知
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var timer: DispatchSourceTimer?
    private var lastActivity: AgentActivity?
    private var lastSessions: [Session] = []
    /// 解不开的文件：只在新出现时记一次日志（准则 5：计数、跳过，不覆盖原文件）
    private var unreadable: Set<URL> = []

    /// 回合文件这么久没写过，就是 `/clear` 或 App 没开时退出的会话留下的。还活着的会话下一个回合结束会重写，删了也不丢提醒
    private static let staleTurnFile: TimeInterval = 7 * 24 * 3600

    /// `onUpdate` 在内部队列上调用，只在动态、会话列表变了或有事件时调用
    init(onUpdate: @escaping @Sendable (Update) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.publish(events: []) }
            self.timer = timer
            timer.activate()
            if !sessionFiles.open() { Log.write("agent：打不开会话目录（errno \(errno)），不看 agent 状态") }
            // 回合文件的目录归 App：先建好才能监听，mod 还没写过也一样
            do {
                try FileManager.default.createDirectory(at: turnFiles.url, withIntermediateDirectories: true)
                try pruneTurnFiles()
            } catch {
                Log.write("agent：建不了或读不了回合文件目录：\(error.localizedDescription)")
            }
            if !turnFiles.open() { Log.write("agent：打不开回合文件目录（errno \(errno)），不弹完成卡、出错卡") }
            scan()
        }
    }

    private func pruneTurnFiles() throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        for url in try FileManager.default.contentsOfDirectory(at: turnFiles.url, includingPropertiesForKeys: Array(keys))
        where url.pathExtension == "json" {
            guard let modified = try url.resourceValues(forKeys: keys).contentModificationDate,
                  -modified.timeIntervalSinceNow > Self.staleTurnFile else { continue }
            removeTurnFile(url)
        }
    }

    /// 本来就没有（mod 没装、这个会话里没加载）不算错
    private func removeTurnFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            Log.write("agent：删不掉回合文件：\(error.localizedDescription)")
        }
    }

    private func scan() {
        let now = Date()
        var events: [AgentEvent] = []
        let names: Set<String>
        do {
            names = try sessionFiles.list()
        } catch {
            Log.write("agent：读会话目录失败，不看 agent 状态：\(error.localizedDescription)")
            publish(events: exitSources.keys.compactMap(forget))
            return
        }
        var present: Set<Int32> = []
        for name in names {
            let url = sessionFiles.url.appendingPathComponent(name)
            let session: Session?
            do {
                session = try SessionFile.parse(Data(contentsOf: url))
            } catch CocoaError.fileReadNoSuchFile {
                continue // 列目录之后、读之前进程正常退出删掉了
            } catch {
                // 读不了、解不开都跳过，但不当成没了：上一次读到的状态留着
                if let pid = Int32(name.dropLast(5)) { present.insert(pid) }
                markUnreadable(url, error)
                continue
            }
            unreadable.remove(url)
            guard let session else { continue }
            watchExit(session.pid) // 先挂通知再查进程：查完到挂上之间退出的也收得到
            guard Self.isRunning(pid: session.pid, since: session.processStart) else { continue }
            present.insert(session.pid)
            if let event = board.update(session, at: now) { events.append(event) }
        }
        events += exitSources.keys.filter { !present.contains($0) }.compactMap(forget)
        // 会话先于回合文件：新会话的回合文件对得上
        do {
            for name in try turnFiles.list() {
                let url = turnFiles.url.appendingPathComponent(name)
                do {
                    let report = try TurnFile.parse(Data(contentsOf: url))
                    unreadable.remove(url)
                    if let event = board.update(report, at: now) { events.append(event) }
                } catch CocoaError.fileReadNoSuchFile {
                    continue
                } catch {
                    markUnreadable(url, error)
                }
            }
        } catch {
            Log.write("agent：读回合文件目录失败，不弹完成卡、出错卡：\(error.localizedDescription)")
        }
        publish(events: events)
    }

    private func markUnreadable(_ url: URL, _ error: Error) {
        if unreadable.insert(url).inserted {
            Log.write("agent：\(url.deletingLastPathComponent().lastPathComponent) 里有文件解不开，跳过（共 \(unreadable.count) 份）：\(error)")
        }
    }
    /// 进程在，并且启动时刻和文件里的 `procStart` 一致（防 pid 复用）。查不到（进程没了或判不出来）都算不在
    /// @see https://opensource.apple.com/source/xnu/xnu-7195.81.3/bsd/sys/proc_info.h （`proc_bsdinfo.pbi_start_tvsec`）
    static func isRunning(pid: Int32, since processStart: Date) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return TimeInterval(info.pbi_start_tvsec) == processStart.timeIntervalSince1970
    }

    private func watchExit(_ pid: Int32) {
        guard exitSources[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.publish(events: [self.forget(pid)].compactMap { $0 })
        }
        exitSources[pid] = source
        source.activate()
    }

    /// 不再看这个进程，删掉它的回合文件（mod 不会再写）；它正在需要你介入时返回介入结束
    private func forget(_ pid: Int32) -> AgentEvent? {
        exitSources.removeValue(forKey: pid)?.cancel()
        if let session = board.sessions.first(where: { $0.pid == pid }) {
            removeTurnFile(turnFiles.url.appendingPathComponent(session.sessionId + ".json"))
        }
        return board.remove(pid: pid)
    }

    private func publish(events: [AgentEvent]) {
        let now = Date()
        let activity = board.activity(at: now)
        if let next = board.nextChange(after: now) {
            timer?.schedule(wallDeadline: .now() + next.timeIntervalSince(now), leeway: .milliseconds(10))
        }
        let sessions = board.sessions
        guard activity != lastActivity || sessions != lastSessions || !events.isEmpty else { return }
        lastActivity = activity
        lastSessions = sessions
        onUpdate(Update(activity: activity, sessions: sessions, events: events))
    }
}
