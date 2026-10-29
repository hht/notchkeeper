import AppKit
import SwiftUI

/// 第一次点击即可响应（非激活面板里不用先点一下“激活”）
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PressableStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

enum Motion {
    static let page = Animation.spring(response: 0.42, dampingFraction: 0.84)
    static let notchOpen = Animation.spring(response: 0.5, dampingFraction: 0.7)
    static let notchClose = Animation.spring(response: 0.38, dampingFraction: 0.88)
}
