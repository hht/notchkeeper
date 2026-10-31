import Foundation
import NotchCore

/// 回答：收件箱里的一份文件说了什么——哪个插件、哪张卡、同哪组替换、什么时候过期。
/// 只解析 v1 消息（只有卡片）；不读文件，不知道插件登没登记、限没限流（`InboxGate`）。
/// 内容块和动作照 Adaptive Cards 起名（TextBlock、FactSet、Action.OpenUrl，按钮是带 title 的动作），进度、勾叉列表、activate、focusTerminal 是扩展。
/// @see https://github.com/microsoft/AdaptiveCards/tree/main/schemas/src
public struct Message: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case open(URL)
        case activate(bundleID: String)
        /// 跳回这个终端：tty 是 `/dev/ttys` 加数字，pid 是用它的进程（shell）
        case focusTerminal(tty: String, pid: Int32, cwd: String)
    }

    public struct Button: Equatable, Sendable {
        public var title: String
        public var action: Action
    }

    /// 活动的哪一步（照 ActivityKit 的 start / update / end）。活动在面板里插件那一段占一行，`alert` 时弹卡、之后的更新原地刷新它
    /// @see https://developer.apple.com/documentation/activitykit/activity
    public struct Activity: Equatable, Sendable {
        public enum Event: Equatable, Sendable { case start, update, end }
        /// 插件自己起的名字，同一个插件里认同一个活动
        public var id: String
        public var event: Event
        public var alert: Bool
    }

    public var plugin: String
    public var id: UUID
    public var at: Date
    /// 同一个插件里同组的卡只留最新
    public var group: String?
    public var title: String
    public var subtitle: String?
    public var value: String?
    /// 只有 done、failed、attention、info：红色、绿色属于出口守卫
    public var outcome: Card.Outcome
    public var block: Card.Block?
    public var action: Action?
    public var buttons: [Button]
    /// 过了这个时刻还没放就不放；活动是这一行留到什么时候
    public var staleAt: Date?
    /// nil：这是一张普通卡，不是活动
    public var activity: Activity?

    public static func parse(_ data: Data) throws(MessageError) -> Message {
        let wire: Wire
        do {
            wire = try decoder.decode(Wire.self, from: data)
        } catch {
            throw .malformed
        }
        return try Message(wire)
    }

    /// 插件 id 会拼进 `plugins/<id>/manifest.json`：小写字母或数字开头，只有小写字母、数字和连字符，至多 32 个字符
    static func isPluginID(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, s.unicodeScalars.count <= 32, first != "-" else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// 脚本常用 `date -u +%FT%TZ`，JS 的 `toISOString()` 带毫秒：10-31 实测 macOS 26.5 上 `.iso8601` 两种都认（测试覆盖）
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// 在 extension 里：保留编译器合成的逐成员 init（测试用）
extension Message {
    private init(_ wire: Wire) throws(MessageError) {
        guard wire.v == 1 else { throw .unsupportedVersion }
        guard Self.isPluginID(wire.plugin) else { throw .badPluginID }
        guard !wire.title.allSatisfy(\.isWhitespace) else { throw .missingTitle }
        plugin = wire.plugin
        id = wire.id
        at = wire.at
        group = wire.group
        title = wire.title
        subtitle = wire.subtitle
        value = wire.value
        switch wire.outcome ?? "info" {
        case "done": outcome = .done
        case "failed": outcome = .failed
        case "attention": outcome = .attention
        case "info": outcome = .info
        default: throw .unknownOutcome
        }
        block = try wire.block.map(Self.block)
        action = try wire.action.map(Self.action)
        buttons = try (wire.buttons ?? []).map { a throws(MessageError) in
            guard let title = a.title, !title.allSatisfy(\.isWhitespace) else { throw .badAction }
            return Button(title: title, action: try Self.action(a))
        }
        staleAt = wire.staleAt
        activity = try wire.activity.map { a throws(MessageError) in
            guard !a.id.isEmpty, a.id.count <= 64 else { throw .badActivity }
            let event: Activity.Event
            switch a.event {
            case "start": event = .start
            case "update": event = .update
            case "end": event = .end
            default: throw .badActivity
            }
            return Activity(id: a.id, event: event, alert: a.alert ?? false)
        }
    }

    private static func block(_ b: Wire.Block) throws(MessageError) -> Card.Block {
        switch b.type {
        case "TextBlock":
            guard let text = b.text else { throw .badBlock }
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            switch b.fontType?.lowercased() {
            case nil, "default": return .text(lines)
            case "monospace": return .log(lines)
            default: throw .badBlock
            }
        case "FactSet":
            guard let facts = b.facts else { throw .badBlock }
            return .facts(facts.map { Card.Fact(title: $0.title, value: $0.value) })
        case "checklist":
            guard let items = b.items else { throw .badBlock }
            return .checklist(try items.map { item throws(MessageError) in
                switch item.state {
                case "ok": return Card.Check(text: item.text, state: .ok)
                case "failed": return Card.Check(text: item.text, state: .failed)
                case "pending": return Card.Check(text: item.text, state: .pending)
                default: throw .badBlock
                }
            })
        case "progress":
            guard let value = b.value else { throw .badBlock }
            return .progress(value, label: b.label)
        default:
            throw .badBlock
        }
    }

    private static func action(_ a: Wire.Action) throws(MessageError) -> Action {
        switch a.type {
        case "Action.OpenUrl":
            guard let url = a.url.flatMap(URL.init(string:)), url.scheme != nil else { throw .badAction }
            return .open(url)
        case "activate":
            guard let id = a.bundleID, !id.isEmpty else { throw .badAction }
            return .activate(bundleID: id)
        case "focusTerminal":
            // tty 会被打开来写标记：只认 macOS 伪终端的名字，拼不出别的路径
            guard let tty = a.tty, tty.hasPrefix("/dev/ttys"), tty.count > 9, tty.dropFirst(9).allSatisfy({ $0.isASCII && $0.isNumber }),
                  let pid = a.pid, pid > 1, let cwd = a.cwd else { throw .badAction }
            return .focusTerminal(tty: tty, pid: pid, cwd: cwd)
        default:
            throw .badAction
        }
    }
}

/// 消息解不开的原因：App 计数、删掉文件。不带消息里的原文（外部来源，可能很长，也可能是伪造的日志行）
public enum MessageError: Error, Equatable, Sendable {
    /// 不是 JSON、缺必填字段或类型不对
    case malformed
    case unsupportedVersion
    case badPluginID
    case missingTitle
    /// 外部插件只能用 done、failed、attention、info
    case unknownOutcome
    /// 内容块类型不认识或缺字段
    case badBlock
    /// 动作类型不认识、缺字段，或按钮没有标题
    case badAction
    /// 活动的 id 是空的或太长，或 event 不认识
    case badActivity
}

/// 收件箱文件的 JSON 格式（`nk` 拼的也是它）。缺字段、类型不对在这里就解不开
private struct Wire: Decodable {
    var v: Int
    var plugin: String
    var id: UUID
    var at: Date
    var group: String?
    var title: String
    var subtitle: String?
    var value: String?
    /// 缺省是 info
    var outcome: String?
    var block: Block?
    var action: Action?
    var buttons: [Action]?
    var staleAt: Date?
    var activity: Activity?

    struct Activity: Decodable {
        var id: String
        /// start、update、end
        var event: String
        var alert: Bool?
    }

    /// `type` 是 TextBlock、FactSet、checklist、progress，各用各的字段
    struct Block: Decodable {
        var type: String
        var text: String?
        var fontType: String?
        var facts: [Fact]?
        var items: [Item]?
        var value: Double?
        var label: String?

        struct Fact: Decodable {
            var title: String
            var value: String
        }

        struct Item: Decodable {
            var text: String
            /// ok、failed、pending
            var state: String
        }
    }

    /// `type` 是 Action.OpenUrl（`url`）、activate（`bundleID`）或 focusTerminal（`tty`、`pid`、`cwd`）；做按钮时要有 `title`
    struct Action: Decodable {
        var type: String
        var title: String?
        var url: String?
        var bundleID: String?
        var tty: String?
        var pid: Int32?
        var cwd: String?
    }
}
