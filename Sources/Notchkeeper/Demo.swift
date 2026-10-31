#if DEBUG
import AppKit
import AgentCore
import NotchCore

/// `scripts/demo.sh` 弹卡。分布式通知本机任何进程都能发，所以只在 DEBUG 构建（`CONFIG=debug scripts/run.sh`）里听
extension AppDelegate {
    func listenForDemo() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleCardNotification(_:)),
            name: Notification.Name("local.hht.notchkeeper.card"), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

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
#endif
