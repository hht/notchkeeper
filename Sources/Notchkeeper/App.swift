import AppKit

@main
@MainActor
enum NotchkeeperMain {
    static func main() {
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
    var statusItem: StatusItemController!
    var panel: PanelController!
    var notch: NotchController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController()
        panel = PanelController(state: state, notch: notch)
        statusItem = StatusItemController(menu: buildMenu())
        statusItem.onLeftClick = { [weak self] in
            guard let self, let frame = self.statusItem.buttonScreenFrame else { return }
            self.panel.toggle(anchor: frame)
        }
        statusItem.onMenuWillOpen = { [weak self] in self?.panel.close() }

        state.onStatusChange = { [weak self] old, new in
            guard let self else { return }
            self.statusItem.update(new, animated: true)
            if new == .unhealthy, self.state.autoAlert {
                self.notch.show(.exitAlert(ip: self.state.simulateUnhealthy ? nil : self.state.exitIP))
            } else if old == .unhealthy, new == .healthy {
                self.notch.clearAlert(showRecovered: true)
            }
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleCardNotification(_:)),
            name: Notification.Name("local.hht.notchkeeper.card"), object: nil,
            suspensionBehavior: .deliverImmediately)

        state.start()
        state.addLog("Notchkeeper 启动（M1 预览，仅界面）")
        Log.write("status item created: \(statusItem.item.button != nil); notch screen: \(notch.hasNotch)")
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ key: String = "") {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            m.addItem(i)
        }
        add("打开面板", #selector(openPanel))
        add("立即检查出口", #selector(checkNow))
        m.addItem(.separator())
        add("演示：出口异常卡片（红，常驻）", #selector(demoAlert))
        add("演示：任务完成卡片（绿，4 秒）", #selector(demoDone))
        add("收起刘海卡片", #selector(dismissCard))
        m.addItem(.separator())
        add("退出 Notchkeeper", #selector(quit), "q")
        return m
    }

    @objc func openPanel() {
        if let f = statusItem.buttonScreenFrame, !panel.isOpen { panel.open(anchor: f) }
    }
    @objc func checkNow() { state.refresh() }
    @objc func demoAlert() { notch.show(.exitAlert(ip: state.exitIP)); state.addLog("演示：出口异常卡片", .warn) }
    @objc func demoDone() { notch.show(.taskDone()); state.addLog("演示：任务完成卡片", .ok) }
    @objc func dismissCard() { notch.dismissCurrent() }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func handleCardNotification(_ n: Notification) {
        let kind = (n.object as? String) ?? "done"
        let title = n.userInfo?["title"] as? String
        let detail = n.userInfo?["detail"] as? String
        if kind == "alert" {
            var c = NotchCard.exitAlert(ip: nil)
            if let title { c.title = title }
            if let detail { c.detail = detail }
            notch.show(c)
            state.addLog("外部触发：异常卡片", .warn)
        } else {
            notch.show(.taskDone(title: title ?? "✅ 任务完成", detail: detail ?? "任务已完成"))
            state.addLog("外部触发：完成卡片", .ok)
        }
    }
}
