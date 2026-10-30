import AgentCore
import AppKit
import SwiftUI
import MascotCore
import NotchCore

/// 刘海上的一张卡长什么样、放出来时响什么（docs/ui.md「卡片」）。什么时候放由 `CardQueue` 决定
struct NotchCard: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    /// 边缘流星的颜色（docs/ui.md「卡片」）
    var tint: Color
    /// 卡上的盾盾画这张卡自己的造型
    var look: Look
    /// 放出来那一刻响的系统音效（docs/agent-integration.md「提醒」、docs/egress-guard.md）
    var sound: NSSound.Name
    /// agent 的卡说的是哪个会话：点卡片跳到 Ghostty 里它的窗口（docs/ui.md「卡片」）。守卫的卡是 nil
    var session: Session? = nil

    static func exitAlert(detail: String = GuardPresentation.violatedDetail) -> NotchCard {
        NotchCard(title: GuardPresentation.violatedTitle, detail: detail, tint: Color(cgColor: RGB.red.cg), look: .danger, sound: "Basso")
    }
    static var recovered: NotchCard {
        NotchCard(title: String(localized: "出口已恢复"), detail: String(localized: "流量重新全部走 utun 隧道"), tint: .green,
                  look: .finished, sound: "Glass")
    }
    /// 恢复卡固定 4 秒，不跟「卡片停留」设置走（docs/ui.md「卡片」）
    static let recoveredSeconds: TimeInterval = 4

    /// 回合做完的完成卡；副标题是会话的路径，和会话行一样
    static func turnDone(_ session: Session) -> NotchCard {
        NotchCard(title: String(localized: "Claude Code 做完了"), detail: abbreviated(session.cwd), tint: Self.doneTint, look: .finished,
                  sound: "Glass", session: session)
    }

    /// 回合出错的出错卡：流星用 error 造型身体下端的浅橙（docs/ui.md「卡片」）
    static func turnFailed(_ session: Session) -> NotchCard {
        NotchCard(title: String(localized: "Claude Code 出错了"), detail: abbreviated(session.cwd), tint: Color(cgColor: Look.error.gradient.bottom.cg),
                  look: .error, sound: "Funk", session: session)
    }

    /// 进入需要你介入的介入卡
    static func needsYou(_ need: AgentState.Need, _ session: Session) -> NotchCard {
        switch need {
        case .question:
            return NotchCard(title: String(localized: "Claude Code 在等你回答"), detail: abbreviated(session.cwd), tint: Color(cgColor: RGB.question.cg),
                             look: .question, sound: "Ping", session: session)
        case .approval:
            return NotchCard(title: String(localized: "Claude Code 在等你批准"), detail: abbreviated(session.cwd), tint: Color(cgColor: RGB.approval.cg),
                             look: .approval, sound: "Ping", session: session)
        }
    }

    private static func abbreviated(_ cwd: String) -> String { (cwd as NSString).abbreviatingWithTildeInPath }

    /// 完成卡的流星是低饱和的银白：绿色只给出口正常，Claude 橙在黑底上晕开发红（docs/ui.md「卡片」）
    static let doneTint = Color(white: 0.85)
}

enum NotchMode: Hashable { case closed, card, dashboard }

/// 「状态测试」的覆盖（StateTest.swift）：只在内存里，只经 NotchController 改，重开 App 就没了
@MainActor
final class NotchOverrides: ObservableObject {
    @Published fileprivate(set) var look: Look?
    @Published fileprivate(set) var pin: NotchPin = .auto

    var isReal: Bool { look == nil && pin == .auto }

    /// 盾盾实际显示的造型：强制的优先，否则是真实的守卫状态
    func mascot(real: Look) -> Look { look ?? real }
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
    /// 卡片内容离形状黑底左右边、第一行（盾盾 + 标题 + 副标题）的高度
    static let cardPadding: CGFloat = 18
    static let cardRowHeight: CGFloat = 38
    static let cardBottom: CGFloat = 16
    /// 展开面板和卡片的黑底宽 = iOS 灵动岛展开态宽 408（HIG Live Activities；Mac 菜单栏里的 Live Activity 用同一套尺寸）。
    /// 形状两侧还各有一截往外翻的顶角（`openFlare`），不算黑底
    static let dashWidth: CGFloat = 408
    /// 展开（面板、卡片）时形状顶角往外翻的宽度（NotchShape 的 topRadius）
    static let openFlare: CGFloat = 14
    /// 黑底四周边距 14（HIG Live Activities：Lock Screen 标准边距）
    static let dashMargin: CGFloat = 14
    static let listRadius: CGFloat = 14
    /// 展开（面板、卡片）时形状的底角；收起时 8
    static let openBottomRadius: CGFloat = 28
    /// 会话容器四周留 4
    static let listInset: CGFloat = 4
    static let rowHeight: CGFloat = 38
    static let rowPadding: CGFloat = 10
    static let rowIcon: CGFloat = 24
    /// 行内容离黑底左右边：会话图标左缘、时间右缘、底栏文字左缘、齿轮右缘、右上徽章右缘都在这条线上（docs/ui.md「面板布局」）
    static let contentInset = dashMargin + listInset + rowPadding
    /// 左上的盾盾和右上的徽章：等大（HIG：leading / trailing 大小相近，左右平衡），和刘海下的标题 + IP 两行一样高；
    /// 盾盾身体中心和会话图标中心在同一条竖线上。卡片上还是这只盾盾，也是这么大
    static let dashCorner: CGFloat = 32
    /// 盾盾和徽章上缘离面板顶 8：紧贴刘海两侧，不留「额头」
    static let dashCornerTop: CGFloat = 8
    /// 刘海正下方的状态区（标题 + IP）的高度
    static let dashStatusHeight: CGFloat = 42
    static let footerHeight: CGFloat = 30
    /// 状态区和会话容器之间、底栏和面板底之间
    static let listGap: CGFloat = 10
    static let footerBottom: CGFloat = 4
    /// 会话列表最多露出几行，再多就在列表里滚动（用户 10-29：开的会话多了面板不能无限变长）
    static let maxRows = 5
    /// 小字（时间、底栏、空列表）的白色不透明度：≤17pt 的字对比度至少 4.5:1（HIG Accessibility）
    static let secondaryTextOpacity = 0.5

    /// 收起时刘海两侧各一只耳朵：左耳放盾盾，右耳放状态指示（docs/mascot.md §1）
    static let earWidth: CGFloat = 44
    /// 收起时形状顶角往外翻的宽度（NotchShape 的 topRadius）
    static let closedFlare: CGFloat = 4
    /// 左耳盾盾画布 28×28，左缘在身体外边（形状左边 + 外翻）往里 6pt，离刘海也是 6pt（docs/mascot.md §1）
    static let earCanvas: CGFloat = 28
    static let earCanvasInset: CGFloat = 6
    /// 画布里身体中心的纵坐标；身体中心对齐 notchSize.height / 2，所以 32pt 刘海时画布上缘在 -0.5
    static let earBodyCenterY: CGFloat = 16.5
    /// 左耳盾盾的身体直径（docs/mascot.md §1）：面板里那只缩到这么大
    static let earMascotSize: CGFloat = 20
    /// 右耳指示的中心离形状右边 17.5（docs/mascot.md §1）
    static let earDotInset: CGFloat = 17.5

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
    /// 面板内容从刘海下沿起；没有刘海的屏幕按 32 留出菜单栏
    static func dashTop(_ notch: CGSize) -> CGFloat { max(notch.height, 32) }
    /// 卡片内容的上沿
    static func cardTop(_ notch: CGSize) -> CGFloat { topInset(notch) - 2 }

    static func size(_ mode: NotchMode, notch: CGSize, rows: Int) -> CGSize {
        switch mode {
        case .closed:
            return hasEars(notch) ? CGSize(width: notch.width + 2 * earWidth, height: notch.height) : notch
        case .card: return CGSize(width: dashWidth + 2 * openFlare, height: cardTop(notch) + cardRowHeight + cardBottom)
        case .dashboard:
            let n = min(rows, maxRows)
            let list = (n == 0 ? rowHeight : CGFloat(n) * rowHeight) + 2 * listInset
            return CGSize(width: dashWidth + 2 * openFlare, height: dashTop(notch) + dashStatusHeight + listGap + list + footerHeight + footerBottom)
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
    private var queue = CardQueue<NotchCard>()
    /// 红卡的内容：挂着时台面上放它；副标题跟着守卫状态换
    private var alertCard: NotchCard?
    private var tickWork: DispatchWorkItem?
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
            // 点了卡片的 ×
            guard let self else { return }
            self.apply(self.queue.dismiss(now: Date()))
        }, onOpenCard: { [weak self] session in
            // 点了 agent 卡的其他地方：跳到 Ghostty，这张卡算关掉（docs/ui.md「卡片」）
            guard let self else { return }
            Ghostty.focus(session)
            self.apply(self.queue.dismiss(now: Date()))
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

    /// 临时卡进队列（docs/ui.md「卡片」）。seconds 默认是「卡片停留」设置
    func post(_ card: NotchCard, key: CardQueue<NotchCard>.Key?, seconds: TimeInterval? = nil, lapses: Bool = false) {
        let notice = CardQueue.Notice(card: card, key: key, seconds: seconds ?? ConfigStore.shared.config.cardAutoDismissSeconds,
                                      lapses: lapses)
        apply(queue.post(notice, now: Date()))
    }

    /// AgentCore 的事件变成卡，或撤掉过期的介入卡（docs/ui.md「卡片」2）
    func agentEvents(_ events: [AgentEvent], sessions: [Session]) {
        // 事件和会话列表出自同一次更新：弹卡的会话一定在列表里
        func session(_ pid: Int32) -> Session {
            guard let s = sessions.first(where: { $0.pid == pid }) else { preconditionFailure("事件的会话不在列表里") }
            return s
        }
        for event in events {
            switch event {
            case .turnDone(let pid): post(.turnDone(session(pid)), key: .session(pid))
            case .turnFailed(let pid): post(.turnFailed(session(pid)), key: .session(pid))
            case .needsYou(let need, let pid): post(.needsYou(need, session(pid)), key: .session(pid), lapses: true)
            case .needsYouEnded(let pid): apply(queue.withdraw(.session(pid), now: Date()))
            }
        }
    }

    /// 新的一次违规：红卡插到最前。sound 为 false 时不响（守卫不响应时保留的红卡不再响 Basso）
    func raiseAlert(_ card: NotchCard, sound: Bool) {
        alertCard = card
        let cfg = ConfigStore.shared.config
        apply(queue.raiseAlert(persistent: cfg.alertPersistent, sound: sound, seconds: cfg.cardAutoDismissSeconds, now: Date()))
    }

    /// 台面跟着队列走：换卡或收起、响这张卡的声音、定下一次到点
    private func apply(_ change: CardQueue<NotchCard>.Change) {
        let card: NotchCard?
        switch queue.showing {
        case .notice(let c): card = c
        case .alert:
            guard let a = alertCard else { preconditionFailure("红卡挂着时一定有内容") }
            card = a
        case nil: card = nil
        }
        if let card {
            if card.id != model.card?.id || !model.expanded { present(card) }
            if change.sound, ConfigStore.shared.config.soundEnabled { NSSound(named: card.sound)?.play() }
        } else if model.expanded {
            collapse()
        }
        // 常驻红卡没有倒计时：边缘不流星，只画细边（docs/ui.md「卡片」）
        model.countdown = queue.showing == .alert(persistent: true) ? nil : queue.countdown
        scheduleTick()
        if change.alertDismissed {
            alertCard = nil
            onAlertDismissed()
        }
    }

    private func present(_ card: NotchCard) {
        orderFront()
        if model.mode != .closed {
            withAnimation(NotchSpring.notchOpen) { model.card = card; model.expanded = true }
        } else {
            model.card = card
            withAnimation(NotchSpring.notchOpen) { model.expanded = true }
        }
        updateMouseCapture()
        // 卡片弹到鼠标底下：当作停在卡上，先不倒计时
        if shapeRect.contains(NSEvent.mouseLocation) { _ = queue.setHovering(true, now: Date()) }
    }

    /// 熄屏或锁屏：台面上的卡停住，新卡不放、不响；回来接着放
    func setScreenAway(_ away: Bool) {
        apply(queue.setAway(away, now: Date()))
    }

    private func scheduleTick() {
        tickWork?.cancel()
        guard let at = queue.deadline(now: Date()) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.apply(self.queue.tick(now: Date()))
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
    }

    /// 鼠标在卡片上：倒计时暂停；移开：从剩下的时间继续
    func setCardHover(_ over: Bool) {
        guard over != queue.hovering else { return }
        apply(queue.setHovering(over, now: Date()))
    }

    /// 每读一次守卫状态调用一次
    func guardChanged(to new: GuardPresentation) {
        if new.clearsAlert {
            apply(queue.clearAlert(now: Date()))
            alertCard = nil
            // 只有弹过红卡的那次违规回到 healthy 才弹恢复卡：中间断网、守卫不响应、用户关掉红卡都算同一次
            if violationAlerted {
                violationAlerted = false
                post(.recovered, key: .recovered, seconds: NotchCard.recoveredSeconds)
            }
            return
        }
        guard let alert = new.alert, ConfigStore.shared.config.autoAlert else { return }
        violationAlerted = true
        if var shown = alertCard {
            // 红卡已经挂着：只换副标题，不重弹、不重响
            guard shown.detail != alert.detail else { return }
            shown.detail = alert.detail
            alertCard = shown
            if model.card?.id == shown.id { model.card = shown }
        } else {
            raiseAlert(.exitAlert(detail: alert.detail), sound: alert.sounds)
        }
    }

    private func collapse() {
        withAnimation(model.hovering ? NotchSpring.page : NotchSpring.notchClose) { model.expanded = false }
        updateMouseCapture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.model.expanded { self.model.card = nil }
        }
    }

    // MARK: 状态测试（只在内存里，见 StateTest.swift）

    var mode: NotchMode { model.mode }

    /// 强制盾盾显示某个状态；nil 回到真实状态。只换盾盾的样子：不调 guardChanged、不碰 AppState，
    /// 所以强制「危险」不弹红卡、不响，也不动「这次违规已关掉」的记录
    func force(_ l: Look?) {
        guard overrides.look != l else { return }
        overrides.look = l
    }

    /// 固定展开 / 固定收起 / 自动。换的时候清掉悬停，回到自动时按当前鼠标重新判断
    func setPin(_ p: NotchPin) {
        guard overrides.pin != p else { return }
        hoverIntent?.cancel(); hoverIntent = nil
        leaveWork?.cancel(); leaveWork = nil
        let opening = p == .open && model.mode == .closed
        if opening { orderFront() }
        withAnimation(opening ? NotchSpring.notchOpen : NotchSpring.notchClose) {
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

    /// 刘海本体在屏幕上的位置（盾盾 MascotDirector 贴着它走）
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
        MascotDirector.shared.mouseMoved(to: p)
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
            orderFront()
            withAnimation(NotchSpring.notchOpen) { model.hovering = true }
            updateMouseCapture()
        } else {
            withAnimation(NotchSpring.notchClose) { model.hovering = false }
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

    /// 顶角外翻和底角实际用的半径：太小的矩形里压到放得下
    private func radii(in r: CGRect) -> (top: CGFloat, bottom: CGFloat) {
        let t = min(topRadius, r.width / 4, r.height / 2)
        return (t, max(0, min(bottomRadius, r.height - t, (r.width - 2 * t) / 2)))
    }

    /// 左半边：从左上外翻的顶端，沿左边、左下角走到底边中点。卡片边缘的流星沿它走，右边一颗走它的镜像
    func leftHalf(in r: CGRect) -> Path {
        var p = Path()
        guard r.width > 0, r.height > 0 else { return p }
        let (t, b) = radii(in: r)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard r.width > 0, r.height > 0 else { return p }
        let (t, b) = radii(in: r)
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
    let onOpenCard: (Session) -> Void
    let onSettings: () -> Void

    @ObservedObject private var director = MascotDirector.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mode = model.mode
        let size = NotchLayout.size(mode, notch: model.notchSize, rows: state.sessions.count)
        let open = mode != .closed
        let t: CGFloat = open ? NotchLayout.openFlare : NotchLayout.closedFlare
        let b: CGFloat = open ? NotchLayout.openBottomRadius : 8
        let shape = NotchShape(topRadius: t, bottomRadius: b)

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) { content(mode, inset: t) }
                .overlay(alignment: .topLeading) { corners(mode, size: size, flare: t) }
                .overlay {
                    // 面板是一条很淡的白线；卡片的边缘是流星，画在裁切外面（见下）
                    if mode != .card {
                        NotchShape(topRadius: t, bottomRadius: b, closed: false)
                            .stroke(Color.white.opacity(open ? 0.08 : 0), lineWidth: 1)
                    }
                }
                .clipShape(shape)
                .overlay {
                    // 卡片边缘的流星就是倒计时（docs/ui.md「卡片」）：压在边缘正中，柔光往里外两边晕开，所以放在裁切外面
                    if mode == .card, let card = model.card {
                        // 圆角是跟着弹簧变的，流星按最终外形画：等形状快长好再淡入，免得拐角错开；
                        // 一开始收起就立刻撤掉，不淡出，免得光团停在原处、跟不上缩回刘海的形状（灵动岛收起时也是内容先撤）
                        CardEdge(topRadius: t, bottomRadius: b, tint: card.tint, countdown: model.countdown)
                            // 盖满整张卡，点击交给下面的 × 和卡片
                            .allowsHitTesting(false)
                            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.25).delay(CardEdgeView.appearDelay)),
                                                    removal: .opacity.animation(.linear(duration: 0))))
                    }
                }
                .shadow(color: .black.opacity(open ? 0.3 : 0), radius: 18, y: 6)
                .animation(NotchSpring.page, value: state.sessions.count)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 盾盾和右边的指示：收起、面板、卡片里是**同一个视图**，只按形态改位置和缩放，
    /// 跟着形状的同一个弹簧走（HIG Live Activities：「Maintain the relative placement of elements」，
    /// 展开态是收起态放大，元素不移除再进场）。布局尺寸固定、只动 position / scaleEffect，
    /// 嵌进来的 Core Animation 视图在 macOS 14 上也会被逐帧插值（10-29 实测）。
    /// 盾盾在左耳 → 面板左上 → 卡片左侧之间飞，到卡片上换成这张卡的造型、告示画回来（docs/ui.md「卡片」7）；
    /// 右边的一组在卡片形态时淡出，透明时停掉动画。
    /// 减弱动态效果时不飞：换形态就换一个新视图，旧的原地淡出、新的在新位置淡入（docs/mascot.md §5）
    @ViewBuilder
    private func corners(_ mode: NotchMode, size: CGSize, flare: CGFloat) -> some View {
        if NotchLayout.hasEars(model.notchSize) || mode != .closed {
            let open = mode == .dashboard
            let notch = model.notchSize
            let c = NotchLayout.dashCorner
            let top = NotchLayout.dashCornerTop + c / 2
            let right = size.width - flare - NotchLayout.contentInset - c / 2
            let card = mode == .card ? model.card : nil
            let look = card?.look ?? overrides.mascot(real: state.look)
            // 右边跟着左边实际画的造型走（犯困时左耳睡着，右耳就不亮）
            let shown = overrides.look != nil ? look : look.shown(drowsy: director.drowsy)
            let mascotAt: CGPoint = switch mode {
            case .closed: NotchLayout.ears(notch: notch, flare: flare).bodyCenter
            case .dashboard: CGPoint(x: flare + NotchLayout.contentInset + NotchLayout.rowIcon / 2, y: top)
            case .card: CGPoint(x: flare + NotchLayout.cardPadding + c / 2, y: NotchLayout.cardTop(notch) + NotchLayout.cardRowHeight / 2)
            }
            ZStack(alignment: .topLeading) {
                // 告示（sign）在右边，盾盾只管表情；卡片上没有右边，画回来
                MascotView(look: look, size: c, hidesSigns: card == nil)
                    .environment(\.mascotLiteral, overrides.look != nil || card != nil)
                    .scaleEffect(mode == .closed ? NotchLayout.earMascotSize / c : 1)
                    .position(mascotAt)
                    .id(reduceMotion ? mode : .closed)
                    .transition(.opacity)
                ZStack {
                    EarIndicatorView(indicator: .for(shown, probeFailed: state.presentation.probeFailed && overrides.look == nil),
                                     size: CGSize(width: NotchLayout.earWidth, height: notch.height),
                                     // 外面已经把这一组的中心放在离右边 earDotInset 处，这里以自身中心为准，不再偏一次
                                     center: CGPoint(x: NotchLayout.earWidth / 2, y: notch.height / 2),
                                     playing: mode == .closed)
                        .frame(width: NotchLayout.earWidth, height: notch.height)
                        .opacity(mode == .closed ? 1 : 0)
                    GuardBadge(presentation: state.presentation, size: c)
                        .opacity(open ? 1 : 0)
                        .scaleEffect(open || reduceMotion ? 1 : 0.4)
                }
                .frame(width: c, height: c)
                .position(open ? CGPoint(x: right, y: top)
                               : CGPoint(x: size.width - NotchLayout.earDotInset, y: notch.height / 2))
                .id(reduceMotion && open)
                .transition(.opacity)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func content(_ mode: NotchMode, inset: CGFloat) -> some View {
        let top = NotchLayout.cardTop(model.notchSize)
        switch mode {
        case .card:
            if let card = model.card {
                NotchCardView(card: card, onDismiss: onDismiss, onOpen: card.session.map { s in { onOpenCard(s) } })
                    .id(card.id)
                    .padding(.top, top)
                    .padding(.horizontal, inset)
                    .transition(Self.contentTransition(reduceMotion))
            }
        case .dashboard:
            NotchDashboard(state: state, onSettings: onSettings)
                .frame(width: NotchLayout.dashWidth)
                .padding(.top, NotchLayout.dashTop(model.notchSize))
                .transition(Self.contentTransition(reduceMotion))
        case .closed:
            EmptyView()
        }
    }

    /// 内容在形状长开之后进场：模糊变清晰 + 从 0.96 放大 + 淡入，稍等 0.06s 让形状先走（DynamicNotchKit 的 blur + scale + opacity，
    /// boring.notch 的 `.smooth(0.35)`）；退场只淡出、更快（CLAUDE.md：进场稍慢、退场稍快）。减弱动态效果只淡入淡出
    static func contentTransition(_ reduceMotion: Bool) -> AnyTransition {
        let fadeOut = AnyTransition.opacity.animation(.easeIn(duration: 0.1))
        if reduceMotion { return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2)), removal: fadeOut) }
        return .asymmetric(
            insertion: .modifier(active: Unfocus(amount: 1), identity: Unfocus(amount: 0))
                .animation(.smooth(duration: 0.35).delay(0.06)),
            removal: fadeOut)
    }
}

/// 进场用：模糊 8pt、缩到 0.96（锚在顶部）、透明
private struct Unfocus: ViewModifier {
    let amount: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: 8 * amount)
            .scaleEffect(1 - 0.04 * amount, anchor: .top)
            .opacity(1 - amount)
    }
}

/// 右上的出口状态徽章：和左上的盾盾等大。颜色 + 图标 + 文案三者一起表达状态（CLAUDE.md「状态 = 颜色 + 图标 + 文案」），
/// 文案在刘海下方的标题
struct GuardBadge: View {
    let presentation: GuardPresentation
    let size: CGFloat

    private var symbol: String {
        switch presentation.tone {
        case .healthy: return "checkmark.shield.fill"
        case .mismatch: return "exclamationmark.triangle.fill"
        case .violated: return "xmark.shield.fill"
        case .unknown:
            switch presentation.look {
            case .offline: return "wifi.slash"
            case .stale: return "hourglass"
            default: return "questionmark"
            }
        }
    }

    var body: some View {
        let c = presentation.color
        Circle()
            .fill(c.opacity(0.16))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(c))
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(presentation.title)
    }
}

/// 悬停展开的内容：刘海正下方的出口状态、会话列表、底栏（检查时间 + 设置）。左上的盾盾和右上的徽章在 NotchRoot。
/// 只显示路径 / 状态 / 时间，不显示任何对话内容。
struct NotchDashboard: View {
    @ObservedObject var state: AppState
    let onSettings: () -> Void

    var body: some View {
        let p = state.presentation
        let m = NotchLayout.dashMargin
        VStack(spacing: 0) {
            // 刘海正下方（灵动岛的 center 区）：标题用中等以上字重（HIG Live Activities），圆体配圆润的盾盾（HIG Typography）
            VStack(spacing: 2) {
                Text(p.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(state.display.egressIP ?? "—")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(p.ipColor)
            }
            // 两侧让开盾盾和徽章
            .padding(.horizontal, NotchLayout.contentInset + NotchLayout.rowIcon / 2 + NotchLayout.dashCorner / 2 + 6)
            .frame(height: NotchLayout.dashStatusHeight)

            SessionList(sessions: state.sessions)
                .padding(.top, NotchLayout.listGap)
                .padding(.horizontal, m)

            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(checkedText)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(NotchLayout.secondaryTextOpacity))
                }
                Spacer()
                NotchGearButton(action: onSettings)
                    .padding(.trailing, -5) // 齿轮的点击框 24、图形约 14：让图形右缘落在右对齐线上
            }
            .padding(.horizontal, NotchLayout.contentInset)
            .frame(height: NotchLayout.footerHeight)
        }
    }

    /// 守卫数据新不新鲜：「未知」也要看得出来（CLAUDE.md 准则 5）
    private var checkedText: String {
        guard let at = state.display.checkedAt else { return String(localized: "出口还没检查过") }
        return String(localized: "出口检查于 \(at.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
    }
}

/// 会话列表：内嵌的圆角容器（HIG Live Activities：用内嵌圆角容器分隔内容）。最多露出 maxRows 行，多的在里面滚
struct SessionList: View {
    let sessions: [Session]

    var body: some View {
        Group {
            if sessions.isEmpty {
                Text("没有看到正在运行的 Claude Code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchLayout.secondaryTextOpacity))
                    .frame(maxWidth: .infinity)
                    .frame(height: NotchLayout.rowHeight)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(sessions, id: \.pid) { SessionRow(session: $0) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .environment(\.colorScheme, .dark) // 系统亮色、滚动条设成「始终」时，别在黑底上画浅色槽
                .frame(height: CGFloat(min(sessions.count, NotchLayout.maxRows)) * NotchLayout.rowHeight)
            }
        }
        .padding(NotchLayout.listInset)
        .background(RoundedRectangle(cornerRadius: NotchLayout.listRadius, style: .continuous).fill(.white.opacity(0.06)))
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

/// 一行会话：agent 的标志、路径、状态指示、状态变化距今。已停止的标志和路径变暗，时间不暗（保住对比度）。
/// 状态只用指示表达，不写字（用户 10-29）；状态名留给悬停提示和旁白
struct SessionRow: View {
    let session: Session
    @State private var hover = false

    /// 工作中和右耳一样是三蓝点；需要你介入用盾盾这两个造型自己的装饰（带 ? 的气泡、举起的手），比一个点好认；已停止不画
    private var indicator: EarIndicator {
        switch session.state {
        case .working: return .dots
        case .needsYou(.question): return .decoration(.question)
        case .needsYou(.approval): return .decoration(.approval)
        case .stopped: return .none
        }
    }

    private var stateTitle: String {
        switch session.state {
        case .working: return String(localized: "工作中")
        case .needsYou(.question): return String(localized: "等你回答")
        case .needsYou(.approval): return String(localized: "等你批准")
        case .stopped: return String(localized: "已停止")
        }
    }

    var body: some View {
        let path = (session.cwd as NSString).abbreviatingWithTildeInPath
        let dimmed = session.state == .stopped ? 0.55 : 1
        // 点一行跳到 Ghostty 里这个会话的窗口（docs/ui.md「面板布局」）
        Button { Ghostty.focus(session) } label: { row(path: path, dimmed: dimmed) }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover ? 0.06 : 0)))
            .onHover { hover = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityValue(stateTitle)
            .accessibilityHint("在 Ghostty 中打开")
    }

    private func row(path: String, dimmed: Double) -> some View {
        HStack(spacing: 10) {
            // 是哪个 agent 只靠行首的厂商标志表示（用户 10-29）
            ClaudeMark()
                .fill(ClaudeMark.color)
                .frame(width: 15, height: 15)
                .frame(width: NotchLayout.rowIcon, height: NotchLayout.rowIcon)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.08)))
                .opacity(dimmed)
                .help("Claude Code")
                .accessibilityLabel("Claude Code")
            // 太长从前面截成「…」，留住最后几段（用户 10-29）
            Text(path)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.head)
                .opacity(dimmed)
                .help(path)
            Spacer(minLength: 8)
            EarIndicatorView(indicator: indicator, size: CGSize(width: 20, height: 20), center: CGPoint(x: 13, y: 10))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .help(stateTitle)
            // TimelineView 每秒重算一次 body，按当时的现在算
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(session.stateSince.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(NotchLayout.secondaryTextOpacity))
            }
            .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, NotchLayout.rowPadding)
        .frame(height: NotchLayout.rowHeight)
        .contentShape(Rectangle())
    }
}

struct NotchCardView: View {
    let card: NotchCard
    let onDismiss: () -> Void
    /// nil：点了不做事（守卫的卡）
    let onOpen: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // 盾盾的位置：NotchRoot 里那只飞过来（docs/ui.md「卡片」7）
            Color.clear.frame(width: NotchLayout.dashCorner, height: NotchLayout.dashCorner)
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
        .frame(height: NotchLayout.cardRowHeight)
        .padding(.horizontal, NotchLayout.cardPadding)
        // × 是按钮，自己先接住点击；其余地方点了跳到 Ghostty
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
    }
}
