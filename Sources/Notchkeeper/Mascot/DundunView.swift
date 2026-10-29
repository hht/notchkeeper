import AppKit
import SwiftUI
import MascotCore

/// 盾盾嵌进 SwiftUI 的地方。
/// 布局占 size × size，正好是身体圆的外框；画布按 docs/mascot.md §1 的比例画在 overlay 里，装饰在右上方出框。
/// size ≤ 24 用 20pt 画法（左耳），更大用 40pt 画法按比例缩放（面板、卡片、设置页）。
/// 这里只决定造型（晕、开心、犯困盖不盖过调用方给的状态）；怎么画、怎么动见 `DundunLayerView`。
struct DundunView: View {
    let state: DundunState
    let size: CGFloat
    let emote: MascotEmote
    /// 面板头部那只：能拍（拍一下晕 1.6s）
    let interactive: Bool

    init(state: DundunState, size: CGFloat, emote: MascotEmote = .none, interactive: Bool = false) {
        self.state = state
        self.size = size
        self.emote = emote
        self.interactive = interactive
    }

    /// 拍一下晕多久
    static let dizzyFor: TimeInterval = 1.6
    /// 完成卡、恢复卡出现时开心多久
    static let cheerFor: TimeInterval = 5.2

    @ObservedObject private var director = DundunDirector.shared
    /// @see https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dundunLiteral) private var literal
    @State private var dizzy = false
    @State private var cheering = false

    private var look: Look {
        if emote == .beaming || cheering { return .finished }
        return (literal ? state : DundunState.shown(base: state, dizzy: dizzy, drowsy: director.drowsy)).look
    }

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
                DundunLayer(look: look, size: c.size, unit: c.unit, reduceMotion: reduceMotion, entrance: emote != .beaming)
                    .frame(width: c.frame.width, height: c.frame.height)
                    .offset(x: c.frame.minX, y: c.frame.minY)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard interactive, !dizzy else { return }
                dizzy = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.dizzyFor))
                    dizzy = false
                }
            }
            .onAppear {
                guard emote == .cheer, !cheering else { return }
                cheering = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.cheerFor))
                    cheering = false
                }
            }
            .accessibilityElement()
            .accessibilityLabel("盾盾")
    }
}

private struct DundunLayer: NSViewRepresentable {
    let look: Look
    let size: Size
    let unit: CGFloat
    let reduceMotion: Bool
    let entrance: Bool

    func makeNSView(context: Context) -> DundunLayerView {
        DundunLayerView(look: look, size: size, unit: unit, reduceMotion: reduceMotion, entrance: entrance)
    }

    func updateNSView(_ v: DundunLayerView, context: Context) {
        v.setReduceMotion(reduceMotion)
        v.setLook(look)
    }
}

extension DundunState {
    /// 画成哪一种造型。守卫 unknown 不改造型，右耳显示灰环（docs/mascot.md §2）
    var look: Look {
        switch self {
        case .idle, .guardUnknown: return .idle
        case .sleeping: return .sleeping
        case .thinking: return .thinking
        case .working: return .working
        case .question: return .question
        case .finished: return .finished
        case .error: return .error
        case .interrupted: return .interrupted
        case .dizzy: return .dizzy
        case .guardMismatch: return .mismatch
        case .guardStale: return .stale
        case .guardViolated: return .danger
        }
    }
}

/// 「状态测试」强制显示时为 true：照给的状态画，不让晕、犯困盖掉（强制 idle 不会自己睡着）
/// @see https://developer.apple.com/documentation/swiftui/environmentkey
private struct DundunLiteralKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dundunLiteral: Bool {
        get { self[DundunLiteralKey.self] }
        set { self[DundunLiteralKey.self] = newValue }
    }
}

/// 出现时附带的表情
enum MascotEmote {
    case none
    /// 出现时开心一下（完成卡、恢复卡）
    case cheer
    /// 一直开心（设置页「关于」）
    case beaming
}
