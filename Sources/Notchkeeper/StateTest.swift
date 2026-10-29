import Foundation

// 设置里的「状态测试」：强制盾盾显示某个状态、把刘海固定展开或收起，方便看效果。
// 只在内存里：不写 config.json、不写 guard-state.json、不碰 guardd，重开 App 就回到真实状态。
// 存放和改动在 Notch.swift 的 NotchOverrides / NotchController，这里只是两张表。

/// 刘海固定在哪：自动（跟悬停走）、固定展开、固定收起。只压过悬停，卡片照常弹出，测试时也不会挡住真的红卡
enum NotchPin: String, CaseIterable, Identifiable {
    case auto, open, closed
    var id: Self { self }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .open: return "固定展开"
        case .closed: return "固定收起"
        }
    }
}

/// 可以强制显示的 12 个状态，各自对应现有的 DundunState
enum DundunTestState: String, CaseIterable, Identifiable {
    case idle, sleeping, thinking, working, waiting, done, error, interrupted, dizzy
    case warningMismatch = "warning-mismatch", warningStale = "warning-stale", danger
    var id: Self { self }

    var dundun: DundunState {
        switch self {
        case .idle: return .idle
        case .sleeping: return .sleeping
        case .thinking: return .thinking
        case .working: return .working
        case .waiting: return .question
        case .done: return .finished
        case .error: return .error
        case .interrupted: return .interrupted
        case .dizzy: return .dizzy
        case .warningMismatch: return .guardMismatch
        case .warningStale: return .guardStale
        case .danger: return .guardViolated
        }
    }

    var title: String {
        switch self {
        case .idle: return "空闲"
        case .sleeping: return "睡着"
        case .thinking: return "思考中"
        case .working: return "工作中"
        case .waiting: return "等你回复"
        case .done: return "完成"
        case .error: return "出错"
        case .interrupted: return "已中断"
        case .dizzy: return "晕了"
        case .warningMismatch: return "警告：出口不一致"
        case .warningStale: return "警告：守卫没有响应"
        case .danger: return "危险：出口不合规"
        }
    }
}
