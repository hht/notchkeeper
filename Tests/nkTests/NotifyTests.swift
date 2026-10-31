import Foundation
import Testing
import NotchCore
@testable import PluginCore
@testable import nk

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let id = UUID()

private func notify(_ args: [String]) throws -> Message {
    try Message.parse(Notify.message(args, id: id, now: t0))
}

@Suite struct NotifyArguments {
    @Test func minimal() throws {
        let m = try notify(["--plugin", "terminal", "--title", "sleep 跑完了"])
        #expect(m.plugin == "terminal" && m.title == "sleep 跑完了" && m.id == id && m.at == t0)
        #expect(m.outcome == .info)
        #expect(m.subtitle == nil && m.value == nil && m.group == nil && m.block == nil && m.action == nil)
    }

    @Test func allOptions() throws {
        let m = try notify(["--plugin", "terminal", "--title", "sleep 失败了", "--subtitle", "~/x", "--value", "12 秒", "--outcome", "failed",
                            "--group", "tty:/dev/ttys003", "--fact", "退出码=1", "--fact", "目录=~/a=b", "--open", "https://example.com/x"])
        #expect(m.subtitle == "~/x" && m.value == "12 秒" && m.outcome == .failed && m.group == "tty:/dev/ttys003")
        #expect(m.block == .facts([.init(title: "退出码", value: "1"), .init(title: "目录", value: "~/a=b")]))
        #expect(m.action == .open(URL(string: "https://example.com/x")!))
    }

    /// zsh 插件传 `--tty $TTY --pid $$ --cwd $PWD`：点卡片跳回这个终端
    @Test func focusTerminal() throws {
        let m = try notify(["--plugin", "terminal", "--title", "x", "--tty", "/dev/ttys003", "--pid", "4242", "--cwd", "/Users/x"])
        #expect(m.action == .focusTerminal(tty: "/dev/ttys003", pid: 4242, cwd: "/Users/x"))
    }

    @Test(arguments: [["--tty", "/dev/ttys003"], ["--tty", "/dev/ttys003", "--pid", "abc", "--cwd", "/"], ["--pid", "4242", "--cwd", "/"],
                      ["--tty", "/dev/ttys003", "--pid", "4242", "--cwd", "/", "--open", "https://example.com"]])
    func incompleteTerminalRejected(_ extra: [String]) {
        #expect(throws: NotifyError.self) { try Notify.message(["--plugin", "terminal", "--title", "x"] + extra, id: id, now: t0) }
    }

    @Test(arguments: [[], ["--plugin", "terminal"], ["--title", "x"], ["--plugin", "terminal", "--title"],
                      ["--plugin", "terminal", "--title", "x", "--fact", "没有等号"], ["--plugin", "terminal", "--title", "x", "--color", "red"]])
    func usageErrors(_ args: [String]) {
        #expect(throws: NotifyError.self) { try Notify.message(args, id: id, now: t0) }
    }

    /// 消息本身不合规（插件 id、outcome、URL）在写盘之前就报错，和 App 读的是同一套规则
    @Test(arguments: [["--plugin", "Terminal", "--title", "x"], ["--plugin", "terminal", "--title", "x", "--outcome", "violation"],
                      ["--plugin", "terminal", "--title", "x", "--open", "no scheme"]])
    func invalidMessages(_ args: [String]) {
        #expect(throws: NotifyError.self) { try Notify.message(args, id: id, now: t0) }
    }
}

/// `nk activity start|update|end --id <活动> …`：其余参数和 notify 一样，多一个 `--progress`、`--alert`
@Suite struct ActivityArguments {
    private func activity(_ event: String, _ extra: [String]) throws -> Message {
        try Message.parse(Notify.message(extra + ["--plugin", "dl", "--title", "下载中"], id: id, now: t0, activity: event))
    }

    @Test func update() throws {
        let m = try activity("update", ["--id", "xcode", "--progress", "0.62", "--label", "7.4 / 12 GB", "--value", "剩 1 分"])
        #expect(m.activity == .init(id: "xcode", event: .update, alert: false))
        #expect(m.block == .progress(0.62, label: "7.4 / 12 GB") && m.value == "剩 1 分")
    }

    @Test func alertFlag() throws {
        #expect(try activity("start", ["--id", "x", "--alert"]).activity == .init(id: "x", event: .start, alert: true))
    }

    @Test(arguments: [["--progress", "0.5"], ["--id", "x", "--progress", "abc"], ["--id", "x", "--progress", "0.5", "--fact", "a=b"],
                      ["--id", "x", "--group", "g"]])
    func usageErrors(_ extra: [String]) {
        #expect(throws: NotifyError.self) { try activity("update", extra) }
    }

    @Test func badEvent() {
        #expect(throws: NotifyError.self) { try activity("stop", ["--id", "x"]) }
    }

    /// 普通卡不收活动的参数
    @Test(arguments: [["--id", "x"], ["--alert"]])
    func notifyRejectsActivityOptions(_ extra: [String]) {
        #expect(throws: NotifyError.self) { try Notify.message(["--plugin", "dl", "--title", "x"] + extra, id: id, now: t0) }
    }
}

/// 发出时刻带毫秒：脚本一秒里连发 start、end，App 才分得清先后
@Suite struct NotifyTimestamp {
    @Test func fractionalSeconds() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000.25)
        let m = try Message.parse(Notify.message(["--plugin", "dl", "--title", "x"], id: id, now: now))
        #expect(m.at == now)
    }
}
