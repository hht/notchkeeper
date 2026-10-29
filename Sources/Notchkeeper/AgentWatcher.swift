import AgentCore
import Darwin
import Foundation

/// 回答：Claude Code 各会话合起来此刻是什么 agent 动态、刚发生了哪些该提醒的事。
/// 只做 I/O：监听 `~/.claude/sessions`、读文件、查进程、挂进程退出通知和一个到点定时器；
/// 要不要看、什么状态、回合有没有结束全归 AgentCore（`SessionFile`、`AgentBoard`），这里不重复任何一条规则。
/// 可变状态只在 `queue` 上读写，所以标 `@unchecked Sendable`。
///
/// 三种通知，来了都把整个目录重读一遍（会话只有几个，每份不到 1KB）：
/// - 目录 `.write`：新会话加文件、正常退出删文件。
/// - 每份 `<pid>.json` 自己的 `.write` / `.extend`：Claude Code 原地重写状态（inode 不变，目录收不到事件，10-29 实测）；
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

    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
    private let onUpdate: @Sendable (Update) -> Void
    private let queue = DispatchQueue(label: "com.notchkeeper.agent-watcher")
    private var board = AgentBoard()
    private var directorySource: DispatchSourceFileSystemObject?
    /// 文件名 → 它的监听
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    /// 正在看的会话：pid → 它的退出通知
    private var exitSources: [Int32: DispatchSourceProcess] = [:]
    private var timer: DispatchSourceTimer?
    private var lastActivity: AgentActivity?
    private var lastSessions: [Session] = []
    /// 解不开的文件名：只在新出现时记一次日志（准则 5：计数、跳过，不覆盖原文件）
    private var unreadable: Set<String> = []

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
            openDirectory()
            scan()
        }
    }

    /// 目录不在（没装过 claude）就不看 agent 状态，等 App 重启。目录被删或改名时重读会失败，清空全部会话
    private func openDirectory() {
        directorySource = watch(directory, events: [.write, .delete, .rename]) { [weak self] _ in self?.scan() }
        if directorySource == nil { Log.write("agent：打不开会话目录（errno \(errno)），不看 agent 状态") }
    }

    /// `O_EVTONLY`：只为收事件打开。打不开（文件刚被删）返回 nil
    private func watch(_ url: URL, events: DispatchSource.FileSystemEvent,
                       handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler { [unowned source] in handler(source.data) }
        source.setCancelHandler { close(fd) }
        source.activate()
        return source
    }

    private func watchFile(_ name: String) {
        guard fileSources[name] == nil else { return }
        fileSources[name] = watch(directory.appendingPathComponent(name), events: [.write, .extend, .delete, .rename]) { [weak self] data in
            guard let self else { return }
            if !data.isDisjoint(with: [.delete, .rename]) { fileSources.removeValue(forKey: name)?.cancel() }
            scan()
        }
    }

    private func scan() {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            Log.write("agent：读会话目录失败，不看 agent 状态：\(error.localizedDescription)")
            directorySource?.cancel() // 挂在已删掉的目录上没用，也免得每次事件都再记一行
            directorySource = nil
            fileSources.values.forEach { $0.cancel() }
            fileSources.removeAll()
            for pid in exitSources.keys { forget(pid) }
            publish(events: [])
            return
        }
        let now = Date()
        var events: [AgentEvent] = []
        var present: Set<Int32> = []
        let files = Set(names.filter { $0.hasSuffix(".json") })
        for name in fileSources.keys where !files.contains(name) { fileSources.removeValue(forKey: name)?.cancel() }
        for name in files {
            watchFile(name) // 先挂监听再读：读完到挂上之间的改动也收得到
            let session: Session?
            do {
                session = try SessionFile.parse(Data(contentsOf: directory.appendingPathComponent(name)))
            } catch CocoaError.fileReadNoSuchFile {
                continue // 列目录之后、读之前进程正常退出删掉了
            } catch {
                // 读不了、解不开都跳过，但不当成没了：上一次读到的状态留着
                if let pid = Int32(name.dropLast(5)) { present.insert(pid) }
                markUnreadable(name, error)
                continue
            }
            unreadable.remove(name)
            guard let session else { continue }
            watchExit(session.pid) // 先挂通知再查进程：查完到挂上之间退出的也收得到
            guard Self.isRunning(session) else { continue }
            present.insert(session.pid)
            if let event = board.update(session, at: now) { events.append(event) }
        }
        for pid in exitSources.keys where !present.contains(pid) { forget(pid) }
        publish(events: events)
    }

    private func markUnreadable(_ name: String, _ error: Error) {
        if unreadable.insert(name).inserted {
            Log.write("agent：会话文件解不开，跳过（共 \(unreadable.count) 份）：\(error)")
        }
    }

    /// 进程在，并且启动时刻和文件里的 `procStart` 一致（防 pid 复用）。查不到（进程没了或判不出来）都算不在
    /// @see https://opensource.apple.com/source/xnu/xnu-7195.81.3/bsd/sys/proc_info.h （`proc_bsdinfo.pbi_start_tvsec`）
    private static func isRunning(_ session: Session) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(session.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return TimeInterval(info.pbi_start_tvsec) == session.processStart.timeIntervalSince1970
    }

    private func watchExit(_ pid: Int32) {
        guard exitSources[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.forget(pid)
            self?.publish(events: [])
        }
        exitSources[pid] = source
        source.activate()
    }

    private func forget(_ pid: Int32) {
        exitSources.removeValue(forKey: pid)?.cancel()
        board.remove(pid: pid)
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
