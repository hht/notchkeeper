import AppKit
import AgentCore
import Combine
import NotchCore
import PluginCore

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
    private var inbox: InboxWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClaudeMod.refreshIfInstalled()
        TerminalPlugin.refreshIfInstalled()
        notch = NotchController()
        settings = SettingsWindowController(state: state, notch: notch)
        notch.onOpenSettings = { [weak self] in self?.openSettings() }
        notch.contextMenu = buildMenu()
        NSApp.mainMenu = buildMainMenu()

        state.onAlertAction = { [weak self] in self?.notch.alertAction($0) }
        notch.onAlertDismissed = { [weak self] in self?.state.dismissViolation() }
        state.onAgentEvents = { [weak self] in self?.notch.agentEvents($0, sessions: $1) }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleCardNotification(_:)),
            name: Notification.Name("local.hht.notchkeeper.card"), object: nil,
            suspensionBehavior: .deliverImmediately)

        // 设置变化（含 config.json 热加载）实时生效
        ConfigStore.shared.$config
            .receive(on: RunLoop.main)
            .sink { [weak self] c in
                self?.notch.setHoverEnabled(c.hoverExpand)
                MascotDirector.shared.setFollowsMouse(c.mascotFollowsMouse)
            }
            .store(in: &cancellables)

        MascotDirector.shared.onPausedChange = { [weak self] in self?.notch.setScreenAway($0) }
        MascotDirector.shared.start(notchRect: { [weak self] in self?.notch.anchorRect ?? .zero })
        state.start()
        // 外部插件的卡（docs/ui.md「卡片」）：红卡挂着时排着，由 `CardQueue` 按 `externalPluginID` 管
        let inbox = InboxWatcher { admitted in
            DispatchQueue.main.async { [weak self] in
                for a in admitted { self?.postExternal(a) }
            }
        }
        inbox.start()
        self.inbox = inbox
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

    /// 点了要跳回的那个终端正在眼前（shell 发来的卡）：不弹
    private func postExternal(_ a: InboxGate.Admitted) {
        guard case .terminal(let terminal) = a.card.action, case .tty = terminal.identity else {
            notch.post(a.card, key: a.key, staleAt: a.staleAt)
            return
        }
        Ghostty.isFocused(terminal) { focused in
            DispatchQueue.main.async { [weak self] in
                if focused {
                    Log.write("插件：正看着要跳回的终端，这张卡不弹")
                } else {
                    self?.notch.post(a.card, key: a.key, staleAt: a.staleAt)
                }
            }
        }
    }

    @objc func openSettings() { settings.show() }
    /// 拷贝完整的出口 IP（和刘海、设置页显示的同一个值）
    @objc func copyEgressIP() {
        guard let ip = state.display.egressIP else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ip, forType: .string)
    }
    @objc func quit() { Self.quit(reason: "菜单里点了退出") }

    /// scripts/demo.sh：agent 的卡挂在最近变过状态的会话上，和真卡走同一条路（同样的文案，点了也跳 Ghostty）；alert 当一次新违规；blocks 弹五种内容块
    @objc func handleCardNotification(_ n: Notification) {
        let kind = n.object as? String ?? ""
        if kind == "alert" {
            state.demoAlert()
            Log.write("外部触发：红卡")
            return
        }
        if kind == "blocks" {
            for card in Self.demoBlocks { notch.post(card, key: nil) }
            Log.write("外部触发：内容块")
            return
        }
        // 本机任何进程都能发这个通知：不认识的 kind 不进日志，免得伪造日志行
        let make: (Int32) -> AgentEvent
        switch kind {
        case "done": make = { .turnDone(pid: $0) }
        case "failed": make = { .turnFailed(pid: $0) }
        case "question": make = { .needsYou(.question, pid: $0) }
        case "approval": make = { .needsYou(.approval, pid: $0) }
        default: Log.write("外部触发：不认识的卡"); return
        }
        guard let s = state.sessions.max(by: { $0.stateSince < $1.stateSince }) else {
            Log.write("外部触发：没有 Claude Code 会话，不弹")
            return
        }
        notch.agentEvents([make(s.pid)], sessions: state.sessions)
        Log.write("外部触发：\(kind)")
    }
}

extension AppDelegate {
    /// `demo.sh blocks`：五种内容块各一张，挂在一个假的外部插件上
    /// 每次新造：卡的 id 和真卡一样每张不同
    static var demoBlocks: [Card] {
        let source = Card.Source.plugin(id: "demo", name: "演示", symbol: "sparkles")
        return [
            Card(source: source, title: "npm 跑完了", subtitle: "~/Projects/notchkeeper", value: "2 分 13 秒", outcome: .done,
                 block: .facts([.init(title: "退出码", value: "0"), .init(title: "分支", value: "design/panel"),
                                .init(title: "耗时", value: "2:13"), .init(title: "测试", value: "373 个")]),
                 buttons: [.init(title: "打开访达", action: .activate(bundleID: "com.apple.finder")),
                           .init(title: "看 Swift 文档", action: .open(URL(string: "https://www.swift.org/documentation/")!))]),
            Card(source: source, title: "swift test 失败了", subtitle: "~/Projects/notchkeeper", value: "41 秒", outcome: .failed,
                 block: .log(["✘ Test cardGrowsWithBlock() failed", "Expectation failed: 156 <= 150", "NotchLayoutTests.swift:21"]),
                 // 卡片和按钮都是被拦的 scheme（不同的两个）：点按钮只该记一次 ftp，点空白处只该记一次 http
                 action: .open(URL(string: "http://example.com")!),
                 buttons: [.init(title: "看日志", action: .open(URL(string: "ftp://example.com/log")!))]),
            Card(source: source, title: "部署", subtitle: "app 0.3.1", outcome: .info,
                 block: .checklist([.init(text: "编译", state: .ok), .init(text: "单元测试", state: .failed), .init(text: "上传", state: .pending)])),
            Card(source: source, title: "下载中", subtitle: "Xcode_27.xip", value: "剩 1 分", outcome: .info,
                 block: .progress(0.62, label: "7.4 / 12 GB")),
            Card(source: source, title: "构建说明", outcome: .attention,
                 block: .text(["**3 个测试**没过，最慢的是 `GuardStateWatching`", "_其余_ 370 个都通过了", "[链接不会生效](https://example.com) ![图片也不会](file:///etc/hosts)"])),
        ]
    }
}

/// 没有出口 IP 时「拷贝出口 IP」灰掉
/// @see https://developer.apple.com/documentation/appkit/nsmenuitemvalidation/validatemenuitem(_:)
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copyEgressIP) ? state.display.egressIP != nil : true
    }
}
