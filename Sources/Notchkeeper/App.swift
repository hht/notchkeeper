import AppKit
import Combine

@main
@MainActor
enum NotchkeeperMain {
    static func main() {
        var args = CommandLine.arguments
        // 自检用的抢锁子进程：只碰给定的锁文件，不写别的
        if let i = args.firstIndex(of: "--instance-probe"), args.count > i + 1 {
            switch SingleInstance.lock(at: URL(fileURLWithPath: args[i + 1])) {
            case .acquired:
                guard args.contains("--hold") else { exit(0) }
                print("held"); fflush(stdout)
                var byte: UInt8 = 0
                _ = read(0, &byte, 1)   // 父进程关管道或退出时返回
                exit(0)
            case .heldByOther: exit(3)
            case .unavailable: exit(2)
            }
        }
        #if DEBUG
        // 换 HOME 之前先把输出目录解析成绝对路径，否则 ~ 会指到临时 HOME
        if let i = args.firstIndex(of: "--mascot-demo") {
            let dir = URL(fileURLWithPath: ((args.count > i + 1 ? args[i + 1] : "mascot-demo") as NSString).expandingTildeInPath).path
            if args.count > i + 1 { args[i + 1] = dir } else { args.append(dir) }
        }
        #endif
        if args.contains("--selftest") || args.contains("--mascot-demo") {
            TestHome.enter(arguments: args)
        }
        if args.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        #if DEBUG
        if let i = args.firstIndex(of: "--mascot-demo") {
            exit(MascotDemo.run(outDir: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
        }
        #endif
        if let i = args.firstIndex(of: "--login-item") {
            let op = args.count > i + 1 ? args[i + 1] : "status"
            if op == "enable" || op == "disable" {
                if let err = LoginItem.set(op == "enable") { print("error: \(err)") }
            }
            print("login item: \(LoginItem.statusText)")
            exit(0)
        }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController()
        settings = SettingsWindowController(state: state)
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
            }
            .store(in: &cancellables)

        DundunDirector.shared.start(notchRect: { [weak self] in self?.notch.anchorRect ?? .zero })
        state.start()
        Log.write("Notchkeeper 启动")
        Log.write("notch screen: \(notch.hasNotch)")
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
    @objc func quit() { NSApp.terminate(nil) }

    /// scripts/demo.sh done|alert ["标题"] ["详情"]
    @objc func handleCardNotification(_ n: Notification) {
        let card = Self.demoCard(kind: n.object as? String, title: n.userInfo?["title"] as? String,
                                 detail: n.userInfo?["detail"] as? String)
        notch.show(card)
        Log.write(card.kind == .alert ? "外部触发：异常卡片" : "外部触发：完成卡片")
    }

    static func demoCard(kind: String?, title: String?, detail: String?) -> NotchCard {
        guard kind == "alert" else { return .taskDone(title: title ?? "✅ 任务完成", detail: detail ?? "任务已完成") }
        var c = NotchCard.exitAlert()
        if let title { c.title = title }
        if let detail { c.detail = detail }
        return c
    }
}

/// 没有出口 IP 时「拷贝出口 IP」灰掉
/// @see https://developer.apple.com/documentation/appkit/nsmenuitemvalidation/validatemenuitem(_:)
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copyEgressIP) ? state.display.egressIP != nil : true
    }
}
