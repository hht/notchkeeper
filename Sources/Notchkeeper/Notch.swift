import AppKit
import SwiftUI
import MascotCore

struct NotchCard: Identifiable, Equatable {
    enum Kind { case done, alert, recovered }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var tint: Color
    var persistent: Bool

    /// 出口红卡。是否常驻由设置「红卡一直保留，直到恢复」决定，show 时覆盖
    static func exitAlert(detail: String = GuardPresentation.violatedDetail) -> NotchCard {
        NotchCard(kind: .alert, title: GuardPresentation.violatedTitle, detail: detail,
                  tint: Color(cgColor: DundunConst.red), persistent: true)
    }
    static func taskDone(title: String, detail: String) -> NotchCard {
        NotchCard(kind: .done, title: title, detail: detail, tint: .green, persistent: false)
    }
    static var recovered: NotchCard {
        NotchCard(kind: .recovered, title: "出口已恢复", detail: "流量重新全部走 utun 隧道", tint: .green, persistent: false)
    }
    /// 恢复卡固定 4 秒，不跟「卡片停留」设置走（Emily 规格）
    static let recoveredSeconds: TimeInterval = 4

    /// 红卡上是红盾盾；完成卡、恢复卡上开心一下
    var mascotState: DundunState { kind == .alert ? .guardViolated : .idle }
    var mascotEmote: MascotEmote { kind == .alert ? .none : .cheer }
}

/// 临时卡片的倒计时：鼠标停在卡片上时暂停，移开后从剩下的时间继续
struct CardCountdown: Equatable {
    let total: TimeInterval
    private var remainingAtResume: TimeInterval
    /// nil 表示暂停中
    private var resumedAt: Date?

    init(total: TimeInterval, now: Date) {
        self.total = total
        remainingAtResume = total
        resumedAt = now
    }

    var isPaused: Bool { resumedAt == nil }

    func remaining(at now: Date) -> TimeInterval {
        guard let r = resumedAt else { return remainingAtResume }
        return max(0, remainingAtResume - now.timeIntervalSince(r))
    }

    func fraction(at now: Date) -> Double { total > 0 ? remaining(at: now) / total : 0 }

    mutating func pause(at now: Date) {
        guard !isPaused else { return }
        remainingAtResume = remaining(at: now)
        resumedAt = nil
    }

    mutating func resume(at now: Date) {
        guard isPaused else { return }
        resumedAt = now
    }
}

enum NotchMode: Equatable { case closed, card, dashboard }

/// 「状态测试」的覆盖（StateTest.swift）：只在内存里，只经 NotchController 改，重开 App 就没了
@MainActor
final class NotchOverrides: ObservableObject {
    @Published fileprivate(set) var dundun: DundunTestState?
    @Published fileprivate(set) var pin: NotchPin = .auto

    var isReal: Bool { dundun == nil && pin == .auto }

    /// 盾盾实际显示的状态：强制的优先，否则是真实的守卫状态
    func mascot(real: DundunState) -> DundunState { dundun?.dundun ?? real }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var card: NotchCard?
    @Published var expanded = false      // 卡片是否展开
    @Published var hovering = false      // 鼠标悬停展开的“岛”
    @Published var notchSize: CGSize = CGSize(width: 190, height: 32)
    @Published var countdown: CardCountdown?
    let overrides = NotchOverrides()

    /// 卡片压过一切（固定收起也挡不住真的红卡）；其余由固定方式决定，自动时跟悬停走
    var mode: NotchMode {
        if expanded, card != nil { return .card }
        switch overrides.pin {
        case .open: return .dashboard
        case .closed: return .closed
        case .auto: return hovering ? .dashboard : .closed
        }
    }
}

/// 三种形态的尺寸，视图和悬停命中测试共用
enum NotchLayout {
    static let cardWidth: CGFloat = 400
    static let dashWidth: CGFloat = 440
    static let rowHeight: CGFloat = 34
    static let maxRows = 5

    /// 收起时刘海两侧各一只耳朵：左耳放盾盾，右耳放状态指示（docs/mascot.md §1）
    static let earWidth: CGFloat = 44
    /// 收起时形状顶角往外翻的宽度（NotchShape 的 topRadius）
    static let closedFlare: CGFloat = 4
    /// 左耳盾盾画布 28×28，左缘在身体外边（形状左边 + 外翻）往里 6pt，离刘海也是 6pt（docs/mascot.md §1）
    static let earCanvas: CGFloat = 28
    static let earCanvasInset: CGFloat = 6
    /// 画布里身体中心的纵坐标；身体中心对齐 notchSize.height / 2，所以 32pt 刘海时画布上缘在 -0.5
    static let earBodyCenterY: CGFloat = 16.5
    /// 左耳盾盾的身体直径（docs/mascot.md §1：20pt 版）
    static let earMascotSize: CGFloat = 20
    /// 右耳 7pt 圆点的圆心离形状右边 17.5（docs/mascot.md §1）
    static let earDotInset: CGFloat = 17.5
    /// 三颗点（右缘离形状右边 14）整组中心比圆点圆心再往左 3
    static let earDotsShift: CGFloat = 3

    /// 收起态两只耳朵在形状里的位置（原点在形状左上），W = 刘海宽 + 88，H = 刘海高
    struct Ears: Equatable {
        var canvas: CGRect
        var bodyCenter: CGPoint
    }

    static func ears(notch: CGSize, flare: CGFloat = closedFlare) -> Ears {
        let mid = notch.height / 2
        let canvas = CGRect(x: flare + earCanvasInset, y: mid - earBodyCenterY, width: earCanvas, height: earCanvas)
        return Ears(canvas: canvas, bodyCenter: CGPoint(x: canvas.minX + earCanvas / 2, y: mid))
    }

    /// 没有刘海的屏幕（高度 0）不长耳朵，保持原来从顶端中间长出来的样子
    static func hasEars(_ notch: CGSize) -> Bool { notch.height > 0 }

    static func topInset(_ notch: CGSize) -> CGFloat { max(notch.height, 24) }

    static func size(_ mode: NotchMode, notch: CGSize, rows: Int) -> CGSize {
        switch mode {
        case .closed:
            return hasEars(notch) ? CGSize(width: notch.width + 2 * earWidth, height: notch.height) : notch
        case .card: return CGSize(width: cardWidth, height: topInset(notch) + 72)
        case .dashboard:
            let n = min(rows, maxRows)
            let list = n == 0 ? 36 : CGFloat(n) * rowHeight
            return CGSize(width: dashWidth, height: topInset(notch) + 75 + list)
        }
    }
}

/// 刘海区域的透明窗口。收起时黑色形状与刘海重合（看不见），展开时从刘海里弹出。
/// 收起时窗口不接收鼠标：悬停和刘海上的点击都靠全局监听判断鼠标是否在刘海热区里，
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
    private var countdownWork: DispatchWorkItem?
    /// 出口红卡（正在显示，或被临时卡片暂时盖住）
    private var pendingAlert: NotchCard?
    /// 这次违规弹过红卡（之后被关掉、断网、守卫不响应都不清），回到 healthy 时据此弹恢复卡
    private var violationAlerted = false
    var hasNotch: Bool { NotchLayout.hasEars(model.notchSize) }
    var overrides: NotchOverrides { model.overrides }

    private var moveMonitors: [Any] = []
    private let tracker = NotchMouseTracker()
    private var hoverEnabled = false
    private var hoverIntent: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var screenFrame: NSRect = .zero

    /// 齿轮按钮：打开设置
    var onOpenSettings: () -> Void = {}
    /// 在刘海或展开的形状上右键时弹出
    var contextMenu: NSMenu?
    /// 红卡没等到 healthy 就收起（用户点 ×，或非常驻红卡到时）：记作用户关掉了这一次违规
    var onAlertDismissed: () -> Void = {}

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

        let host = FirstMouseHostingView(rootView: NotchRoot(model: model, overrides: model.overrides, state: state, onDismiss: { [weak self] in
            self?.dismissCurrent()
        }, onSettings: { [weak self] in
            self?.setHovering(false)
            self?.onOpenSettings()
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
        orderFront()
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
        // 没有刘海的屏幕：从屏幕顶端中间“长”出来
        var notch = CGSize(width: 180, height: 0)
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notch = CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
        }
        model.notchSize = notch
        let f = s.frame
        screenFrame = f
        window.setFrame(NSRect(x: f.midX - Self.windowSize.width / 2, y: f.maxY - Self.windowSize.height,
                               width: Self.windowSize.width, height: Self.windowSize.height), display: true)
    }

    // MARK: 卡片

    private func orderFront() { window.orderFrontRegardless() }

    /// 现在看得见的卡片（收起动画里的不算）
    var visibleCard: NotchCard? { model.expanded ? model.card : nil }

    /// - sound: false 时不响（守卫不响应时保留的红卡不再响 Basso）
    func show(_ input: NotchCard, sound: Bool = true) {
        // 恢复卡不叠第二张
        if input.kind == .recovered, visibleCard?.kind == .recovered { return }
        let cfg = ConfigStore.shared.config
        var card = input
        if card.kind == .alert {
            card.persistent = cfg.alertPersistent
            pendingAlert = card
        }
        if sound, cfg.soundEnabled { NSSound(named: card.kind == .alert ? "Basso" : "Glass")?.play() }
        present(card)
    }

    private func present(_ card: NotchCard) {
        countdownWork?.cancel()
        model.countdown = nil
        orderFront()
        if model.mode != .closed {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { model.card = card; model.expanded = true }
        } else {
            model.card = card
            withAnimation(Motion.notchOpen) { model.expanded = true }
        }
        updateMouseCapture()
        if !card.persistent {
            let total = card.kind == .recovered ? NotchCard.recoveredSeconds : ConfigStore.shared.config.cardAutoDismissSeconds
            model.countdown = CardCountdown(total: total, now: Date())
            scheduleCountdown()
            setCardHover(model.mode == .card && shapeRect.contains(NSEvent.mouseLocation))
        }
    }

    private func scheduleCountdown() {
        countdownWork?.cancel()
        guard let c = model.countdown, !c.isPaused, let id = model.card?.id else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.card?.id == id else { return }
            self.dismissCurrent()
        }
        countdownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + c.remaining(at: Date()), execute: work)
    }

    /// 鼠标在卡片上：倒计时暂停；移开：从剩下的时间继续
    func setCardHover(_ over: Bool) {
        guard var c = model.countdown, over != c.isPaused else { return }
        if over {
            c.pause(at: Date())
            countdownWork?.cancel()
            model.countdown = c
        } else {
            c.resume(at: Date())
            model.countdown = c
            scheduleCountdown()
        }
    }

    /// 关闭当前卡片（× 或倒计时到）。红卡关掉算用户关掉这一次违规；
    /// 临时卡片关掉后，如果还有红卡就恢复红卡
    func dismissCurrent() {
        countdownWork?.cancel()
        model.countdown = nil
        guard let current = model.card else { return }
        if current.kind == .alert {
            pendingAlert = nil
            collapse()
            onAlertDismissed()
        } else if let alert = pendingAlert {
            present(alert)
        } else {
            collapse()
        }
    }

    /// 每读一次守卫状态调用一次。`old` 是这次读之前的显示，只用来判断「之前是不是违规」
    func guardChanged(to new: GuardPresentation) {
        if new.clearsAlert {
            // 只有弹过红卡的那次违规回到 healthy 才弹恢复卡：中间断网、守卫不响应、用户关掉红卡都算同一次
            let alertOnScreen = visibleCard?.kind == .alert
            pendingAlert = nil
            if violationAlerted {
                violationAlerted = false
                show(.recovered)
            } else if alertOnScreen {
                // 没有对应违规的红卡（scripts/demo.sh alert）：读到 healthy 照样撤掉
                countdownWork?.cancel()
                model.countdown = nil
                collapse()
            }
            return
        }
        guard let alert = new.alert, ConfigStore.shared.config.autoAlert else { return }
        violationAlerted = true
        if var shown = pendingAlert {
            // 红卡已经在：只换副标题，不重弹、不重响
            guard shown.detail != alert.detail else { return }
            shown.detail = alert.detail
            pendingAlert = shown
            if model.card?.id == shown.id { model.card = shown }
        } else {
            show(.exitAlert(detail: alert.detail), sound: alert.sounds)
        }
    }

    private func collapse() {
        withAnimation(model.hovering ? Motion.page : Motion.notchClose) { model.expanded = false }
        updateMouseCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.model.expanded { self.model.card = nil }
        }
    }

    // MARK: 状态测试（只在内存里，见 StateTest.swift）

    var mode: NotchMode { model.mode }

    /// 强制盾盾显示某个状态；nil 回到真实状态。只换盾盾的样子：不调 guardChanged、不碰 AppState，
    /// 所以强制「危险」不弹红卡、不响，也不动「这次违规已关掉」的记录
    func force(_ s: DundunTestState?) {
        guard overrides.dundun != s else { return }
        overrides.dundun = s
    }

    /// 固定展开 / 固定收起 / 自动。换的时候清掉悬停，回到自动时按当前鼠标重新判断
    func setPin(_ p: NotchPin) {
        guard overrides.pin != p else { return }
        hoverIntent?.cancel(); hoverIntent = nil
        leaveWork?.cancel(); leaveWork = nil
        let opening = p == .open && model.mode == .closed
        if opening { state.scanSessions(); orderFront() }
        withAnimation(opening ? Motion.notchOpen : Motion.notchClose) {
            overrides.pin = p
            model.hovering = false
        }
        updateMouseCapture()
    }

    /// 「恢复真实状态」：两项覆盖一起清掉
    func restoreRealState() {
        force(nil)
        setPin(.auto)
    }

    // MARK: 悬停展开

    func setHoverEnabled(_ on: Bool) {
        hoverEnabled = on
        if !on {
            hoverIntent?.cancel(); hoverIntent = nil
            setHovering(false)
        }
    }

    /// 鼠标监听常驻：卡片的点击穿透也靠它，所以不随「悬停展开」开关装卸。
    /// 收起时点击发给的是别的 App，只有全局监听看得到；展开后窗口接收鼠标，点击改由本地监听接住。
    /// @see https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents(matching:handler:)
    private func installMouseMonitors() {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in
            Task { @MainActor in self.mouseMoved() }
        }) { moveMonitors.append(g) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            let right = e.type == .rightMouseDown
            Task { @MainActor in _ = self.mouseDown(right: right) }
        }) { moveMonitors.append(g) }
        // 鼠标在收起的耳朵上时窗口接收鼠标（见 captures），左键点击也只有本地监听看得到
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            self.mouseDown(right: e.type == .rightMouseDown) ? nil : e
        }) { moveMonitors.append(l) }
    }

    /// 点刘海展开；在刘海或展开的形状上右键弹出菜单。返回 true 表示事件已处理
    private func mouseDown(right: Bool) -> Bool {
        let p = NSEvent.mouseLocation
        let onShape = triggerRect.contains(p) || (model.mode != .closed && shapeRect.contains(p))
        guard onShape else { return false }
        if right {
            guard let menu = contextMenu else { return false }
            menu.popUp(positioning: nil, at: p, in: nil)
            return true
        }
        guard model.mode == .closed, overrides.pin == .auto else { return false }
        hoverIntent?.cancel(); hoverIntent = nil
        setHovering(true)
        return true
    }

    /// 刘海本体在屏幕上的位置（盾盾 DundunDirector 贴着它走）
    var anchorRect: NSRect {
        let h = NotchLayout.topInset(model.notchSize)
        let w = model.notchSize.width
        return NSRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }

    /// 窗口收不收鼠标、在哪一层只由这里决定：鼠标落在当前看得见的形状里才接收，
    /// 其余（包括 580×320 窗口的透明部分）一律穿透，不挡菜单栏和别的 App
    private func updateMouseCapture() {
        let open = model.mode != .closed
        let level = open ? Self.openLevel : Self.restLevel
        if window.level != level { window.level = level }
        let capture = captures(NSEvent.mouseLocation)
        if window.ignoresMouseEvents == capture { window.ignoresMouseEvents = !capture }
    }

    /// 这一点上窗口要不要接收鼠标：展开时是整个形状；收起时是刘海加两只黑色耳朵（耳朵挡在菜单栏上，
    /// 点它不能漏给后面的菜单栏），没有刘海的屏幕收起时形状高 0，一律穿透
    func captures(_ p: NSPoint) -> Bool {
        (model.mode != .closed || hasNotch) && shapeRect.contains(p)
    }

    /// 收起的形状（刘海加两只耳朵，或无刘海屏顶端中间一条细带）略放大一点作为悬停、点击热区
    var triggerRect: NSRect {
        let f = screenFrame
        let n = NotchLayout.size(.closed, notch: model.notchSize, rows: 0)
        let w = (hasNotch ? n.width : 200) + 16
        let h = hasNotch ? n.height + 2 : 6
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h + Self.topEdgeSlack)
    }

    /// 鼠标顶到屏幕最上沿时 NSEvent.mouseLocation.y 恰好等于 frame.maxY，而 NSRect.contains 不含上边界，
    /// 所以命中区要越过屏幕顶边 1pt，否则贴顶的鼠标永远判在区外（2026-10-28 在刘海机型上用 CGWarpMouseCursorPosition 实测）
    /// @see https://developer.apple.com/documentation/appkit/nsevent/mouselocation
    /// @see https://developer.apple.com/documentation/corefoundation/cgrect
    private static let topEdgeSlack: CGFloat = 1

    /// 当前可见形状的屏幕区域（与视图共用 NotchLayout 的尺寸）
    private var shapeRect: NSRect {
        let s = NotchLayout.size(model.mode, notch: model.notchSize, rows: state.sessions.count)
        let f = screenFrame
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height + Self.topEdgeSlack)
    }

    /// 判断悬停是否离开时多留 10pt 余量
    private var visibleRect: NSRect { shapeRect.insetBy(dx: -10, dy: -10) }

    private func mouseMoved() {
        updateMouseCapture()
        let p = NSEvent.mouseLocation
        DundunDirector.shared.mouseMoved(to: p)
        setCardHover(model.mode == .card && shapeRect.contains(p))
        // 点击展开的岛不受「悬停展开」开关影响，离开时照样收起
        if model.hovering {
            if visibleRect.contains(p) || triggerRect.contains(p) {
                leaveWork?.cancel(); leaveWork = nil
            } else if leaveWork == nil {
                let w = DispatchWorkItem { [weak self] in self?.setHovering(false) }
                leaveWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            }
        } else if hoverEnabled, overrides.pin == .auto, triggerRect.contains(p) {
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

    func setHovering(_ on: Bool) {
        leaveWork?.cancel(); leaveWork = nil
        guard model.hovering != on else { return }
        if on {
            state.scanSessions()
            orderFront()
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
    @ObservedObject var overrides: NotchOverrides
    @ObservedObject var state: AppState
    let onDismiss: () -> Void
    let onSettings: () -> Void

    var body: some View {
        let mode = model.mode
        let size = NotchLayout.size(mode, notch: model.notchSize, rows: state.sessions.count)
        let open = mode != .closed
        let t: CGFloat = open ? 14 : NotchLayout.closedFlare
        let b: CGFloat = mode == .dashboard ? 26 : (open ? 28 : 8)
        let shape = NotchShape(topRadius: t, bottomRadius: b)
        let glow: Color = mode == .card ? (model.card?.tint ?? .clear) : .white

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) { content(mode, inset: t) }
                .overlay(alignment: .topTrailing) {
                    if mode == .dashboard {
                        NotchGearButton(action: onSettings)
                            .padding(.top, 12)
                            .padding(.trailing, t + 12)
                            .transition(Self.contentTransition)
                    }
                }
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
                NotchCardView(card: card, countdown: model.countdown, onDismiss: onDismiss)
                    .id(card.id)
                    .padding(.top, top)
                    .padding(.horizontal, inset)
                    .transition(Self.contentTransition)
            }
        case .dashboard:
            NotchDashboard(state: state, overrides: overrides)
                .frame(width: NotchLayout.dashWidth)
                .padding(.top, top)
                .transition(Self.contentTransition)
        case .closed:
            if NotchLayout.hasEars(model.notchSize) {
                NotchEars(mascot: overrides.mascot(real: state.presentation.mascotState), forced: overrides.dundun != nil,
                          notch: model.notchSize, flare: inset)
            }
        }
    }

    static let contentTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
            .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.08)),
        removal: .opacity.animation(.easeIn(duration: 0.1)))
}

/// 收起时的两只耳朵（docs/mascot.md §1、§2）。纯黑、无描边无阴影，
/// 底色就是 NotchRoot 的黑形状。坐标见 `NotchLayout.ears`：左耳身体圆心 x = 外翻 + 6 + 14、y = H/2；
/// 右耳圆点圆心 x = W − 17.5。点击和悬停由 NotchController 的热区处理。
struct NotchEars: View {
    let mascot: DundunState
    let forced: Bool
    let notch: CGSize
    let flare: CGFloat

    @ObservedObject private var director = DundunDirector.shared
    @ObservedObject private var earState = DundunEarState.shared

    /// 右耳跟着左耳实际画的造型走（犯困时左耳睡着，右耳就不亮）
    private var look: Look {
        (forced ? mascot : DundunState.shown(base: mascot, dizzy: false, drowsy: director.drowsy)).look
    }

    var body: some View {
        let e = NotchLayout.ears(notch: notch, flare: flare)
        let w = notch.width + 2 * NotchLayout.earWidth
        ZStack(alignment: .topLeading) {
            DundunView(state: mascot, size: NotchLayout.earMascotSize)
                .environment(\.dundunLiteral, forced)
                .position(e.bodyCenter)
            DundunEarView(indicator: .for(look, guardUnknown: mascot == .guardUnknown, errorUnread: earState.errorUnread), height: notch.height)
                .frame(width: NotchLayout.earWidth, height: notch.height)
                .position(x: w - NotchLayout.earWidth / 2, y: notch.height / 2)
        }
        .frame(width: w, height: notch.height, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .onChange(of: look, initial: true) { _, l in DundunEarState.shared.entered(l) }
    }
}

/// 悬停展开内容：出口 + 活跃会话。只显示项目名 / agent / 状态 / 时间，不显示任何对话内容。
struct NotchDashboard: View {
    @ObservedObject var state: AppState
    @ObservedObject var overrides: NotchOverrides

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                let p = state.presentation
                DundunView(state: overrides.mascot(real: p.mascotState), size: 40)
                    .environment(\.dundunLiteral, overrides.dundun != nil)
                    // 展开过刘海就算看过错误，右耳红点灭
                    .onAppear { DundunEarState.shared.markRead() }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        GuardDot(presentation: p, glow: true)
                        Text(p.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    }
                    Text("出口 \(state.display.egressIP ?? "—")")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(p.ipColor)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("进程").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.35))
                    Text("claude \(state.processes.claude)")
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

/// 展开岛右上角的设置入口（Emily 规格：13pt 常规字重，白 55%，悬停白 90% + 白 10% 圆底 + 转 30°）
struct NotchGearButton: View {
    let action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(hover ? 0.9 : 0.55))
                .rotationEffect(.degrees(hover && !reduceMotion ? 30 : 0))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(pressedScale: 0.92))
        .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { hover = h } }
        .help("设置")
        .accessibilityLabel("设置")
    }
}

struct SessionRow: View {
    let session: AgentSession

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
                        .foregroundStyle(Color.white)
                    Text(session.agent.displayName).font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Spacer(minLength: 6)
                StatePill(running: session.state == .running)
                Text(elapsed(ctx.date))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.6))
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
        .foregroundStyle(running ? Color.green : Color.white.opacity(0.5))
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
    /// nil：常驻卡片，不画进度条
    let countdown: CardCountdown?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                DundunView(state: card.mascotState, size: 38, emote: card.mascotEmote)
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
            if let countdown {
                // 进度条直接从倒计时算，暂停时 TimelineView 停止刷新
                // @see https://developer.apple.com/documentation/swiftui/timelineviewdefaultcontext
                // @see https://developer.apple.com/documentation/swiftui/timelineschedule/animation(minimuminterval:paused:)
                TimelineView(.animation(paused: countdown.isPaused)) { ctx in
                    GeometryReader { g in
                        Capsule().fill(Color.white.opacity(0.1))
                            .overlay(alignment: .leading) {
                                Capsule().fill(card.tint.opacity(0.85))
                                    .frame(width: g.size.width * countdown.fraction(at: ctx.date))
                            }
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
}
