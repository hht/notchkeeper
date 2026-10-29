import AppKit
import Darwin

/// 同一用户只留一个刘海实例：第二个在创建 NSApplication、画任何东西之前就退出。
/// 两道关，各补对方的缺口：
/// 1. 每用户一把 flock 排他锁（man 2 flock）。由内核仲裁，同时启动也只有一个拿到；进程退出或崩溃时内核自动释放，
///    不会留下要人清理的死锁文件。锁文件在每用户私有目录（confstr _CS_DARWIN_USER_DIR，0700），
///    不跟 HOME / CFFIXED_USER_HOME 走，所以换了 HOME 的测试实例和正式实例抢的是同一把锁。
/// 2. 扫正在运行的 App：同一用户、可执行文件叫 Notchkeeper、不是 prohibited（会画界面）的，谁先启动谁留下。
///    这一关拦住不拿锁的旧版本（比如正在跑的上一版）和别的 bundle id 的副本。
///    自检、演示这类无界面进程是未打包的可执行文件，激活策略默认 prohibited，不算数，也不拿锁。
/// 不用 Info.plist 的 LSMultipleInstancesProhibited：它管的是「多个用户同时启动」，不是同一用户的第二个实例；
/// 也不只按 bundle id 查：测试副本和直接运行的二进制 bundle id 不同或没有。
/// @see https://developer.apple.com/documentation/bundleresources/information-property-list/lsmultipleinstancesprohibited
/// @see https://developer.apple.com/documentation/appkit/nsrunningapplication/runningapplications(withbundleidentifier:)
/// @see https://developer.apple.com/documentation/appkit/nsworkspace/runningapplications
/// @see https://developer.apple.com/documentation/appkit/nsrunningapplication/executableurl
/// @see https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/prohibited
@MainActor
enum SingleInstance {
    struct Instance: Equatable {
        let pid: pid_t
        /// 进程启动时刻（秒，内核记录）
        let start: Double
    }

    enum LockResult: Equatable {
        case acquired(Int32)
        case heldByOther
        case unavailable
    }

    static let lockURL: URL? = {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf), isDirectory: true).appendingPathComponent("local.hht.notchkeeper.lock")
    }()

    /// 拿到的锁一直开着，进程结束时由内核释放
    private static var heldLock: Int32?

    /// 正式启动时最先调用；false 表示已有实例，应立刻退出
    static func claim() -> Bool {
        switch lockURL.map(lock(at:)) ?? .unavailable {
        case .acquired(let fd): heldLock = fd
        case .heldByOther:
            Log.write("已有 Notchkeeper 持有单实例锁，本实例退出")
            return false
        case .unavailable:
            Log.write("单实例锁不可用，只按运行中的 App 判断")
        }
        guard let me = instance(getpid()) else { return true }
        if let older = olderInstance(than: me, among: runningGUIInstances()) {
            Log.write("已有 Notchkeeper 在运行（pid \(older.pid)），本实例退出")
            return false
        }
        return true
    }

    static func lock(at url: URL) -> LockResult {
        // O_CLOEXEC：子进程不继承这把锁，App 退出后不会被它启动的进程拖着不放
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .unavailable }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return .acquired(fd) }
        let busy = errno == EWOULDBLOCK
        close(fd)
        return busy ? .heldByOther : .unavailable
    }

    /// 比 me 先启动的那个（同一时刻按 pid 小的先）；没有就是 nil
    static func olderInstance(than me: Instance, among others: [Instance]) -> Instance? {
        others.filter { $0.pid != me.pid && ($0.start, $0.pid) < (me.start, me.pid) }.min { ($0.start, $0.pid) < ($1.start, $1.pid) }
    }

    static func runningGUIInstances() -> [Instance] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && $0.executableURL?.lastPathComponent == "Notchkeeper" }
            .compactMap { instance($0.processIdentifier) }
    }

    /// 同一用户、还活着的进程才返回；已退出等回收的（僵尸）不算，run.sh 刚 pkill 掉的旧实例不会挡住新实例
    static func instance(_ pid: pid_t) -> Instance? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        return Instance(pid: pid, start: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
}
