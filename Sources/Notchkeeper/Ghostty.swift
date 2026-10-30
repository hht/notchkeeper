import AgentCore
import AppKit

/// 回答：点了一个会话，Ghostty 里哪个窗口是它、怎么切过去（docs/agent-integration.md「跳转到 Ghostty」）。
/// 只在用户点击时发 Apple Event，不轮询；都在一条专用队列上发，第一次用时系统问权限、Ghostty 卡住时都不挡主线程。
/// 不知道卡片和面板。
/// @see /Applications/Ghostty.app/Contents/Resources/Ghostty.sdef（Ghostty 1.3：terminal 的 id、name、working directory，focus 命令）
enum Ghostty {
    struct Terminal {
        var id: String
        /// Claude Code 把会话名写进标题，前面带一个状态字符，如「✳ 修登录」
        var title: String
        var workingDirectory: String
    }

    private static let bundleID = "com.mitchellh.ghostty"
    /// NSAppleScript 不是线程安全的：只在这一条队列上用
    private static let queue = DispatchQueue(label: "com.notchkeeper.ghostty")
    /// 每个 Apple Event 最多等这么久（默认约 2 分钟）
    private static let timeout = "with timeout of 3 seconds"

    /// 先按目录认，只有一个就是它；同目录有好几个、或一个都没有，再拿会话名和去掉状态字符的标题比。认不出来是 nil
    static func pick(_ terminals: [Terminal], cwd: String, name: String?) -> String? {
        let sameDirectory = terminals.filter { trimmed($0.workingDirectory) == trimmed(cwd) }
        if sameDirectory.count == 1 { return sameDirectory[0].id }
        guard let name else { return nil }
        let titled = (sameDirectory.isEmpty ? terminals : sameDirectory).filter { session(in: $0.title) == name }
        return titled.count == 1 ? titled[0].id : nil
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// 「✳ 修登录」→「修登录」：第一个词是单个不是字母数字的字符才当状态字符去掉
    private static func session(in title: String) -> String {
        let parts = title.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 1, let glyph = parts[0].first, !glyph.isLetter, !glyph.isNumber else { return title }
        return String(parts[1])
    }

    /// 打开 Ghostty 并切到这个会话的窗口、标签和分屏；认不出来就只把 Ghostty 拉到前面
    static func focus(_ session: Session) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            // 没开：只打开 Ghostty，里面没有这个会话
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        queue.async {
            // id 来自 Ghostty，拼进脚本前仍按 UUID 校验（信任边界），拼的是原样的字符串
            let target = terminals().flatMap { pick($0, cwd: session.cwd, name: session.name) }.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
            let focus = target.map { "focus terminal id \"\($0)\"\n" } ?? ""
            _ = execute("tell application id \"\(bundleID)\"\n\(timeout)\n\(focus)activate\nend timeout\nend tell")
        }
    }

    /// 全部 terminal；Apple Event 失败（用户没允许控制 Ghostty、超时）是 nil
    private static func terminals() -> [Terminal]? {
        // 结果是三列：{ {id…}, {name…}, {working directory…} }
        guard let columns = execute("tell application id \"\(bundleID)\"\n\(timeout)\nget {id, name, working directory} of every terminal\nend timeout\nend tell"),
              columns.numberOfItems == 3,
              let ids = columns.atIndex(1), let titles = columns.atIndex(2), let directories = columns.atIndex(3) else { return nil }
        return (0..<ids.numberOfItems).compactMap { i in
            guard let id = ids.atIndex(i + 1)?.stringValue else { return nil }
            // 没有 shell 集成的 terminal 目录是 missing value
            return Terminal(id: id, title: titles.atIndex(i + 1)?.stringValue ?? "",
                            workingDirectory: directories.atIndex(i + 1)?.stringValue ?? "")
        }
    }

    private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let script = NSAppleScript(source: source) else { preconditionFailure("脚本是写死的，一定能编译") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743：用户没允许 Notchkeeper 控制 Ghostty（系统设置 › 隐私与安全性 › 自动化）
            Log.write("Ghostty：Apple Event 失败（\(error[NSAppleScript.errorNumber] ?? "?")）")
            return nil
        }
        return result
    }
}
