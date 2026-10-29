import AppKit
import Combine

@main
@MainActor
enum NotchkeeperMain {
    static func main() {
        // 在创建 NSApplication 之前：第二个实例什么都不画就退出
        guard SingleInstance.claim() else { exit(0) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState.shared
    var settings: SettingsWindowController!
    var notch: NotchController!
    private var cancellables = Set<AnyCancellable>()
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController()
        settings = SettingsWindowController(state: state, notch: notch)
        notch.onOpenSettings = { [weak self] in self?.openSettings() }
        notch.contextMenu = buildMenu()
        NSApp.mainMenu = buildMainMenu()

        state.onPresentation = { [weak self] in self?.notch.guardChanged(to: $0) }
        notch.onAlertDismissed = { [weak self] in self?.state.dismissViolation() }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleCardNotification(_:)),
            name: Notification.Name("local.hht.notchkeeper.card"), object: nil,
            suspensionBehavior: .deliverImmediately)

        // 设置变化（含 config.json 热加载）实时生效
        ConfigStore.shared.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] c in
                self?.notch.setHoverEnabled(c.hoverExpand)
                DundunDirector.shared.setFollowsMouse(c.dundunFollowsMouse)
            }
            .store(in: &cancellables)

        DundunDirector.shared.start(notchRect: { [weak self] in self?.notch.anchorRect ?? .zero })
        state.start()
        watchSIGTERM()
        Log.write("Notchkeeper 启动")
        Log.write("notch screen: \(notch.hasNotch)")
    }

    /// 退出前记一行日志（带原因），再取消守卫订阅，目录监听和定时器跟着关掉
    /// @see https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationwillterminate(_:)
    func applicationWillTerminate(_ notification: Notification) {
        Log.write("Notchkeeper 退出（\(Self.quitReason ?? "原因不明：有人调了 terminate")）")
        state.stopWatchingGuard()
    }

    /// 退出原因。本 App 自己发起的退出（菜单、设置页、SIGTERM）先记下再 terminate；
    /// 注销、关机或别的 App 让它退出时，AppKit 收到 quit Apple 事件后也走 terminate，在这里认出来。
    /// 崩溃和 SIGKILL 不经过 terminate，记不到。
    private static var quitReason: String?

    /// 自己发起的退出都走这里，日志里才分得清是谁让它退的
    /// @see https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:)
    static func quit(reason: String) {
        if quitReason == nil { quitReason = reason }
        NSApp.terminate(nil)
    }

    /// terminate 之后、真正退出之前调用；此时正在处理的 Apple 事件若是 quit（'aevt'/'quit'），就是系统或别的 App 要它退出
    /// @see https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)
    /// @see https://developer.apple.com/documentation/foundation/nsappleeventmanager/currentappleevent
    /// @see https://developer.apple.com/documentation/foundation/nsappleeventdescriptor/eventid
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.quitReason == nil, let e = NSAppleEventManager.shared().currentAppleEvent,
           e.eventClass == AEEventClass(kCoreEventClass), e.eventID == AEEventID(kAEQuitApplication) {
            Self.quitReason = "收到 quit Apple 事件：注销、关机或别的 App 要求退出"
        }
        return .terminateNow
    }

    /// kill / launchctl 发来的 SIGTERM 默认直接杀进程，applicationWillTerminate 不会跑。
    /// 先把默认动作设成忽略，再用 dispatch source 在主队列接住：记日志，然后正常 terminate。
    /// @see https://developer.apple.com/library/archive/documentation/General/Conceptual/ConcurrencyProgrammingGuide/GCDWorkQueues/GCDWorkQueues.html
    /// @see https://developer.apple.com/documentation/dispatch/dispatchsource/makesignalsource(signal:queue:)
    /// @see https://developer.apple.com/documentation/dispatch/dispatchobject/activate()
    private func watchSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Log.write("收到 SIGTERM，正常退出")
                Self.quit(reason: "SIGTERM")
            }
        }
        source.activate()
        sigterm = source
    }

    /// 再次打开 App（Finder 双击、`open -a`）时没有菜单栏图标可点，直接打开设置
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    /// 刘海右键菜单
    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("设置…", #selector(openSettings)))
        m.addItem(item("拷贝出口 IP", #selector(copyEgressIP)))
        m.addItem(.separator())
        m.addItem(item("退出 Notchkeeper", #selector(quit)))
        return m
    }

    /// 主菜单不显示（accessory App），只为 App 激活后 ⌘, / ⌘Q / ⌘W 和输入框的编辑快捷键生效
    func buildMainMenu() -> NSMenu {
        let app = NSMenu()
        app.addItem(item("设置…", #selector(openSettings), ","))
        app.addItem(.separator())
        app.addItem(item("退出 Notchkeeper", #selector(quit), "q"))

        // target 为 nil：沿响应链交给当前窗口 / 输入框
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        for sub in [app, edit, window] {
            let root = NSMenuItem()
            root.submenu = sub
            main.addItem(root)
        }
        return main
    }

    private func item(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc func openSettings() { settings.show() }
    /// 拷贝完整的出口 IP（和刘海、设置页显示的同一个值）
    @objc func copyEgressIP() {
        guard let ip = state.display.egressIP else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }
    @objc func quit() { Self.quit(reason: "菜单里点了退出") }

    /// scripts/demo.sh done|alert ["标题"] ["详情"]
    @objc func handleCardNotification(_ n: Notification) {
        let title = n.userInfo?["title"] as? String, detail = n.userInfo?["detail"] as? String
        var card: NotchCard
        if n.object as? String == "alert" {
            card = .exitAlert()
            if let title { card.title = title }
            if let detail { card.detail = detail }
        } else {
            card = .taskDone(title: title ?? "✅ 任务完成", detail: detail ?? "任务已完成")
        }
        notch.show(card)
        Log.write(card.kind == .alert ? "外部触发：异常卡片" : "外部触发：完成卡片")
    }
}

/// 没有出口 IP 时「拷贝出口 IP」灰掉
/// @see https://developer.apple.com/documentation/appkit/nsmenuitemvalidation/validatemenuitem(_:)
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copyEgressIP) ? state.display.egressIP != nil : true
    }
}
