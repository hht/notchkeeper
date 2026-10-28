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
    var isAlert = false

    static func exitAlert(ip: String?) -> NotchCard {
        NotchCard(title: "出口异常",
                  detail: ip.map { "当前出口 \($0) 不在允许列表" } ?? "当前出口不在允许列表",
                  symbol: "exclamationmark.shield.fill", tint: .red, persistent: true, mood: .worried, isAlert: true)
    }
    static func taskDone(title: String = "✅ 任务完成", detail: String = "演示：编程助手已完成任务") -> NotchCard {
        NotchCard(title: title, detail: detail, symbol: "checkmark.seal.fill", tint: .green, persistent: false, mood: .happy)
    }
    static var recovered: NotchCard {
        NotchCard(title: "出口已恢复", detail: "当前出口回到允许列表", symbol: "checkmark.shield.fill",
                  tint: .green, persistent: false, mood: .happy)
    }
}

enum NotchMode: Equatable { case closed, card, dashboard }

@MainActor
final class NotchModel: ObservableObject {
    @Published var card: NotchCard?
    @Published var expanded = false      // 卡片是否展开
    @Published var hovering = false      // 鼠标悬停展开的“岛”
    @Published var notchSize: CGSize = CGSize(width: 190, height: 32)
    @Published var cardDuration: TimeInterval = 4

    var mode: NotchMode {
        if expanded, card != nil { return .card }
        if hovering { return .dashboard }
        return .closed
    }
}

/// 三种形态的尺寸，视图和悬停命中测试共用
enum NotchLayout {
    static let cardWidth: CGFloat = 400
    static let dashWidth: CGFloat = 440
    static let rowHeight: CGFloat = 34
    static let maxRows = 5

    static func topInset(_ notch: CGSize) -> CGFloat { max(notch.height, 24) }

    static func size(_ mode: NotchMode, notch: CGSize, rows: Int) -> CGSize {
        switch mode {
        case .closed: return notch
        case .card: return CGSize(width: cardWidth, height: topInset(notch) + 72)
        case .dashboard:
            let n = min(rows, maxRows)
            let list = n == 0 ? 36 : CGFloat(n) * rowHeight
            return CGSize(width: dashWidth, height: topInset(notch) + 75 + list)
        }
    }
}

/// 刘海区域的透明窗口。收起时黑色形状与刘海重合（看不见），展开时从刘海里弹出。
/// 悬停检测不放任何拦截点击的窗口：用全局 / 本地 mouseMoved 监听判断鼠标是否在刘海热区里，
/// 所以不会抢焦点，也不会挡住别处的点击。
@MainActor
final class NotchController {
    static let windowSize = CGSize(width: 580, height: 320)
    /// 收起时的层级：在系统菜单栏之上，但在下拉菜单之下
    static let restLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    /// 展开时的层级：要压过铺满顶部的第三方菜单栏覆盖层，否则卡片上沿会被盖住一截。
    /// 只在展开期间用，收起后降回 restLevel，平时不挡下拉菜单。
    /// 实测（2026-10-28，CGWindowListCopyWindowInfo，macOS 26.5）：控制中心 25 层，
    /// Vibe Island 27 层（同 mainMenu + 3），iBar Pro 101 层（popUpMenu，铺满菜单栏），
    /// 红卡期间打开刘海旁的下拉菜单未被遮挡。
    static let openLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    private let window: NSPanel
    private let model = NotchModel()
    private let state = AppState.shared
    private var dismissWork: DispatchWorkItem?
    private var pendingAlert: NotchCard?
    private(set) var hasNotch = false

    private var moveMonitors: [Any] = []
    private let tracker = NotchMouseTracker()
    private var hoverEnabled = false
    private var hoverIntent: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var screenFrame: NSRect = .zero

    init() {
        window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = Self.restLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        let host = FirstMouseHostingView(rootView: NotchRoot(model: model, state: state, onDismiss: { [weak self] in
            self?.dismissCurrent()
        }))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.windowSize)
        window.contentView = host
        // 窗口接收鼠标后，全局监听收不到发给本 App 的事件，而这个面板不会成为 key window；
        // 用 activeAlways 的 tracking area 接住移动和移出，鼠标离开形状时才能及时恢复穿透
        // @see https://developer.apple.com/documentation/appkit/nstrackingarea/options/activealways
        // @see https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:)
        tracker.onMove = { [weak self] in self?.mouseMoved() }
        host.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                            owner: tracker, userInfo: nil))
        position()
        window.orderFrontRegardless()
        installMouseMonitors()

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
        screenFrame = s.frame
        let f = s.frame
        window.setFrame(NSRect(x: f.midX - Self.windowSize.width / 2, y: f.maxY - Self.windowSize.height,
                               width: Self.windowSize.width, height: Self.windowSize.height), display: true)
    }

    // MARK: 卡片

    func show(_ input: NotchCard) {
        let cfg = ConfigStore.shared.config
        var card = input
        if card.isAlert { card.persistent = cfg.alertPersistent }
        model.cardDuration = cfg.cardAutoDismissSeconds
        dismissWork?.cancel()
        if card.persistent { pendingAlert = card }
        if cfg.soundEnabled { NSSound(named: card.isAlert ? "Basso" : "Glass")?.play() }
        window.orderFrontRegardless()
        if model.mode != .closed {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.card = card; model.expanded = true }
        } else {
            model.card = card
            withAnimation(Motion.notchOpen) { model.expanded = true }
        }
        updateMouseCapture()
        if !card.persistent {
            let id = card.id
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.card?.id == id else { return }
                self.dismissCurrent()
            }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + cfg.cardAutoDismissSeconds, execute: work)
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
        withAnimation(model.hovering ? Motion.page : Motion.notchClose) { model.expanded = false }
        updateMouseCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.model.expanded { self.model.card = nil }
        }
    }

    // MARK: 悬停展开

    func setHoverEnabled(_ on: Bool) {
        hoverEnabled = on
        if !on {
            hoverIntent?.cancel(); hoverIntent = nil
            setHovering(false)
        }
    }

    /// 鼠标位置监听常驻：卡片的点击穿透也靠它，所以不随「悬停展开」开关装卸
    private func installMouseMonitors() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in
            Task { @MainActor in self.mouseMoved() }
        }) { moveMonitors.append(g) }
    }

    /// 窗口收不收鼠标、在哪一层只由这里决定：鼠标落在当前看得见的形状里才接收，
    /// 其余（包括 580×320 窗口的透明部分）一律穿透，不挡菜单栏和别的 App
    private func updateMouseCapture() {
        let open = model.mode != .closed
        let level = open ? Self.openLevel : Self.restLevel
        if window.level != level { window.level = level }
        let capture = open && shapeRect.contains(NSEvent.mouseLocation)
        if window.ignoresMouseEvents == capture { window.ignoresMouseEvents = !capture }
    }

    /// 刘海本体（或无刘海屏顶端中间一条细带）略放大一点作为触发热区
    private var triggerRect: NSRect {
        let f = screenFrame
        let n = model.notchSize
        let w = (hasNotch ? n.width : 200) + 16
        let h = hasNotch ? n.height + 2 : 6
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    /// 当前可见形状的屏幕区域（与视图共用 NotchLayout 的尺寸）
    private var shapeRect: NSRect {
        let s = NotchLayout.size(model.mode, notch: model.notchSize, rows: state.sessions.count)
        let f = screenFrame
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    /// 判断悬停是否离开时多留 10pt 余量
    private var visibleRect: NSRect { shapeRect.insetBy(dx: -10, dy: -10) }

    private func mouseMoved() {
        updateMouseCapture()
        guard hoverEnabled else { return }
        let p = NSEvent.mouseLocation
        if model.hovering {
            if visibleRect.contains(p) || triggerRect.contains(p) {
                leaveWork?.cancel(); leaveWork = nil
            } else if leaveWork == nil {
                let w = DispatchWorkItem { [weak self] in self?.setHovering(false) }
                leaveWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            }
        } else if triggerRect.contains(p) {
            guard hoverIntent == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hoverIntent = nil
                if self.triggerRect.contains(NSEvent.mouseLocation) { self.setHovering(true) }
            }
            hoverIntent = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
        } else {
            hoverIntent?.cancel(); hoverIntent = nil
        }
    }

    private func setHovering(_ on: Bool) {
        leaveWork?.cancel(); leaveWork = nil
        guard model.hovering != on else { return }
        if on {
            state.scanSessions()
            window.orderFrontRegardless()
            withAnimation(Motion.notchOpen) { model.hovering = true }
            updateMouseCapture()
        } else {
            withAnimation(Motion.notchClose) { model.hovering = false }
            updateMouseCapture()
        }
    }
}

/// 接住宿主视图 tracking area 的鼠标事件，转给 NotchController
final class NotchMouseTracker: NSResponder {
    var onMove: () -> Void = {}
    override func mouseMoved(with event: NSEvent) { onMove() }
    override func mouseEntered(with event: NSEvent) { onMove() }
    override func mouseExited(with event: NSEvent) { onMove() }
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// false 时不画顶边（描边用）：卡片顶部和刘海连成一体，不出现一条线
    var closed = true

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
        if closed { p.closeSubpath() }
        return p
    }
}

struct NotchRoot: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var state: AppState
    let onDismiss: () -> Void

    var body: some View {
        let mode = model.mode
        let size = NotchLayout.size(mode, notch: model.notchSize, rows: state.sessions.count)
        let open = mode != .closed
        let t: CGFloat = open ? 14 : 4
        let b: CGFloat = mode == .dashboard ? 26 : (open ? 28 : 8)
        let shape = NotchShape(topRadius: t, bottomRadius: b)
        let glow: Color = mode == .card ? (model.card?.tint ?? .clear) : .white

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) { content(mode, inset: t) }
                .overlay {
                    // 卡片描边从两侧往下由淡到实，底边最亮；其余形态是一条很淡的白线
                    NotchShape(topRadius: t, bottomRadius: b, closed: false)
                        .stroke(mode == .card
                                ? AnyShapeStyle(LinearGradient(colors: [glow.opacity(0.3), glow], startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(glow.opacity(open ? 0.08 : 0)),
                                lineWidth: 1)
                }
                .clipShape(shape)
                .shadow(color: (mode == .card ? glow : .black).opacity(open ? 0.3 : 0), radius: 18, y: 6)
                .animation(Motion.page, value: state.sessions.count)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func content(_ mode: NotchMode, inset: CGFloat) -> some View {
        let top = NotchLayout.topInset(model.notchSize) - 2
        switch mode {
        case .card:
            if let card = model.card {
                NotchCardView(card: card, duration: model.cardDuration, onDismiss: onDismiss)
                    .id(card.id)
                    .padding(.top, top)
                    .padding(.horizontal, inset)
                    .transition(Self.contentTransition)
            }
        case .dashboard:
            NotchDashboard(state: state)
                .frame(width: NotchLayout.dashWidth)
                .padding(.top, top)
                .transition(Self.contentTransition)
        case .closed:
            EmptyView()
        }
    }

    static let contentTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.08)),
        removal: .opacity.animation(.easeIn(duration: 0.1)))
}

/// 悬停展开内容：出口 + 活跃会话。只显示项目名 / agent / 状态 / 时间，不显示任何对话内容。
struct NotchDashboard: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Mascot(mood: state.status.mood, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(state.status.color).frame(width: 7, height: 7)
                            .shadow(color: state.status.color.opacity(0.8), radius: 3)
                        Text(state.status.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(state.exitIP.map { "出口 \($0)" } ?? "出口 —")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(state.status == .unhealthy ? Color.red.opacity(0.9) : .white.opacity(0.6))
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("进程").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.35))
                    Text("claude \(state.processes.claude) · codex \(state.processes.codex)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(height: 40)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            if state.sessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz").font(.system(size: 11))
                    Text("近 30 分钟没有活跃的编程会话").font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                VStack(spacing: 0) {
                    ForEach(state.sessions.prefix(NotchLayout.maxRows)) { s in
                        SessionRow(session: s).frame(height: NotchLayout.rowHeight)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

struct SessionRow: View {
    let session: AgentSession
    var dark = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 10) {
                Image(systemName: session.agent.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(session.agent.tint)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(session.agent.tint.opacity(0.18)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.project).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(dark ? Color.white : Color.primary)
                    Text(session.agent.displayName).font(.system(size: 10))
                        .foregroundStyle(dark ? Color.white.opacity(0.45) : Color.secondary)
                }
                Spacer(minLength: 6)
                StatePill(running: session.state == .running, dark: dark)
                Text(elapsed(ctx.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(dark ? Color.white.opacity(0.6) : Color.secondary)
                    .frame(minWidth: 58, alignment: .trailing)
            }
        }
    }

    private func elapsed(_ now: Date) -> String {
        if session.state == .running {
            return Self.duration(now.timeIntervalSince(session.turnStart ?? session.lastActivity))
        }
        return Self.duration(now.timeIntervalSince(session.lastActivity)) + "前"
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)秒" }
        if s < 3600 { return "\(s / 60)分\(String(format: "%02d", s % 60))秒" }
        return "\(s / 3600)时\(String(format: "%02d", (s % 3600) / 60))分"
    }
}

struct StatePill: View {
    let running: Bool
    var dark = true
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(running ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
                .scaleEffect(running && pulse ? 1.35 : 1)
                .opacity(running && pulse ? 0.55 : 1)
            Text(running ? "运行中" : "空闲").font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(running ? Color.green : (dark ? Color.white.opacity(0.5) : Color.secondary))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill((running ? Color.green : Color.gray).opacity(0.14)))
        .onAppear {
            guard running else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct NotchCardView: View {
    let card: NotchCard
    let duration: TimeInterval
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
            withAnimation(.linear(duration: duration)) { progress = 0 }
        }
    }
}
