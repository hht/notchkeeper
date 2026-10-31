import AgentCore
import Foundation

/// 回答：面板里插件那一段的一行画什么——图标、标题、可选副标题、状态指示、右侧「距今多久」或短值、点了去哪（docs/ui.md「面板布局」）。
/// 内容由插件定（Claude 会话、外部插件的活动），版式由 App 定；不知道颜色和文案。只放路径、状态和时间，不放对话内容
public struct PanelRow: Identifiable, Equatable, Sendable {
    public enum Icon: Equatable, Sendable {
        /// Claude 的厂商标志
        case claude
        /// SF Symbol 名
        case symbol(String)
    }

    /// 不写字，只用指示（用户 10-29）；文案留给悬停提示和旁白
    public enum Indicator: Equatable, Sendable {
        case none, working, question, approval, attention
        case progress(Double)
    }

    public enum Trailing: Equatable, Sendable {
        /// 状态变化距今多久
        case since(Date)
        case value(String)
    }

    public var id: String
    public var icon: Icon
    public var title: String
    /// 标题是路径：太长从前面截，留住最后几段（用户 10-29）
    public var titleIsPath = false
    public var subtitle: String?
    public var indicator: Indicator
    public var trailing: Trailing
    /// 已停止的会话：图标和标题变暗，时间不暗（保住对比度）
    public var dimmed = false
    public var action: Card.Action?

    public init(id: String, icon: Icon, title: String, titleIsPath: Bool = false, subtitle: String? = nil, indicator: Indicator,
                trailing: Trailing, dimmed: Bool = false, action: Card.Action? = nil) {
        self.id = id
        self.icon = icon
        self.title = title
        self.titleIsPath = titleIsPath
        self.subtitle = subtitle
        self.indicator = indicator
        self.trailing = trailing
        self.dimmed = dimmed
        self.action = action
    }

    /// Claude 会话：路径 + 状态指示 + 状态变化距今；点了跳回它的终端。不显示会话名（它可能从对话推出来）
    public init(_ session: Session) {
        let indicator: Indicator = switch session.state {
        case .working: .working
        case .needsYou(.question): .question
        case .needsYou(.approval): .approval
        case .stopped: .none
        }
        self.init(id: "claude:\(session.pid)", icon: .claude, title: (session.cwd as NSString).abbreviatingWithTildeInPath, titleIsPath: true,
                  indicator: indicator, trailing: .since(session.stateSince), dimmed: session.state == .stopped,
                  action: .terminal(TerminalRef(session)))
    }
}

extension TerminalRef {
    public init(_ session: Session) { self.init(pid: session.pid, identity: .started(session.processStart), cwd: session.cwd) }
}

/// 面板里一个插件的那一段（docs/ui.md「面板布局」）
public struct PanelSection: Identifiable, Equatable, Sendable {
    public var plugin: String
    public var rows: [PanelRow]
    /// 最多露几行，多的在段里滚
    public var maxRows: Int
    public var id: String { plugin }

    public init(plugin: String, rows: [PanelRow], maxRows: Int) {
        self.plugin = plugin
        self.rows = rows
        self.maxRows = maxRows
    }
}
