import Foundation
import Testing
import NotchCore
@testable import PluginCore

private let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

private func parse(_ json: String) throws -> Message { try Message.parse(Data(json.utf8)) }

/// 只有必填字段的消息，`extra` 拼在后面
private func minimal(_ extra: String = "") -> String {
    #"{"v":1,"plugin":"terminal","id":"\#(id)","at":"2026-10-31T08:00:00Z","title":"npm 跑完了","outcome":"done"\#(extra)}"#
}

@Suite struct MessageParsing {
    @Test func minimalMessage() throws {
        let m = try parse(minimal())
        #expect(m.plugin == "terminal")
        #expect(m.id == UUID(uuidString: id))
        #expect(m.at == Date(timeIntervalSince1970: 1_793_433_600))
        #expect(m.title == "npm 跑完了")
        #expect(m.outcome == .done)
        #expect(m.subtitle == nil && m.value == nil && m.group == nil && m.block == nil && m.action == nil && m.buttons.isEmpty && m.staleAt == nil)
    }
}

@Suite struct MessageRejection {
    @Test(arguments: [("done", Card.Outcome.done), ("failed", .failed), ("attention", .attention), ("info", .info)])
    func outcomes(_ raw: String, _ outcome: Card.Outcome) throws {
        #expect(try parse(minimal().replacingOccurrences(of: #""outcome":"done""#, with: #""outcome":"\#(raw)""#)).outcome == outcome)
    }

    /// 红色、绿色属于出口守卫：外部消息写了也不降级成别的，直接不认
    @Test(arguments: ["violation", "recovered", "question", "approval", "DONE", ""])
    func otherOutcomesRejected(_ raw: String) {
        #expect(throws: MessageError.unknownOutcome) {
            try parse(minimal().replacingOccurrences(of: #""outcome":"done""#, with: #""outcome":"\#(raw)""#))
        }
    }

    /// 缺的字段用默认值：outcome 是 info（和 `pipctl` 一致）
    @Test func missingOutcomeIsInfo() throws {
        #expect(try parse(minimal().replacingOccurrences(of: #","outcome":"done""#, with: "")).outcome == .info)
    }

    @Test func otherVersionRejected() {
        #expect(throws: MessageError.unsupportedVersion) { try parse(minimal().replacingOccurrences(of: #""v":1"#, with: #""v":2"#)) }
    }

    @Test(arguments: ["{", "[]", #"{"v":1}"#, minimal().replacingOccurrences(of: id, with: "not-a-uuid"),
                      minimal().replacingOccurrences(of: "2026-10-31T08:00:00Z", with: "昨天"),
                      minimal().replacingOccurrences(of: #""title":"npm 跑完了""#, with: #""title":3"#)])
    func malformedRejected(_ json: String) {
        #expect(throws: MessageError.malformed) { try parse(json) }
    }

    @Test(arguments: ["", "  ", "\n"])
    func blankTitleRejected(_ title: String) {
        #expect(throws: MessageError.missingTitle) {
            try parse(minimal().replacingOccurrences(of: "npm 跑完了", with: title.replacingOccurrences(of: "\n", with: #"\n"#)))
        }
    }

    /// 插件 id 会拼进 `plugins/<id>/manifest.json`：只认小写字母、数字和连字符
    @Test(arguments: ["", "Terminal", "../x", "a/b", "a b", ".hidden", "-x", String(repeating: "a", count: 33)])
    func badPluginIDRejected(_ plugin: String) {
        #expect(throws: MessageError.badPluginID) {
            try parse(minimal().replacingOccurrences(of: #""plugin":"terminal""#, with: #""plugin":"\#(plugin)""#))
        }
    }

    @Test func unknownFieldsIgnored() throws {
        #expect(try parse(minimal(#","sound":"Basso","future":{"x":[1]}"#)).title == "npm 跑完了")
    }

    @Test func fractionalSecondsAccepted() throws {
        let m = try parse(minimal(#","staleAt":"2026-10-31T08:10:00.250Z""#).replacingOccurrences(of: "08:00:00Z", with: "08:00:00.5+08:00"))
        #expect(m.at == Date(timeIntervalSince1970: 1_793_433_600 - 8 * 3600 + 0.5))
        #expect(m.staleAt == Date(timeIntervalSince1970: 1_793_434_200.25))
    }
}

/// 内容块照 Adaptive Cards：TextBlock（fontType monospace 是日志）、FactSet；进度、勾叉列表是扩展
@Suite struct MessageBlocks {
    private func block(_ json: String) throws -> Card.Block? { try parse(minimal(#","block":\#(json)"#)).block }

    /// 正文在边界按换行切成行，空行不算
    @Test func textSplitsOnNewlines() throws {
        #expect(try block(#"{"type":"TextBlock","text":"第一行\n\n第二行\r\n第三行 第四行"}"#) == .text(["第一行", "第二行", "第三行", "第四行"]))
    }

    /// Adaptive Cards 的样例里写的是 Monospace
    @Test(arguments: ["monospace", "Monospace"])
    func monospaceTextIsLog(_ font: String) throws {
        #expect(try block(#"{"type":"TextBlock","text":"a\nb","fontType":"\#(font)"}"#) == .log(["a", "b"]))
    }

    @Test func defaultFontIsText() throws {
        #expect(try block(#"{"type":"TextBlock","text":"a","fontType":"default"}"#) == .text(["a"]))
    }

    @Test func factSet() throws {
        #expect(try block(#"{"type":"FactSet","facts":[{"title":"退出码","value":"1"},{"title":"目录","value":"~/x"}]}"#)
            == .facts([.init(title: "退出码", value: "1"), .init(title: "目录", value: "~/x")]))
    }

    @Test func checklist() throws {
        #expect(try block(#"{"type":"checklist","items":[{"text":"编译","state":"ok"},{"text":"测试","state":"failed"},{"text":"上传","state":"pending"}]}"#)
            == .checklist([.init(text: "编译", state: .ok), .init(text: "测试", state: .failed), .init(text: "上传", state: .pending)]))
    }

    @Test func progress() throws {
        #expect(try block(#"{"type":"progress","value":0.62,"label":"7.4 / 12 GB"}"#) == .progress(0.62, label: "7.4 / 12 GB"))
        #expect(try block(#"{"type":"progress","value":1}"#) == .progress(1, label: nil))
    }

    @Test(arguments: [#"{"type":"Image","url":"file:///etc/hosts"}"#, #"{"type":"TextBlock"}"#, #"{"type":"TextBlock","text":"a","fontType":"serif"}"#,
                      #"{"type":"FactSet"}"#, #"{"type":"checklist","items":[{"text":"a","state":"done"}]}"#, #"{"type":"progress"}"#])
    func badBlockRejected(_ json: String) {
        #expect(throws: MessageError.badBlock) { try block(json) }
    }

    /// 块本身缺 type、键值缺 value：JSON 的形状就不对
    @Test(arguments: [#"{"text":"a"}"#, #"{"type":"FactSet","facts":[{"title":"a"}]}"#])
    func shapelessBlockIsMalformed(_ json: String) {
        #expect(throws: MessageError.malformed) { try block(json) }
    }
}

/// 点卡片和按钮只能打开 URL、切换 App（CLAUDE.md 硬规则「插件」）；URL 放不放行到点击时由 `URLPolicy` 判
@Suite struct MessageActions {
    @Test func openURL() throws {
        let m = try parse(minimal(#","action":{"type":"Action.OpenUrl","url":"https://example.com/x"}"#))
        #expect(m.action == .open(URL(string: "https://example.com/x")!))
    }

    @Test func activate() throws {
        let m = try parse(minimal(#","action":{"type":"activate","bundleID":"com.apple.finder"}"#))
        #expect(m.action == .activate(bundleID: "com.apple.finder"))
    }

    /// 跳回终端：tty 用来认 Ghostty 里是哪个窗口（往它写一次性标题），pid 和 tty 对得上才写
    @Test func focusTerminal() throws {
        let m = try parse(minimal(#","action":{"type":"focusTerminal","tty":"/dev/ttys003","pid":4242,"cwd":"/Users/x/p"}"#))
        #expect(m.action == .focusTerminal(tty: "/dev/ttys003", pid: 4242, cwd: "/Users/x/p"))
    }

    /// tty 会被打开来写：只认 /dev/ttys 加数字（macOS 的伪终端）
    @Test(arguments: [#""tty":"/etc/passwd","pid":4242"#, #""tty":"/dev/ttys","pid":4242"#, #""tty":"/dev/ttys003/../disk0","pid":4242"#,
                      #""tty":"/dev/disk0","pid":4242"#, #""tty":"/dev/ttys003","pid":1"#, #""tty":"/dev/ttys003","pid":0"#])
    func badTerminalRejected(_ fields: String) {
        #expect(throws: MessageError.badAction) { try parse(minimal(#","action":{"type":"focusTerminal",\#(fields),"cwd":"/"}"#)) }
    }

    /// 按钮是带 title 的动作（Adaptive Cards 的 actions）
    @Test func buttons() throws {
        let m = try parse(minimal(#","buttons":[{"type":"Action.OpenUrl","title":"看文档","url":"raycast://x"},{"type":"activate","title":"打开访达","bundleID":"com.apple.finder"}]"#))
        #expect(m.buttons == [.init(title: "看文档", action: .open(URL(string: "raycast://x")!)),
                              .init(title: "打开访达", action: .activate(bundleID: "com.apple.finder"))])
    }

    /// 不收要执行的命令（CLAUDE.md 硬规则「插件」）
    @Test(arguments: [#"{"type":"Action.Execute","verb":"rm"}"#, #"{"type":"shell","command":"rm -rf ~"}"#, #"{"type":"Action.OpenUrl"}"#,
                      #"{"type":"Action.OpenUrl","url":"no scheme"}"#, #"{"type":"activate","bundleID":""}"#])
    func badActionRejected(_ json: String) {
        #expect(throws: MessageError.badAction) { try parse(minimal(#","action":\#(json)"#)) }
    }

    @Test func buttonWithoutTitleRejected() {
        #expect(throws: MessageError.badAction) { try parse(minimal(#","buttons":[{"type":"Action.OpenUrl","url":"https://example.com"}]"#)) }
    }
}

/// 活动（照 ActivityKit 的 start / update / end）：面板里插件那一段的一行，`alert` 时弹卡
@Suite struct ActivityParsing {
    @Test(arguments: [("start", Message.Activity.Event.start), ("update", .update), ("end", .end)])
    func events(_ raw: String, _ event: Message.Activity.Event) throws {
        let m = try parse(minimal(#","activity":{"id":"xcode","event":"\#(raw)"}"#))
        #expect(m.activity == Message.Activity(id: "xcode", event: event, alert: false))
    }

    @Test func alert() throws {
        #expect(try parse(minimal(#","activity":{"id":"x","event":"update","alert":true}"#)).activity?.alert == true)
    }

    @Test func plainMessageHasNoActivity() throws {
        #expect(try parse(minimal()).activity == nil)
    }

    /// id 只在内存里当键用：不能空，也别太长
    @Test(arguments: [#"{"id":"","event":"start"}"#, #"{"id":"x","event":"stop"}"#,
                      #"{"id":"\#(String(repeating: "a", count: 65))","event":"start"}"#])
    func badActivityRejected(_ activity: String) {
        #expect(throws: MessageError.badActivity) { try parse(minimal(#","activity":\#(activity)"#)) }
    }
}
