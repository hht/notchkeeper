import AppKit
import SwiftUI
import MascotCore

/// Pip 嵌进 SwiftUI 的地方。
/// 布局占 size × size，正好是身体圆的外框；画布按 docs/mascot.md §1 的比例画在 overlay 里，装饰在右上方出框。
/// size ≤ 24 用 20pt 画法（左耳），更大用 40pt 画法按比例缩放（面板、卡片、设置页）。
/// 这里只决定画哪个造型（开心、犯困盖不盖过调用方给的造型）；怎么画、怎么动见 `MascotFigureView`。
struct MascotView: View {
    let look: Look
    let size: CGFloat
    /// 收起态的左耳、面板：sign 装饰挪到右边，这里不画
    var hidesSigns = false
    /// false：此刻透明、看不见（关掉了收起时的 Pip），停掉动画，导演的时钟也跟着停
    var playing = true

    @ObservedObject private var director = MascotDirector.shared
    /// @see https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mascotLiteral) private var literal

    private var shown: Look { literal ? look : look.shown(drowsy: director.drowsy) }

    /// 画布相对身体外框（原点 = 身体左上）的位置，单位 pt。身体外框在画布里是 (4, 6.5) 起的 20 × 20 单位
    private var canvas: (size: Size, unit: CGFloat, frame: CGRect) {
        let s: Size = size <= 24 ? .small : .large
        let k = size / (2 * Anatomy.bodyRadius)
        let c = s.canvas
        let x = Anatomy.bodyCenter.x - Anatomy.bodyRadius, y = Anatomy.bodyCenter.y - Anatomy.bodyRadius
        return (s, k, CGRect(x: (c.minX - x) * k, y: (c.minY - y) * k, width: c.width * k, height: c.height * k))
    }

    var body: some View {
        let c = canvas
        Color.clear
            .frame(width: size, height: size)
            .overlay(alignment: .topLeading) {
                MascotLayer(look: shown, size: c.size, unit: c.unit, reduceMotion: reduceMotion, hidesSigns: hidesSigns, playing: playing)
                    .frame(width: c.frame.width, height: c.frame.height)
                    .offset(x: c.frame.minX, y: c.frame.minY)
                    .allowsHitTesting(false)
            }
            .accessibilityElement()
            .accessibilityLabel("Pip")
            // Pip 用表情表达状态，旁白要能念出来（HIG Accessibility）
            .accessibilityValue(shown.title)
    }
}

private struct MascotLayer: NSViewRepresentable {
    let look: Look
    let size: Size
    let unit: CGFloat
    let reduceMotion: Bool
    let hidesSigns: Bool
    let playing: Bool

    func makeNSView(context: Context) -> MascotFigureView {
        let v = MascotFigureView(look: look, size: size, unit: unit, reduceMotion: reduceMotion, entrance: true, hidesSigns: hidesSigns)
        v.playing = playing
        return v
    }

    func updateNSView(_ v: MascotFigureView, context: Context) {
        v.playing = playing
        v.setReduceMotion(reduceMotion)
        v.setLook(look, hidesSigns: hidesSigns)
    }
}

extension Look {
    /// 实际画哪个：守卫照画；空闲时鼠标久不靠近刘海就睡着。完整的优先级第 4 步由 NotchCore 负责
    func shown(drowsy: Bool) -> Look {
        self == .idle && drowsy ? .sleeping : self
    }
}

/// 「状态测试」强制显示时为 true：照给的造型画，不让犯困盖掉（强制空闲不会自己睡着）
/// @see https://developer.apple.com/documentation/swiftui/environmentkey
private struct MascotLiteralKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mascotLiteral: Bool {
        get { self[MascotLiteralKey.self] }
        set { self[MascotLiteralKey.self] = newValue }
    }
}
