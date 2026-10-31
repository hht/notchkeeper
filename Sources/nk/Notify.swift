import Foundation
import PluginCore

/// 回答：`nk notify …`、`nk activity …` 的参数是哪张卡、哪个活动的哪一步。拼成收件箱的 JSON，交给 `Message.parse` 校验：写得出来的 App 一定读得懂
enum Notify {
    static let usage = """
        用法：nk notify --plugin <id> --title <标题> [--subtitle <副标题>] [--value <右侧短值>]
                        [--outcome done|failed|attention|info] [--group <组>] [--fact <名>=<值>]... [--progress <0…1> [--label <说明>]]
                        [--open <URL> | --tty <tty> --pid <pid> --cwd <目录>]
              nk activity start|update|end --id <活动> [--alert] 加上 notify 除 --group 外的参数（--title 每一步都要，end 写结局）
                        活动在面板里插件那一段占一行，end 撤掉；--alert 时弹卡，之后的更新原地刷新这张卡
        """

    /// activity：start、update、end；nil 是一张普通卡
    static func message(_ args: [String], id: UUID, now: Date, activity: String? = nil) throws(NotifyError) -> Data {
        // 带毫秒：脚本一秒里连发 start、end，App 才分得清先后
        var fields: [String: Any] = ["v": 1, "id": id.uuidString, "at": Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(now)]
        var facts: [[String: String]] = []
        var progress: [String: Any] = [:]
        var terminal: [String: Any] = [:]
        var activityFields: [String: Any] = [:]
        if let activity { activityFields["event"] = activity }
        var rest = args[...]
        while let option = rest.popFirst() {
            if option == "--alert" {
                guard activity != nil else { throw .usage("--alert 只用在 nk activity") }
                activityFields["alert"] = true
                continue
            }
            guard let value = rest.popFirst() else { throw .usage("\(option) 后面缺值") }
            switch option {
            case "--id":
                guard activity != nil else { throw .usage("--id 只用在 nk activity") }
                activityFields["id"] = value
            case "--progress":
                guard let p = Double(value) else { throw .usage("--progress 要是 0 到 1 的数") }
                progress["value"] = p
            case "--label":
                progress["label"] = value
            case "--plugin", "--title", "--subtitle", "--value", "--outcome", "--group":
                fields[String(option.dropFirst(2))] = value
            case "--fact":
                guard let eq = value.firstIndex(of: "=") else { throw .usage("--fact 要写成 名=值") }
                facts.append(["title": String(value[..<eq]), "value": String(value[value.index(after: eq)...])])
            case "--open":
                fields["action"] = ["type": "Action.OpenUrl", "url": value]
            case "--tty", "--cwd":
                terminal[String(option.dropFirst(2))] = value
            case "--pid":
                guard let pid = Int32(value) else { throw .usage("--pid 要是数字") }
                terminal["pid"] = pid
            default:
                throw .usage("不认识 \(option)")
            }
        }
        guard fields["plugin"] != nil, fields["title"] != nil else { throw .usage("--plugin 和 --title 必填") }
        if !terminal.isEmpty {
            guard terminal.count == 3 else { throw .usage("--tty、--pid、--cwd 要一起给") }
            guard fields["action"] == nil else { throw .usage("--open 和跳回终端只能选一个") }
            fields["action"] = terminal.merging(["type": "focusTerminal"]) { a, _ in a }
        }
        if activity != nil {
            guard activityFields["id"] != nil else { throw .usage("nk activity 要 --id") }
            // 活动的卡按活动认，组用不上
            guard fields["group"] == nil else { throw .usage("--group 只用在 nk notify") }
            fields["activity"] = activityFields
        }
        guard facts.isEmpty || progress.isEmpty else { throw .usage("--fact 和 --progress 只能选一个：一张卡至多一个内容块") }
        if !facts.isEmpty { fields["block"] = ["type": "FactSet", "facts": facts] }
        if !progress.isEmpty {
            guard progress["value"] != nil else { throw .usage("--label 要和 --progress 一起给") }
            fields["block"] = progress.merging(["type": "progress"]) { a, _ in a }
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            preconditionFailure("拼的只有字符串、数字和它们的数组字典")
        }
        do {
            _ = try Message.parse(data)
        } catch {
            throw .invalid(error)
        }
        return data
    }
}

enum NotifyError: Error {
    case usage(String)
    case invalid(MessageError)
}
