import Foundation
import GuardCore
import Testing
@testable import GuardWatch

/// 真文件系统的集成测试：每个测试一个临时目录，绝不碰 ~/Library。时序相关的判定（合并、过期、兜底）在
/// GuardCoreTests 的 `GuardReadScheduling` 里用手动时间测，这里只验接线，等待一律有 3 秒上限。
@Suite(.serialized) struct GuardStateWatching {
    @Test func initialEmissionReflectsCurrentFile() async throws {
        let dir = try TempDir()
        try writeState(.healthy, in: dir.url)
        let r = Recorder(GuardStateWatcher(directory: dir.url).displays())
        let first = try #require(await r.first { _ in true })
        #expect(first.verdict == .healthy)
        #expect(first.reason == .fresh)
    }

    @Test func initialEmissionForMissingFileIsMissing() async throws {
        let dir = try TempDir()
        let r = Recorder(GuardStateWatcher(directory: dir.url).displays())
        #expect(await r.first { _ in true }?.reason == .missing)
    }

    /// guardd 的写法（同目录临时文件 + rename）：文件 fd 会失效，监听目录才收得到
    @Test func atomicReplaceEmitsNewVerdict() async throws {
        let dir = try TempDir()
        try writeState(.healthy, in: dir.url)
        let r = Recorder(GuardStateWatcher(directory: dir.url).displays())
        _ = await r.first { $0.verdict == .healthy }
        try writeState(.violated, in: dir.url)
        #expect(await r.first { $0.verdict == .violated }?.lastVerdict == .violated)
        // 再连写几次也照样跟上（连写在合并窗口里只读一次，见 GuardReadScheduling.rapidEventsCoalesceIntoOneRead）
        for v in [Verdict.unknown, .healthy, .egressMismatch] { try writeState(v, in: dir.url) }
        #expect(await r.first { $0.verdict == .egressMismatch } != nil)
    }

    /// 只在显示结果变了才发：config.json 改了、兜底重读到一样的内容，都不重复发
    @Test func unchangedDisplayIsNotReemitted() async throws {
        let dir = try TempDir()
        try writeState(.healthy, in: dir.url)
        let r = Recorder(GuardStateWatcher(directory: dir.url, fallbackInterval: .milliseconds(100)).displays())
        _ = await r.first { _ in true }
        try Data("{}".utf8).write(to: dir.url.appendingPathComponent("config.json"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(r.values.count == 1)
    }

    /// 目录被删（比如卸载）再建回来：目录 fd 失效，兜底时重开目录，之后的写照样收到
    @Test func recoversAfterDirectoryIsDeletedAndRecreated() async throws {
        let dir = try TempDir()
        try writeState(.healthy, in: dir.url)
        let r = Recorder(GuardStateWatcher(directory: dir.url, fallbackInterval: .milliseconds(300)).displays())
        _ = await r.first { $0.verdict == .healthy }
        try FileManager.default.removeItem(at: dir.url)
        #expect(await r.first { $0.reason == .missing } != nil)
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: false)
        try await Task.sleep(for: .milliseconds(500)) // 等兜底重开目录
        try writeState(.violated, in: dir.url)
        #expect(await r.first { $0.verdict == .violated } != nil)
    }

    /// 订阅方不再迭代（任务取消）：目录监听和定时器都要取消，不留后台源
    @Test func streamTerminationCancelsSources() async throws {
        let dir = try TempDir()
        let box = SessionBox()
        let stream = GuardStateWatcher(directory: dir.url).displays(onStart: { box.session = $0 })
        let task = Task { for await _ in stream {} }
        let session = try #require(await poll { box.session })
        #expect(await poll { session.sourcesCancelled ? nil : true } == true)
        task.cancel()
        #expect(await poll { session.sourcesCancelled ? true : nil } == true)
    }

    /// 只看传进来的目录：别的目录里的文件和写入都不影响，也不在任何地方建文件或目录
    @Test func onlyTouchesGivenDirectory() async throws {
        let root = try TempDir()
        let watched = root.url.appendingPathComponent("watched"), other = root.url.appendingPathComponent("other")
        let absent = root.url.appendingPathComponent("absent")
        for d in [watched, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false) }
        try writeState(.violated, in: other)

        let r = Recorder(GuardStateWatcher(directory: watched).displays())
        let gone = Recorder(GuardStateWatcher(directory: absent).displays())
        #expect(await r.first { _ in true }?.reason == .missing)
        #expect(await gone.first { _ in true }?.reason == .missing)
        try writeState(.healthy, in: other)
        try await Task.sleep(for: .milliseconds(300))
        #expect(r.values.map(\.reason) == [.missing])

        let fm = FileManager.default
        #expect(try fm.contentsOfDirectory(atPath: root.url.path).sorted() == ["other", "watched"])
        #expect(try fm.contentsOfDirectory(atPath: watched.path).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: other.path) == [GuardState.fileName])
    }
}

// MARK: - 测试工具

/// `FileManager.default.temporaryDirectory` 下的一次性目录，测试结束删掉
private final class TempDir {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("GuardWatchTests-\(UUID().uuidString)", isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// 照 guardd `StateFile.write` 的写法：同目录临时文件写完再 rename
private func writeState(_ verdict: Verdict, in dir: URL) throws {
    let s = GuardState(verdict: verdict, observation: Observation(clashRunning: true, routeInterface: "utun1024", egressIPs: []),
                       allowlist: [], egressFailures: [:], networkPath: nil, violatedSince: Date(), checkedAt: Date())
    let tmp = dir.appendingPathComponent(".\(GuardState.fileName).test.tmp")
    try s.encoded().write(to: tmp)
    guard rename(tmp.path, dir.appendingPathComponent(GuardState.fileName).path) == 0 else { throw POSIXError(.EIO) }
}

/// 后台把流里的值收进数组，测试按条件等
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GuardDisplay] = []
    private var task: Task<Void, Never>?
    var values: [GuardDisplay] { lock.withLock { stored } }

    init(_ stream: AsyncStream<GuardDisplay>) {
        task = Task { [weak self] in
            for await d in stream { self?.lock.withLock { self?.stored.append(d) } }
        }
    }
    deinit { task?.cancel() }

    /// 等到有一个值满足条件（最多 3 秒）
    func first(where match: @escaping @Sendable (GuardDisplay) -> Bool) async -> GuardDisplay? {
        await poll { self.values.first(where: match) }
    }
}

private final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GuardStateWatcher.Session?
    var session: GuardStateWatcher.Session? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// 每 20ms 看一次，3 秒内拿到非 nil 就返回
private func poll<T>(_ body: @Sendable () -> T?) async -> T? {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
        if let v = body() { return v }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}
