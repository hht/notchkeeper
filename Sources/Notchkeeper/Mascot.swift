import SwiftUI

/// 吉祥物插槽：刘海、卡片和设置页里的吉祥物都从这里接入（AGENTS.md）。
protocol MascotRenderable: View {
    init(state: DundunState, size: CGFloat, emote: MascotEmote, interactive: Bool)
}

/// 出现时附带的表情
enum MascotEmote {
    case none
    /// 出现时开心一下（完成卡、恢复卡）
    case cheer
    /// 一直开心（设置页「关于」）
    case beaming
}

/// 当前使用的吉祥物实现
typealias Mascot = DundunCanvasView
