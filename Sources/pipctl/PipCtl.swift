import Darwin
import Foundation
import PluginCore

/// 回答：外部插件怎么给刘海发一张卡、报一个活动（`plugin` 子命令见 `PluginCommand`）。`pipctl notify …`、`pipctl activity …` 校验后写进收件箱：先写 `tmp/<id>.json`，再 rename 到 `new/`（同一个文件系统里 rename 是原子的）。
/// 不等 App 读、不知道插件登没登记（App 判）。App 没启动过时收件箱不在，报错退出
@main
enum PipCtl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let activity: String?
        let rest: [String]
        switch args.first {
        case "notify"?:
            (activity, rest) = (nil, Array(args.dropFirst()))
        case "activity"? where args.count > 1:
            (activity, rest) = (args[1], Array(args.dropFirst(2)))
        case "send"? where args.count == 1:
            (activity, rest) = (nil, [])
        case "plugin"?:
            PluginCommand.run(Array(args.dropFirst()))
        default:
            fail(Notify.usage + "\n" + PluginCommand.usage, status: EX_USAGE)
        }
        let id = UUID()
        let data: Data
        do {
            if args.first == "send" {
                // 读到 maxBytes + 1 就够判超了，不把一个无尽的管道读完
                let input = FileHandle.standardInput.readData(ofLength: Message.maxBytes + 1)
                data = try Notify.send(input, id: id, now: Date())
            } else {
                data = try Notify.message(rest, id: id, now: Date(), activity: activity)
            }
        } catch {
            switch error {
            case .usage(let why): fail("pipctl：\(why)\n\(Notify.usage)", status: EX_USAGE)
            case .invalid(let error): fail("pipctl：消息不合规（\(error)）", status: EX_DATAERR)
            }
        }
        let name = id.uuidString + ".json"
        let tmp = PluginPaths.tmp.appendingPathComponent(name)
        do {
            try data.write(to: tmp)
        } catch {
            fail("pipctl：写不进收件箱（\(PluginPaths.tmp.path)），Pip 启动过吗？\(error.localizedDescription)", status: EX_CANTCREAT)
        }
        guard rename(tmp.path, PluginPaths.new.appendingPathComponent(name).path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp.path)
            fail("pipctl：放不进收件箱（\(why)）", status: EX_CANTCREAT)
        }
    }

    static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }
}
