import Darwin
import Foundation

/// 回答：一个放 `.json` 的目录里此刻有哪些文件、什么时候有了动静。目录本身和里面每份文件各挂一个监听，有动静就调 `onChange`。
/// 不读文件内容。只在建它时给的队列上用（`AgentWatcher`）
final class WatchedDirectory {
    let url: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    /// 文件名 → 它的监听
    private var files: [String: DispatchSourceFileSystemObject] = [:]

    init(_ url: URL, queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.url = url
        self.queue = queue
        self.onChange = onChange
    }

    /// 目录不在就不看它，等 App 重启。返回打没打开
    func open() -> Bool {
        source = watch(url, events: [.write, .delete, .rename]) { [weak self] _ in self?.onChange() }
        return source != nil
    }

    /// 目录里的 `.json`，顺手给新文件挂上监听、关掉已经没了的。目录读不了就关掉全部监听再抛出：
    /// 挂在已删掉的目录上没用，也免得每次事件都再记一行
    func list() throws -> Set<String> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            source?.cancel()
            source = nil
            files.values.forEach { $0.cancel() }
            files.removeAll()
            throw error
        }
        let jsons = Set(names.filter { $0.hasSuffix(".json") })
        for name in files.keys where !jsons.contains(name) { files.removeValue(forKey: name)?.cancel() }
        // 先挂监听再读：读完到挂上之间的改动也收得到
        for name in jsons where files[name] == nil {
            files[name] = watch(url.appendingPathComponent(name), events: [.write, .extend, .delete, .rename]) { [weak self] data in
                guard let self else { return }
                if !data.isDisjoint(with: [.delete, .rename]) { files.removeValue(forKey: name)?.cancel() }
                onChange()
            }
        }
        return jsons
    }

    /// `O_EVTONLY`：只为收事件打开。打不开（文件刚被删）返回 nil
    private func watch(_ url: URL, events: DispatchSource.FileSystemEvent,
                       handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler { [unowned source] in handler(source.data) }
        source.setCancelHandler { close(fd) }
        source.activate()
        return source
    }
}
