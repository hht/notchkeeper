import Darwin
import Foundation

/// 同一用户只留一个刘海实例：第二个在创建 NSApplication、画任何东西之前就退出。
/// 每用户一把 flock 排他锁（man 2 flock）：由内核仲裁，同时启动也只有一个拿到；进程退出或崩溃时内核自动释放，
/// 不会留下要人清理的死锁文件。锁文件在每用户私有目录（confstr _CS_DARWIN_USER_DIR，0700）。
/// 不用 Info.plist 的 LSMultipleInstancesProhibited：它管的是「多个用户同时启动」，不是同一用户的第二个实例。
/// @see https://developer.apple.com/documentation/bundleresources/information-property-list/lsmultipleinstancesprohibited
@MainActor
enum SingleInstance {
    /// 拿到的锁一直开着，进程结束时由内核释放
    private static var heldLock: Int32?

    /// 正式启动时最先调用；false 表示已有实例，应立刻退出。锁不可用（目录拿不到、打不开）时照常启动，只记一行。
    static func claim() -> Bool {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buf, buf.count) > 0 else {
            Log.write("单实例锁不可用：拿不到每用户私有目录")
            return true
        }
        let url = URL(fileURLWithPath: String(cString: buf), isDirectory: true).appendingPathComponent("local.hht.notchkeeper.lock")
        // O_CLOEXEC：子进程不继承这把锁，App 退出后不会被它启动的进程拖着不放
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            Log.write("单实例锁不可用：\(String(cString: strerror(errno)))")
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            heldLock = fd
            return true
        }
        let err = errno
        close(fd)
        guard err == EWOULDBLOCK else {
            Log.write("单实例锁不可用：\(String(cString: strerror(err)))")
            return true
        }
        Log.write("已有 Notchkeeper 持有单实例锁，本实例退出")
        return false
    }
}
