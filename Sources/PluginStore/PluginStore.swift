import Darwin
import Foundation
import NotchCore
import PluginCore

/// 回答：插件目录里装了哪些外部插件，一个插件文件夹怎么装进去、怎么卸掉、怎么新建一个空插件。
/// 只做文件 I/O：登记合不合规归 `Manifest`，SF Symbol 在不在由调用方查（要 AppKit）。从不执行插件里的任何文件（CLAUDE.md 硬规则「插件」）。
/// 换下来的、卸掉的目录都挪进 `backup`，不删：新建的插件，目录里可能是用户唯一的一份脚本
public struct PluginStore: Sendable {
    public enum Problem: Error, Equatable, Sendable {
        /// 文件夹里没有 manifest.json
        case noManifest
        case manifest(ManifestError)
        case unknownSymbol(String)
        /// 是自带的终端插件的 id：那个目录归 App，每次启动都会被换掉
        case bundled
        /// 选中的就是已经装着的那个目录
        case alreadyInstalled
        case notInstalled
        /// 新建时同名插件已经装着
        case exists
    }

    public struct Installed: Sendable {
        public var manifest: Manifest
        /// 同 id 的旧版挪到了哪；nil 是新装
        public var replaced: URL?
    }

    public let plugins: URL
    public let backup: URL

    public init(plugins: URL = PluginPaths.plugins, backup: URL = PluginPaths.backup) {
        self.plugins = plugins
        self.backup = backup
    }

    /// 已登记的外部插件：`plugins/<id>/manifest.json`。读不了的交给 `onBad`（目录名，nil 是整个插件目录；错误），算没登记
    public func manifests(onBad: (String?, Error) -> Void = { _, _ in }) -> [String: Manifest] {
        let dirs: [String]
        do {
            dirs = try FileManager.default.contentsOfDirectory(atPath: plugins.path)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            onBad(nil, error)
            return [:]
        }
        var result: [String: Manifest] = [:]
        for dir in dirs {
            do {
                let manifest = try Manifest.parse(Self.readRegularFile(plugins.appendingPathComponent(dir).appendingPathComponent("manifest.json")),
                                                  directoryName: dir)
                result[manifest.id] = manifest
            } catch POSIXError.ENOENT, POSIXError.ENOTDIR {
                // 没登记的目录；.DS_Store 这类普通文件
                continue
            } catch {
                onBad(dir, error)
            }
        }
        return result
    }

    /// 要装的文件夹登记了什么：给用户确认用，什么都不改。文件夹叫什么都行，装进去的目录按 id 起名
    public func inspect(_ source: URL, symbolExists: (String) -> Bool) throws -> Manifest {
        let data: Data
        do {
            data = try Self.readRegularFile(source.appendingPathComponent("manifest.json"))
        } catch {
            // 选的是一个文件（ENOTDIR）也算没有。写成 `catch POSIXError.ENOENT` 时 Swift 6.3.3 编译器崩溃（typed throws 落进 untyped 函数）
            guard [.ENOENT, .ENOTDIR].contains(error.code) else { throw error }
            throw Problem.noManifest
        }
        return try Self.checked(data, symbolExists: symbolExists)
    }

    /// 拷进 `plugins/<id>/`，原文件夹不动。先拷到同一卷的临时目录：拷到一半失败时什么都没改。
    /// 选的是符号链接时拷它指向的文件夹：`copyItem` 只拷链接本身，相对链接装进来就断了
    public func install(_ source: URL, symbolExists: (String) -> Bool, now: Date) throws -> Installed {
        let source = source.resolvingSymlinksInPath()
        let manifest = try inspect(source, symbolExists: symbolExists)
        let destination = plugins.appendingPathComponent(manifest.id, isDirectory: true)
        guard source.standardizedFileURL.path != destination.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw Problem.alreadyInstalled }
        try createPluginsDirectory()
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: plugins, create: true)
        defer {
            // 系统的临时目录，换上去之后已经空了；删不掉只留一个空目录
            do { try fm.removeItem(at: staging) } catch {}
        }
        let copy = staging.appendingPathComponent(manifest.id, isDirectory: true)
        try fm.copyItem(at: source, to: copy)
        // 同一卷上的两次 rename：第二次失败时旧版已经在备份里
        let replaced = try exists(destination) ? moveToBackup(destination, id: manifest.id, now: now) : nil
        try fm.moveItem(at: copy, to: destination)
        return Installed(manifest: manifest, replaced: replaced)
    }

    /// 挪进备份，返回挪到了哪。终端插件的目录归 App（设置 › 终端里卸）
    public func uninstall(_ id: String, now: Date) throws -> URL {
        guard id != PluginID.terminal else { throw Problem.bundled }
        let dir = plugins.appendingPathComponent(id, isDirectory: true)
        guard Message.isPluginID(id), try exists(dir) else { throw Problem.notInstalled }
        return try moveToBackup(dir, id: id, now: now)
    }

    /// 只有 manifest.json 的空插件：给自己写脚本用
    public func create(id: String, name: String, symbol: String, symbolExists: (String) -> Bool) throws -> Manifest {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: ["id": id, "name": name, "symbol": symbol], options: [.prettyPrinted, .sortedKeys])
        } catch {
            preconditionFailure("只有字符串")
        }
        let manifest = try Self.checked(data, symbolExists: symbolExists)
        let dir = plugins.appendingPathComponent(id, isDirectory: true)
        guard try !exists(dir) else { throw Problem.exists }
        try createPluginsDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        return manifest
    }

    /// 只读普通文件，至多 `Message.maxBytes + 1` 字节。不跟随符号链接（`O_NOFOLLOW`）、打开时不等（`O_NONBLOCK`）：
    /// 收件箱里放一个 FIFO，阻塞地打开会一直等写端，整条队列就卡死了
    /// @see man 2 open
    public static func readRegularFile(_ url: URL) throws(POSIXError) -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        // read(2) 可能读不满：读到文件尾或够了上限为止
        var data = Data(count: Message.maxBytes + 1)
        var total = 0
        while total < data.count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + total, $0.count - total) }
            guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            total += n
        }
        return data.prefix(total)
    }

    private static func checked(_ data: Data, symbolExists: (String) -> Bool) throws -> Manifest {
        let manifest: Manifest
        do {
            manifest = try Manifest.parse(data, directoryName: nil)
        } catch {
            throw Problem.manifest(error)
        }
        guard manifest.id != PluginID.terminal else { throw Problem.bundled }
        guard symbolExists(manifest.symbol) else { throw Problem.unknownSymbol(manifest.symbol) }
        return manifest
    }

    /// 和 InboxWatcher 一样 0700：别的用户写不进来
    private func createPluginsDirectory() throws {
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// 不跟随符号链接：`plugins/<id>` 是一个链接时也算装着
    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return false
        }
        return true
    }

    /// `backup/<id>-<本地时刻>`，同一秒里撞名就加序号
    private func moveToBackup(_ dir: URL, id: String, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let stamp = Date.ISO8601FormatStyle(dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted, timeZone: .current)
            .format(now)
        var target = backup.appendingPathComponent("\(id)-\(stamp)", isDirectory: true)
        var n = 2
        while try exists(target) {
            target = backup.appendingPathComponent("\(id)-\(stamp)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.moveItem(at: dir, to: target)
        return target
    }
}
