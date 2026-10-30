import Foundation
import GuardCore

/// 回答：Notchkeeper 自带的 Claude Code mod 装没装、怎么装、怎么卸（docs/agent-integration.md「安装和卸载」）。
/// 只拷 mod 文件、跑 `claude plugin` 命令；不手改任何配置文件，不读 shell 配置。
enum ClaudeMod {
    enum Status: Equatable {
        case installed
        /// 装了，但在 Claude Code 里关掉了
        case disabled
        case notInstalled
        /// 固定的几个位置都没有 `claude`
        case noClaude
        /// `claude plugin list` 失败，附原因
        case unknown(String)
    }

    struct Failure: Error, LocalizedError {
        var errorDescription: String?
    }

    private static let pluginID = "notchkeeper@notchkeeper"
    private static let marketplace = "notchkeeper"
    /// marketplace 的固定位置：插件从这里原地加载，App 挪了位置也不受影响
    static let directory = GuardPaths.directory.appendingPathComponent("ClaudeMod", isDirectory: true)
    /// App 包里带的那份；`swift run` 直接跑时没有
    private static var bundled: URL? { Bundle.main.url(forResource: "ClaudeMod", withExtension: nil) }
    /// 只看这几个位置：原生安装、Homebrew（Apple 芯片、Intel）
    private static let candidates = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
                                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    static var claude: URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `claude plugin list --json` 的输出：一个数组，每项有 `id` 和 `enabled`
    static func status(fromList data: Data) throws -> Status {
        struct Entry: Decodable {
            var id: String
            var enabled: Bool
        }
        guard let mine = try JSONDecoder().decode([Entry].self, from: data).first(where: { $0.id == pluginID }) else { return .notInstalled }
        return mine.enabled ? .installed : .disabled
    }

    static func status() async -> Status {
        guard let claude else { return .noClaude }
        do {
            return try status(fromList: try await run(claude, ["plugin", "list", "--json"]))
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    static func install() async throws {
        guard let claude else { throw Failure(errorDescription: "找不到 claude") }
        try copyBundled()
        _ = try await run(claude, ["plugin", "install", "notchkeeper", "--marketplace", directory.path, "--json"])
        Log.write("Claude Code mod：已安装")
    }

    /// 去掉 marketplace 会连带卸掉插件、去掉 `enabledPlugins` 里那一项（<https://code.claude.com/docs/en/plugins/install#manage-marketplaces>）
    static func uninstall() async throws {
        guard let claude else { throw Failure(errorDescription: "找不到 claude") }
        _ = try await run(claude, ["plugin", "marketplace", "remove", marketplace, "--json"])
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            // 已经卸掉了，目录本来就不在
        }
        Log.write("Claude Code mod：已卸载")
    }

    /// App 启动时：装着的话换成 App 里带的这一版，下一个会话就用上（原地加载，不用改版本号）
    static func refreshIfInstalled() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try copyBundled()
        } catch {
            Log.write("Claude Code mod：更新失败：\(error.localizedDescription)")
        }
    }

    /// 先拷到同一卷的临时目录再整体换上去：拷到一半失败，原来那份还在（插件从这里原地加载）
    private static func copyBundled() throws {
        guard let bundled else { throw Failure(errorDescription: "这个构建没带 mod，用 scripts/run.sh 打包的 App 才有") }
        let fm = FileManager.default
        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory.deletingLastPathComponent(), create: true)
            .appendingPathComponent("ClaudeMod")
        defer {
            // 临时目录，换上去之后已经空了；删不掉只占一个空目录
            do { try fm.removeItem(at: staging.deletingLastPathComponent()) } catch { Log.write("Claude Code mod：删不掉临时目录：\(error.localizedDescription)") }
        }
        try fm.copyItem(at: bundled, to: staging)
        if fm.fileExists(atPath: directory.path) {
            _ = try fm.replaceItemAt(directory, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: directory)
        }
    }

    /// 跑一条 `claude` 命令，返回标准输出；退出码不是 0 就抛出，带输出的最后一行。60 秒没跑完就杀掉、抛出「超时」，
    /// 不管它起的子进程有没有关掉输出管道，都一定会回来
    private static func run(_ claude: URL, _ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = claude
        process.arguments = arguments
        // 别顺手起自动更新：子进程继承输出管道，读端就等不到 EOF
        process.environment = ProcessInfo.processInfo.environment.merging(["DISABLE_AUTOUPDATER": "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let run = Run(out: out.fileHandleForReading, err: err.fileHandleForReading)
        return try await withCheckedThrowingContinuation { continuation in
            run.start(continuation)
            out.fileHandleForReading.readabilityHandler = { run.append($0.availableData, pipe: 0) }
            err.fileHandleForReading.readabilityHandler = { run.append($0.availableData, pipe: 1) }
            process.terminationHandler = { run.exited($0.terminationStatus) }
            do {
                try process.run()
            } catch {
                run.finish(.failure(error))
                return
            }
            // 到点不管 claude 还在不在都收尾：它退出了、但它起的子进程还占着输出管道时，也等不到 EOF。已经交回过就什么也不做
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                run.finish(.failure(Failure(errorDescription: "超时")))
            }
        }
    }

    /// 一次命令的输出和结局：退出了、两路都读到 EOF 才算完；只交回一次
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let handles: [FileHandle]
        private var continuation: CheckedContinuation<Data, Error>?
        /// [标准输出, 标准错误]
        private var data = [Data(), Data()]
        private var closed = [false, false]
        private var status: Int32?

        init(out: FileHandle, err: FileHandle) { handles = [out, err] }

        func start(_ c: CheckedContinuation<Data, Error>) {
            lock.withLock { continuation = c }
        }

        /// 空数据是 EOF：摘掉这一路的回调，免得 EOF 之后还反复被叫
        func append(_ chunk: Data, pipe: Int) {
            lock.withLock {
                if chunk.isEmpty {
                    closed[pipe] = true
                    handles[pipe].readabilityHandler = nil
                } else {
                    data[pipe] += chunk
                }
            }
            settle()
        }

        func exited(_ code: Int32) {
            lock.withLock { status = code }
            settle()
        }

        private func settle() {
            let result: Result<Data, Error>? = lock.withLock {
                guard let status, !closed.contains(false) else { return nil }
                if status == 0 { return .success(data[0]) }
                let last = String(decoding: data[1] + data[0], as: UTF8.self).split(whereSeparator: \.isNewline).last.map(String.init)
                return .failure(Failure(errorDescription: last ?? "退出码 \(status)"))
            }
            if let result { finish(result) }
        }

        func finish(_ result: Result<Data, Error>) {
            let c: CheckedContinuation<Data, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            guard let c else { return }
            handles.forEach { $0.readabilityHandler = nil }
            c.resume(with: result)
        }
    }
}
