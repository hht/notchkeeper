import Foundation
import Testing
import NotchCore
import PluginCore
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
