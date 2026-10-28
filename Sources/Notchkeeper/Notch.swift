import AppKit
import SwiftUI

struct NotchCard: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
    var persistent: Bool
    var mood: MascotMood = .idle

    static func exitAlert(ip: String?) -> NotchCard {
        NotchCard(title: "出口异常",
                  detail: ip.map { "当前出口 \($0) 不在允许列表" } ?? "当前出口不在允许列表",
                  symbol: "exclamationmark.shield.fill", tint: .red, persistent: true, mood: .worried)
    }
    static func taskDone(title: String = "✅ 任务完成", detail: String = "演示：编程助手已完成任务") -> NotchCard {
        NotchCard(title: title, detail: detail, symbol: "checkmark.seal.fill", tint: .green, persistent: false, mood: .happy)
    }
    static var recovered: NotchCard {
        NotchCard(title: "出口已恢复", detail: "当前出口回到允许列表", symbol: "checkmark.shield.fill",
                  tint: .green, persistent: false, mood: .happy)
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var card: NotchCard?
    @Published var expanded = false
    @Published var notchSize: CGSize = CGSize(width: 190, height: 32)
}

/// 刘海区域的透明窗口。收起时黑色形状与刘海重合（看不见），展开时从刘海里弹出。
@MainActor
final class NotchController {
    static let autoDismiss: TimeInterval = 4
    static let windowSize = CGSize(width: 520, height: 200)

    private let window: NSPanel
    private let model = NotchModel()
    private var dismissWork: DispatchWorkItem?
    private var pendingAlert: NotchCard?
    private(set) var hasNotch = false

    init() {
        window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        let host = FirstMouseHostingView(rootView: NotchRoot(model: model, onDismiss: { [weak self] in
            self?.dismissCurrent()
        }))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.windowSize)
        window.contentView = host
        position()
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.position() }
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func position() {
        guard let s = targetScreen() else { return }
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            hasNotch = true
            model.notchSize = CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        } else {
            hasNotch = false
            // 没有刘海的屏幕：从屏幕顶端中间“长”出来
            model.notchSize = CGSize(width: 180, height: 0)
        }
        let f = s.frame
        window.setFrame(NSRect(x: f.midX - Self.windowSize.width / 2, y: f.maxY - Self.windowSize.height,
                               width: Self.windowSize.width, height: Self.windowSize.height), display: true)
    }

    func show(_ card: NotchCard) {
        dismissWork?.cancel()
        if card.persistent { pendingAlert = card }
        window.orderFrontRegardless()
        window.ignoresMouseEvents = false
        if model.expanded, model.card != nil {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.card = card }
        } else {
            model.card = card
            withAnimation(Motion.notchOpen) { model.expanded = true }
        }
        if !card.persistent {
            let id = card.id
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.card?.id == id else { return }
                self.dismissCurrent()
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoDismiss, execute: work)
        }
    }

    /// 关闭当前卡片；临时卡片关掉后，如果还有常驻红卡就恢复红卡
    func dismissCurrent() {
        dismissWork?.cancel()
        guard let current = model.card else { return }
        if current.persistent {
            pendingAlert = nil
        } else if let alert = pendingAlert {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.card = alert }
            return
        }
        collapse()
    }

    /// 出口恢复：撤掉红卡，可选弹一张短暂的“已恢复”
    func clearAlert(showRecovered: Bool) {
        let hadAlert = pendingAlert != nil
        pendingAlert = nil
        if showRecovered && (hadAlert || model.card?.persistent == true) {
            show(.recovered)
        } else if model.card?.persistent == true {
            collapse()
        }
    }

    private func collapse() {
        withAnimation(Motion.notchClose) { model.expanded = false }
        window.ignoresMouseEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.model.expanded { self.model.card = nil }
        }
    }
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard r.width > 0, r.height > 0 else { return p }
        let t = min(topRadius, r.width / 4, r.height / 2)
        let b = max(0, min(bottomRadius, r.height - t, (r.width - 2 * t) / 2))
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRoot: View {
    @ObservedObject var model: NotchModel
    let onDismiss: () -> Void

    var body: some View {
        let closed = model.notchSize
        let expanded = model.expanded
        let openW: CGFloat = 400
        let openH: CGFloat = max(closed.height, 24) + 72
        let w = expanded ? openW : closed.width
        let h = expanded ? openH : closed.height
        let t: CGFloat = expanded ? 14 : 4
        let b: CGFloat = expanded ? 28 : 8
        let shape = NotchShape(topRadius: t, bottomRadius: b)

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .overlay(alignment: .top) {
                    if expanded, let card = model.card {
                        NotchCardView(card: card, onDismiss: onDismiss)
                            .id(card.id)
                            .padding(.top, max(closed.height, 24) - 2)
                            .padding(.horizontal, t)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
                                    .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.1)),
                                removal: .opacity.animation(.easeIn(duration: 0.12))))
                    }
                }
                .overlay {
                    shape.stroke((model.card?.tint ?? .clear).opacity(expanded ? 0.35 : 0), lineWidth: 1)
                }
                .clipShape(shape)
                .frame(width: w, height: h)
                .shadow(color: (model.card?.tint ?? .black).opacity(expanded ? 0.28 : 0), radius: 18, y: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct NotchCardView: View {
    let card: NotchCard
    let onDismiss: () -> Void
    @State private var progress: CGFloat = 1

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // 吉祥物插槽（占位，原创角色稍后替换）
                Mascot(mood: card.mood, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(card.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(PressableStyle())
            }
            if !card.persistent {
                GeometryReader { g in
                    Capsule().fill(Color.white.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule().fill(card.tint.opacity(0.85)).frame(width: g.size.width * progress)
                        }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .onAppear {
            guard !card.persistent else { return }
            progress = 1
            withAnimation(.linear(duration: NotchController.autoDismiss)) { progress = 0 }
        }
    }
}
