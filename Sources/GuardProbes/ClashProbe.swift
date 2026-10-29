import Darwin

/// 回答：Clash 内核进程在不在。
/// 结果只决定 healthy 还是 unknown，不会触发拦截（规则见 `EgressGuard`）。
/// 按可执行文件名整名匹配，不按子串 grep：GUI（`clash-verge`）和特权服务（`clash-verge-service`）
/// 在、内核没起来时流量并不经过 Clash。
public enum ClashProbe {
    /// Haitao 用的 Clash Verge Rev 自带内核名（2026-10-28 实测）。换别的 Clash 再按实测加。
    static let coreNames: Set<String> = ["verge-mihomo"]

    /// 列不出进程表时返回 nil（未知），不当作「不在」。
    public static func current() -> Bool? {
        executablePaths().map(isRunning(executablePaths:))
    }

    static func isRunning(executablePaths: [String]) -> Bool {
        executablePaths.contains { coreNames.contains(String($0.split(separator: "/").last ?? "")) }
    }

    /// @see https://opensource.apple.com/source/xnu/xnu-7195.81.3/libsyscall/wrappers/libproc/libproc.h
    private static func executablePaths() -> [String]? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return pids.prefix(Int(count)).compactMap { pid in
            proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        }
    }
}
