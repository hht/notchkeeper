import CoreGraphics

/// 收起、放卡片、展开面板
public enum NotchMode: Hashable, Sendable { case closed, card, dashboard }

/// 回答：刘海的三种形态各有多大、里面的东西离边多远。视图和悬停命中测试共用；不知道画什么、鼠标在哪
public enum NotchLayout {
    /// 刘海窗口：装得下最满的面板（`PanelShape.maxRows` 行分在最多 6 段里）和最满的卡片
    public static let windowSize = CGSize(width: 580, height: 440)
    /// 卡片内容离形状黑底左右边：卡上的 Pip 和面板左上的那只中心对齐，两边互切时 Pip 只上下走、不横移（HIG Live Activities：展开态之间元素保持相对位置）
    public static let cardPadding = contentInset + rowIcon / 2 - dashCorner / 2
    /// 第一行（Pip + 标题 + 副标题）的高度
    public static let cardRowHeight: CGFloat = 38
    public static let cardBottom: CGFloat = 16
    /// 展开面板和卡片的黑底宽 = iOS 灵动岛展开态宽 408（HIG Live Activities；Mac 菜单栏里的 Live Activity 用同一套尺寸）。
    /// 形状两侧还各有一截往外翻的顶角（`openFlare`），不算黑底
    public static let dashWidth: CGFloat = 408
    /// 展开（面板、卡片）时形状顶角往外翻的宽度（NotchShape 的 topRadius）
    public static let openFlare: CGFloat = 14
    /// 黑底四周边距 14（HIG Live Activities：Lock Screen 标准边距）
    public static let dashMargin: CGFloat = 14
    public static let listRadius: CGFloat = 14
    /// 展开（面板、卡片）时形状的底角；收起时 8
    public static let openBottomRadius: CGFloat = 28
    /// 会话容器四周留 4
    public static let listInset: CGFloat = 4
    public static let rowHeight: CGFloat = 38
    public static let rowPadding: CGFloat = 10
    public static let rowIcon: CGFloat = 24
    /// 行内容离黑底左右边：会话图标左缘、时间右缘、底栏文字左缘、齿轮右缘、右上徽章右缘都在这条线上（docs/ui.md「面板布局」）
    public static let contentInset = dashMargin + listInset + rowPadding
    /// 左上的 Pip 和右上的徽章：等大（HIG：leading / trailing 大小相近，左右平衡），和刘海下的标题 + IP 两行一样高；
    /// Pip 身体中心和会话图标中心在同一条竖线上。卡片上还是这只 Pip，也是这么大
    public static let dashCorner: CGFloat = 32
    /// Pip 和徽章上缘离面板顶 8：紧贴刘海两侧，不留「额头」
    public static let dashCornerTop: CGFloat = 8
    /// 刘海正下方的状态区（标题 + IP）的高度
    public static let dashStatusHeight: CGFloat = 42
    public static let footerHeight: CGFloat = 30
    /// 状态区和会话容器之间、底栏和面板底之间
    public static let listGap: CGFloat = 10
    public static let footerBottom: CGFloat = 4
    /// 面板里段与段之间
    public static let sectionGap: CGFloat = 6
    /// 小字（时间、底栏、空列表）的白色不透明度：≤17pt 的字对比度至少 4.5:1（HIG Accessibility）
    public static let secondaryTextOpacity = 0.5

    /// 收起时刘海两侧各一只耳朵：左耳放 Pip，右耳放状态指示（docs/mascot.md §1）
    public static let earWidth: CGFloat = 44
    /// 收起时形状顶角往外翻的宽度（NotchShape 的 topRadius）
    public static let closedFlare: CGFloat = 4
    /// 左耳 Pip 的身体直径（docs/mascot.md §1）：面板里那只缩到这么大
    public static let earMascotSize: CGFloat = 20
    /// 左耳 Pip 的身体中心、右耳指示的中心离形状外缘多远：都在耳朵看得见的部分（去掉外翻）里居中，左右对称
    /// （docs/mascot.md §1；HIG Live Activities compact：左右平衡、紧贴摄像头）
    public static let earCenterInset = closedFlare + (earWidth - closedFlare) / 2

    /// 没有刘海的屏幕（高度 0）不长耳朵，保持原来从顶端中间长出来的样子
    public static func hasEars(_ notch: CGSize) -> Bool { notch.height > 0 }

    public static func topInset(_ notch: CGSize) -> CGFloat { max(notch.height, 24) }
    /// 面板内容从刘海下沿起；没有刘海的屏幕按 32 留出菜单栏
    public static func dashTop(_ notch: CGSize) -> CGFloat { max(notch.height, 32) }
    /// 卡片内容的上沿
    public static func cardTop(_ notch: CGSize) -> CGFloat { topInset(notch) - 2 }

    /// cardContent：卡片内容量出来的高度（第一行 + 内容块），形状跟着它用弹簧长。
    /// ears：收起时长不长耳朵（没有刘海的屏幕本来就不长；左耳不画 Pip、右耳也没东西时不长，就是一块纯黑的刘海）
    public static func size(_ mode: NotchMode, notch: CGSize, panel: PanelShape, cardContent: CGFloat, ears: Bool) -> CGSize {
        switch mode {
        case .closed:
            return hasEars(notch) && ears ? CGSize(width: notch.width + 2 * earWidth, height: notch.height) : notch
        case .card: return CGSize(width: dashWidth + 2 * openFlare, height: cardTop(notch) + cardContent + cardBottom)
        case .dashboard:
            let list: CGFloat = switch panel.list {
            case nil: 0
            case []?: listGap + rowHeight + 2 * listInset
            case let sections?: listGap + sections.map { CGFloat($0.rows) * rowHeight + 2 * listInset }.reduce(0, +)
                + CGFloat(sections.count - 1) * sectionGap
            }
            return CGSize(width: dashWidth + 2 * openFlare,
                          height: dashTop(notch) + (panel.header ? dashStatusHeight : 0) + list + footerHeight + footerBottom)
        }
    }
}

/// 面板长什么样：顶上有没有出口守卫的状态区，下面各段露几行（docs/ui.md「面板布局」）。视图和悬停命中测试共用
public struct PanelShape: Equatable, Sendable {
    public struct Visible: Equatable, Sendable {
        public var plugin: String
        public var rows: Int

        public init(plugin: String, rows: Int) {
            self.plugin = plugin
            self.rows = rows
        }
    }

    public var header: Bool
    /// nil：没有列表（只开了出口守卫）；空：一行占位（段都空着，或一个插件都没开）
    public var list: [Visible]?

    /// 各段合起来至多露这么多行：排在前面的段先拿，拿不到的不画（面板再高就挡住半个屏幕了）
    public static let maxRows = 6

    public init(header: Bool, list: [Visible]?) {
        self.header = header
        self.list = list
    }

    /// sections：开着的段，按顺序
    public init(guardEnabled: Bool, sections: [PanelSection]) {
        header = guardEnabled
        guard !sections.isEmpty else {
            list = guardEnabled ? nil : []
            return
        }
        var left = Self.maxRows
        var visible: [Visible] = []
        for s in sections {
            let n = min(s.rows.count, s.maxRows, left)
            guard n > 0 else { continue }
            visible.append(Visible(plugin: s.plugin, rows: n))
            left -= n
        }
        list = visible
    }
}
