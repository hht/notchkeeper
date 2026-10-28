import AppKit
import SwiftUI

/// 第一次点击即可响应（非激活面板里不用先点一下“激活”）
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 12
    var base: Double = 0.06
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hover ? base + 0.05 : base))
            )
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

extension View {
    func hoverCard(_ radius: CGFloat = 12, base: Double = 0.06) -> some View {
        modifier(HoverHighlight(cornerRadius: radius, base: base))
    }
}

enum Motion {
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let close = Animation.spring(response: 0.28, dampingFraction: 0.9)
    static let page = Animation.spring(response: 0.42, dampingFraction: 0.84)
    static let notchOpen = Animation.spring(response: 0.5, dampingFraction: 0.7)
    static let notchClose = Animation.spring(response: 0.38, dampingFraction: 0.88)
}
