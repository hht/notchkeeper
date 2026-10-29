import Foundation
import GuardCore

/// 回答：`guard-state.json` 现在该显示成什么；变了就推给订阅方，代替 App 每 5 秒轮询。
/// 只做 I/O：监听目录、起定时器、读文件。什么时候读归 `GuardReadSchedule`，读出来显示什么归 `GuardStateReader.display`，
/// 这里不重复任何一条规则。不知道目录在哪（由调用方传入，App 传 `GuardPaths.directory`，测试传临时目录），不写任何文件。
///
/// 监听的是**目录**不是文件：guardd 用临时文件 + `rename(2)` 替换（guardd 的 `StateFile`），
/// 打开文件本身的 fd 在第一次替换后就指向旧 inode，再也收不到事件；目录项变化会让目录收到 `.write`。
/// 同目录的 `config.json` 变了也会触发，只是多读一次；显示结果没变就不发。
/// 目录自己被删或改名（`.delete` / `.rename`）时关掉旧 fd，之后每次读之前都试着重开，直到目录回来。
/// @see https://developer.apple.com/documentation/dispatch/dispatchsource/makefilesystemobjectsource(filedescriptor:eventmask:queue:)
/// @see https://keith.github.io/xcode-man-pages/open.2.html （`O_EVTONLY`：只为收事件打开，不阻止卷被卸载）
///
/// 定时器用墙上时间（`DispatchWallTime`）：Mac 睡眠时墙上时间照走，醒来后过期重读和兜底马上到期。
/// @see https://developer.apple.com/documentation/dispatch/dispatchwalltime
public struct GuardStateWatcher: Sendable {
    public var directory: URL
    public var fileName: String
    public var interval: Duration
    public var debounce: Duration
    public var fallbackInterval: Duration
    public var now: @Sendable () -> Date

    public init(directory: URL, fileName: String = GuardState.fileName, interval: Duration = PollSchedule.interval,
                debounce: Duration = .milliseconds(100), fallbackInterval: Duration = .seconds(30),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.fileName = fileName
        self.interval = interval
        self.debounce = debounce
        self.fallbackInterval = fallbackInterval
        self.now = now
    }

    /// 开始监听：马上发一次当前显示，之后只在显示结果变了时再发。只留最新一个值，订阅方慢了不会积压旧状态。
    /// 订阅方停止迭代（任务取消或流被释放）时，目录监听和定时器一起取消。
    public func displays() -> AsyncStream<GuardDisplay> { displays(onStart: { _ in }) }

    /// `onStart` 只给测试拿到 `Session`，检查停止后有没有留下后台源。
    func displays(onStart: (Session) -> Void) -> AsyncStream<GuardDisplay> {
        let (stream, continuation) = AsyncStream.makeStream(of: GuardDisplay.self, bufferingPolicy: .bufferingNewest(1))
        let session = Session(watcher: self, continuation: continuation)
        continuation.onTermination = { _ in session.stop() }
        onStart(session)
        session.start()
        return stream
    }

    /// 一次订阅的运行状态。可变状态只在 `queue` 上读写，所以标 `@unchecked Sendable`。
    final class Session: @unchecked Sendable {
        private let watcher: GuardStateWatcher
        private let continuation: AsyncStream<GuardDisplay>.Continuation
        private let queue = DispatchQueue(label: "com.notchkeeper.guard-state-watcher")
        private var schedule: GuardReadSchedule
        private var directorySource: DispatchSourceFileSystemObject?
        private var timer: DispatchSourceTimer?
        private var lastDisplay: GuardDisplay?

        init(watcher: GuardStateWatcher, continuation: AsyncStream<GuardDisplay>.Continuation) {
            self.watcher = watcher
            self.continuation = continuation
            schedule = GuardReadSchedule(interval: watcher.interval, debounce: watcher.debounce,
                                         fallbackInterval: watcher.fallbackInterval, now: watcher.now())
        }

        /// 目录监听和定时器都已取消（停止后才为真；目录不存在时监听本来就没开，看定时器）
        var sourcesCancelled: Bool { queue.sync { directorySource == nil && timer == nil } }

        func start() {
            queue.async { [self] in
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.activate()
                tick() // schedule 新建时就到期：马上读第一次
            }
        }

        func stop() {
            queue.async { [self] in
                directorySource?.cancel()
                directorySource = nil
                timer?.cancel()
                timer = nil
            }
        }

        private func tick() {
            guard timer != nil else { return } // 已停止
            let now = watcher.now()
            if schedule.isReadDue(at: now) { read(at: now) }
            rearm()
        }

        private func read(at now: Date) {
            if directorySource == nil { openDirectory() }
            let display = GuardStateReader.display(data: loadFile(), now: now, interval: watcher.interval)
            schedule.didRead(checkedAt: display.checkedAt, at: now)
            if display != lastDisplay {
                lastDisplay = display
                continuation.yield(display)
            }
        }

        /// 文件不存在是正常状态（guardd 没装或没跑过），交给 reader 报 missing；
        /// 别的读错误（权限等）当成读出了坏内容，reader 报 unreadable，不吞成「没有文件」。
        private func loadFile() -> Data? {
            do {
                return try Data(contentsOf: watcher.directory.appendingPathComponent(watcher.fileName))
            } catch CocoaError.fileReadNoSuchFile {
                return nil
            } catch {
                return Data()
            }
        }

        private func openDirectory() {
            let fd = open(watcher.directory.path, O_EVTONLY)
            guard fd >= 0 else { return } // 目录不在：下次读（最晚兜底时）再试
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self] in self?.directoryEvent() }
            source.setCancelHandler { close(fd) }
            directorySource = source
            source.activate()
        }

        private func directoryEvent() {
            guard let source = directorySource else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // 旧 fd 跟着被删 / 改名的目录走了，留着没用；重开交给下一次读
                source.cancel()
                directorySource = nil
            }
            schedule.directoryChanged(at: watcher.now())
            rearm()
        }

        private func rearm() {
            let delay = max(0, schedule.nextReadAt.timeIntervalSince(watcher.now()))
            timer?.schedule(wallDeadline: .now() + delay, leeway: .milliseconds(10))
        }
    }
}
