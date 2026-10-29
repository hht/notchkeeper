import Foundation

/// 回答：怎么把状态写到磁盘，让读的一方永远只看到完整的一份。
/// 同目录临时文件 + `rename(2)`：同一文件系统上 rename 是原子的，App 不会读到写了一半的 JSON。
/// 临时文件用 `O_CREAT | O_EXCL` 以 0600 新建，从第一个字节起就只有本人可读，不靠事后 chmod。
/// @see https://keith.github.io/xcode-man-pages/rename.2.html
enum StateFile {
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        unlink(tmp.path) // 上次崩在半路留下的同名临时文件；不存在时失败无妨
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw posixError() }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(tmp.path, url.path) == 0 else { throw posixError() }
        } catch {
            unlink(tmp.path)
            throw error
        }
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
