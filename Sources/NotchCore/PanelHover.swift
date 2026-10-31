import Foundation

/// 回答：鼠标悬停把面板展开了没有——在刘海上停多久算要展开、离开多久算走了。
/// 纯状态机：喂鼠标落在哪、当前时间；不知道屏幕坐标、不起定时器（App 按 `deadline` 到点调 `tick`）。
/// 卡片压不压过面板、固定展开 / 收起不归这里管
public struct PanelHover: Sendable {
    /// 停这么久才展开：路过刘海不弹出来
    public static let openDelay: TimeInterval = 0.12
    /// 离开这么久才收起：划出形状边一下不至于收起
    public static let closeDelay: TimeInterval = 0.35

    private enum Phase: Equatable {
        case closed, opening(at: Date), open, closing(at: Date)
    }

    private var phase = Phase.closed

    public init() {}

    public var isOpen: Bool {
        switch phase {
        case .open, .closing: true
        case .closed, .opening: false
        }
    }

    /// 下一次要 `tick` 的时刻；nil 表示没有在等的
    public var deadline: Date? {
        switch phase {
        case .opening(let at), .closing(let at): at
        case .closed, .open: nil
        }
    }

    /// onNotch：在收起的形状（略放大的热区）上；nearShape：在展开的形状上（多留 10pt 余量）；
    /// canOpen：开着「悬停展开」、没固定展开 / 收起。点击展开的面板离开时照样收起，不看 canOpen
    public mutating func mouseMoved(onNotch: Bool, nearShape: Bool, canOpen: Bool, now: Date) {
        switch phase {
        case .open, .closing:
            if onNotch || nearShape {
                phase = .open
            } else if phase == .open {
                phase = .closing(at: now + Self.closeDelay)
            }
        case .closed, .opening:
            if !(canOpen && onNotch) {
                phase = .closed
            } else if phase == .closed {
                phase = .opening(at: now + Self.openDelay)
            }
        }
    }

    /// 点了刘海
    public mutating func open() { phase = .open }

    /// 打开设置、换固定方式、关掉悬停展开：立刻收起，等着的展开也作废
    public mutating func close() { phase = .closed }

    public mutating func tick(now: Date) {
        switch phase {
        case .opening(let at) where at <= now: phase = .open
        case .closing(let at) where at <= now: phase = .closed
        default: break
        }
    }
}
