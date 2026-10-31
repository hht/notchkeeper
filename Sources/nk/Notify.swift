import Foundation
import PluginCore

/// 回答：`nk notify …` 的参数是哪张卡。拼成收件箱的 JSON，交给 `Message.parse` 校验：写得出来的 App 一定读得懂
enum Notify {
    static let usage = """
        用法：nk notify --plugin <id> --title <标题> [--subtitle <副标题>] [--value <右侧短值>]
                        [--outcome done|failed|attention|info] [--group <组>] [--fact <名>=<值>]... [--open <URL>]
        """

    static func message(_ args: [String], id: UUID, now: Date) throws(NotifyError) -> Data {
        var fields: [String: Any] = ["v": 1, "id": id.uuidString, "at": now.formatted(.iso8601)]
        var facts: [[String: String]] = []
        var rest = args[...]
        while let option = rest.popFirst() {
            guard let value = rest.popFirst() else { throw .usage("\(option) 后面缺值") }
            switch option {
            case "--plugin", "--title", "--subtitle", "--value", "--outcome", "--group":
                fields[String(option.dropFirst(2))] = value
            case "--fact":
                guard let eq = value.firstIndex(of: "=") else { throw .usage("--fact 要写成 名=值") }
                facts.append(["title": String(value[..<eq]), "value": String(value[value.index(after: eq)...])])
            case "--open":
                fields["action"] = ["type": "Action.OpenUrl", "url": value]
            default:
                throw .usage("不认识 \(option)")
            }
        }
        guard fields["plugin"] != nil, fields["title"] != nil else { throw .usage("--plugin 和 --title 必填") }
        if !facts.isEmpty { fields["block"] = ["type": "FactSet", "facts": facts] }
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
