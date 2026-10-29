import MascotCore

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

extension Look {
    /// 「状态测试」里的名字（docs/mascot.md §2）
    var title: String {
        switch self {
        case .idle: return "空闲"
        case .sleeping: return "睡着"
        case .thinking: return "思考"
        case .working: return "工作"
        case .longTurn: return "干了很久"
        case .question: return "等你回答"
        case .approval: return "等你批准"
        case .finished: return "完成"
        case .error: return "出错"
        case .interrupted: return "被打断"
        case .dizzy: return "晕"
        case .offline: return "断网"
        case .mismatch: return "出口不符"
        case .stale: return "守卫没响应"
        case .danger: return "危险"
        case .shielded: return "防火墙守住"
        }
    }
}
