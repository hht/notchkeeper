import Foundation
import NotchCore
import PluginCore

/// 回答：`pipctl notify …`、`pipctl activity …` 的参数、`pipctl send` 读进来的 JSON 是哪张卡、哪个活动的哪一步。
/// 拼成收件箱的 JSON，交给 `Message.parse` 校验：写得出来的 App 一定读得懂
enum Notify {
    static let usage = """
        用法：pipctl notify --plugin <id> --title <标题> [--subtitle <副标题>] [--value <右侧短值>]
                            [--outcome done|failed|attention|info] [--group <组>] [--stale <秒>]
                            [--fact <名>=<值>... | --check ok|failed|pending=<文字>... | --text <文字> | --log <文字> | --progress <0…1> [--label <说明>]]
                            [--open <URL> | --activate <bundle ID> | --tty <tty> --pid <pid> --cwd <目录>] [--button <标题>=<URL>]...
              pipctl activity start|update|end --id <活动> [--alert] 加上 notify 除 --group 外的参数（--title 每一步都要，end 写结局）
                            活动在面板里插件那一段占一行，end 撤掉；--alert 时弹卡，之后的更新原地刷新这张卡
              pipctl send < 消息.json   标准输入里一整份消息（格式见用户文档），缺 v、id、at 就补上
        """

    /// activity：start、update、end；nil 是一张普通卡
    static func message(_ args: [String], id: UUID, now: Date, activity: String? = nil) throws(NotifyError) -> Data {
        var fields = envelope(id: id, now: now)
        var blocks: [[String: Any]] = []
        var facts: [[String: String]] = []
        var checks: [[String: String]] = []
        var progress: [String: Any] = [:]
        var terminal: [String: Any] = [:]
        var actions: [[String: Any]] = []
        var buttons: [[String: Any]] = []
        var activityFields: [String: Any] = [:]
        if let activity { activityFields["event"] = activity }
        var rest = args[...]
        while let option = rest.popFirst() {
            if option == "--alert" {
                guard activity != nil else { throw .usage("--alert 只用在 pipctl activity") }
                activityFields["alert"] = true
                continue
            }
            guard let value = rest.popFirst() else { throw .usage("\(option) 后面缺值") }
            switch option {
            case "--id":
                guard activity != nil else { throw .usage("--id 只用在 pipctl activity") }
                activityFields["id"] = value
            case "--progress":
                guard let p = Double(value), p.isFinite else { throw .usage("--progress 要是 0 到 1 的数") }
                progress["value"] = p
            case "--label":
                progress["label"] = value
            case "--plugin", "--title", "--subtitle", "--value", "--outcome", "--group":
                fields[String(option.dropFirst(2))] = value
            case "--stale":
                guard let seconds = TimeInterval(value), seconds > 0 else { throw .usage("--stale 要是大于 0 的秒数") }
                fields["staleAt"] = timestamp(now.addingTimeInterval(seconds))
            case "--fact":
                let (name, rest) = try split(value, option)
                facts.append(["title": name, "value": rest])
            case "--check":
                // 状态在前：文字里可能有等号
                let (state, text) = try split(value, option)
                checks.append(["state": state, "text": text])
            case "--text", "--log":
                blocks.append(["type": "TextBlock", "text": value, "fontType": option == "--log" ? "monospace" : "default"])
            case "--open":
                actions.append(["type": "Action.OpenUrl", "url": value])
            case "--activate":
                actions.append(["type": "activate", "bundleID": value])
            case "--button":
                // 标题在前：URL 里常有等号
                let (title, url) = try split(value, option)
                buttons.append(["type": "Action.OpenUrl", "title": title, "url": url])
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
            actions.append(terminal.merging(["type": "focusTerminal"]) { a, _ in a })
        }
        guard actions.count <= 1 else { throw .usage("--open、--activate 和跳回终端只能选一个") }
        fields["action"] = actions.first
        guard buttons.count <= Card.maxButtons else { throw .usage("--button 至多 \(Card.maxButtons) 个") }
        if !buttons.isEmpty { fields["buttons"] = buttons }
        if activity != nil {
            guard activityFields["id"] != nil else { throw .usage("pipctl activity 要 --id") }
            // 活动的卡按活动认，组用不上
            guard fields["group"] == nil else { throw .usage("--group 只用在 pipctl notify") }
            fields["activity"] = activityFields
        }
        if !facts.isEmpty { blocks.append(["type": "FactSet", "facts": facts]) }
        if !checks.isEmpty { blocks.append(["type": "checklist", "items": checks]) }
        if !progress.isEmpty {
            guard progress["value"] != nil else { throw .usage("--label 要和 --progress 一起给") }
            blocks.append(progress.merging(["type": "progress"]) { a, _ in a })
        }
        guard blocks.count <= 1 else { throw .usage("--fact、--check、--text、--log、--progress 只能选一种：一张卡至多一个内容块") }
        fields["block"] = blocks.first
        return try validated(fields)
    }

    /// `pipctl send`：一整份消息。只补 `v`、`id`、`at`，别的字段原样交给 `Message.parse`
    static func send(_ input: Data, id: UUID, now: Date) throws(NotifyError) -> Data {
        guard input.count <= Message.maxBytes else { throw .usage("消息超过 \(Message.maxBytes / 1024) KB") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: input)
        } catch {
            throw .invalid(.malformed)
        }
        guard let fields = object as? [String: Any] else { throw .invalid(.malformed) }
        return try validated(envelope(id: id, now: now).merging(fields) { _, given in given })
    }

    private static func envelope(id: UUID, now: Date) -> [String: Any] {
        ["v": 1, "id": id.uuidString, "at": timestamp(now)]
    }

    /// 带毫秒：脚本一秒里连发 start、end，App 才分得清先后
    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    /// `名=值` 从第一个等号切开，两边都不能空
    private static func split(_ value: String, _ option: String) throws(NotifyError) -> (String, String) {
        guard let eq = value.firstIndex(of: "="), eq != value.startIndex else { throw .usage("\(option) 要写成 名=值") }
        return (String(value[..<eq]), String(value[value.index(after: eq)...]))
    }

    private static func validated(_ fields: [String: Any]) throws(NotifyError) -> Data {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            preconditionFailure("拼的和读进来的都是 JSON 值")
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
