import Darwin
import Foundation
import PluginCore

/// 回答：外部插件怎么给刘海发一张卡。`nk notify …` 校验后写进收件箱：先写 `tmp/<id>.json`，再 rename 到 `new/`（同一个文件系统里 rename 是原子的）。
/// 不等 App 读、不知道插件登没登记（App 判）。App 没启动过时收件箱不在，报错退出
@main
enum NK {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        guard args.first == "notify" else { fail(Notify.usage, status: EX_USAGE) }
        let id = UUID()
        let data: Data
        do {
            data = try Notify.message(Array(args.dropFirst()), id: id, now: Date())
        } catch {
            switch error {
            case .usage(let why): fail("nk：\(why)\n\(Notify.usage)", status: EX_USAGE)
            case .invalid(let error): fail("nk：消息不合规（\(error)）", status: EX_DATAERR)
            }
        }
        let name = id.uuidString + ".json"
        let tmp = PluginPaths.tmp.appendingPathComponent(name)
        do {
            try data.write(to: tmp)
        } catch {
            fail("nk：写不进收件箱（\(PluginPaths.tmp.path)），Notchkeeper 启动过吗？\(error.localizedDescription)", status: EX_CANTCREAT)
        }
        guard rename(tmp.path, PluginPaths.new.appendingPathComponent(name).path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp.path)
            fail("nk：放不进收件箱（\(why)）", status: EX_CANTCREAT)
        }
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }
}
