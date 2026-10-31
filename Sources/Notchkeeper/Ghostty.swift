import AgentCore
import AppKit

/// 回答：点了一个会话，Ghostty 里哪个窗口是它、怎么切过去（docs/agent-integration.md「跳转到 Ghostty」）。
/// 只在用户点击时发 Apple Event，不轮询；都在一条专用队列上发，第一次用时系统问权限、Ghostty 卡住时都不挡主线程。
/// 不知道卡片和面板。
/// @see /Applications/Ghostty.app/Contents/Resources/Ghostty.sdef（Ghostty 1.3：terminal 的 id、name、working directory，focus 命令；没有 tty、pid）
enum Ghostty {
    struct Terminal {
        var id: String
        /// Claude Code 起的会话标题，可能从对话推出来：只在内存里找标记、写回原样，不显示、不进日志
        var title: String
        var workingDirectory: String
    }

    private static let bundleID = "com.mitchellh.ghostty"
    /// NSAppleScript 不是线程安全的：只在这一条队列上用
    private static let queue = DispatchQueue(label: "com.notchkeeper.ghostty")
    /// 每个 Apple Event 最多等这么久（默认约 2 分钟）
    private static let timeout = "with timeout of 3 seconds"
    /// Ghostty 在 IO 线程上解析 tty 输出、再到主线程改标题：标记最多等这么久。10-30 实测第一次查询（约 90ms）就看到了
    private static let markerWait: TimeInterval = 1

    /// 标记找不到时的退路：目录对上的只有一个才是它（同目录常还开着 dev server）。认不出来是 nil
    static func pick(_ terminals: [Terminal], cwd: String) -> String? {
        let sameDirectory = terminals.filter { trimmed($0.workingDirectory) == trimmed(cwd) }
        return sameDirectory.count == 1 ? sameDirectory[0].id : nil
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// 设标题的 OSC 2。标题来自 Ghostty（信任边界）：去掉控制字符，原标题里夹带的转义序列不会被重放进终端
    static func titleSequence(_ title: String) -> [UInt8] {
        let clean = String(String.UnicodeScalarView(title.unicodeScalars.filter { $0.properties.generalCategory != .control }))
        return Array("\u{1B}]2;\(clean)\u{07}".utf8)
    }

    /// 能写标记的 tty：`pid` 的控制终端，并且就是 Ghostty 直接开的那个（沿 ppid 往上，Ghostty 的直接子进程用的同一个 tty）。
    /// 套在 tmux 里（tmux 服务进程的父进程是 launchd）、nvim 的 :terminal 里（tty 是 nvim 开的）都是 nil：OSC 2 被它们吃掉，写了恢复不了
    static func markableTTY(_ pid: Int32, ghostty: Set<Int32>, parent: (Int32) -> Int32?, tty: (Int32) -> String?) -> String? {
        guard let own = tty(pid) else { return nil }
        var current = pid
        // 进程树很浅；限步数防 ppid 成环这种不该有的数据
        for _ in 0..<64 {
            guard let next = parent(current), next > 1 else { return nil }
            if ghostty.contains(next) { return tty(current) == own ? own : nil }
            current = next
        }
        return nil
    }

    /// 打开 Ghostty 并切到这个会话的窗口、标签和分屏；认不出来就只把 Ghostty 拉到前面
    static func focus(_ session: Session) {
        let ghostty = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !ghostty.isEmpty else {
            // 没开：只打开 Ghostty，里面没有这个会话
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        let ghosttyPIDs = Set(ghostty.map(\.processIdentifier))
        queue.async {
            let all = terminals()
            let target = all.flatMap { all in marked(session, ghostty: ghosttyPIDs, in: all) ?? pick(all, cwd: session.cwd) }
            // id 来自 Ghostty，拼进脚本前仍按 UUID 校验（信任边界），拼的是原样的字符串
            let focus = target.flatMap { UUID(uuidString: $0) == nil ? nil : "focus terminal id \"\($0)\"\n" } ?? ""
            _ = execute("tell application id \"\(bundleID)\"\n\(timeout)\n\(focus)activate\nend timeout\nend tell")
        }
    }

    /// 往会话的 tty 写一个一次性的标题，看 Ghostty 里哪个 terminal 换成了它，再把那个 terminal 的原标题写回去。
    /// Ghostty 的 AppleScript 不给 tty（1.3，main 上也还没有），tty 是唯一认得准的东西。
    /// @see https://github.com/kovoor/claude-code-notifier（同一招：临时标题当标记，找到后恢复原标题）
    private static func marked(_ session: Session, ghostty: Set<Int32>, in terminals: [Terminal]) -> String? {
        // 卡片里存的是会话快照：进程没了、pid 被别的终端复用了，就不能往那个 tty 写
        guard AgentWatcher.isRunning(session),
              let tty = markableTTY(session.pid, ghostty: ghostty, parent: { process($0)?.kp_eproc.e_ppid }, tty: tty(of:))
        else { return nil }
        let marker = "notchkeeper-\(UUID().uuidString)"
        guard write(titleSequence(marker), to: tty) else { return nil }
        let deadline = Date().addingTimeInterval(markerWait)
        repeat {
            // Apple Event 失败（execute 已记日志）就不再等；没找到是空列表
            guard let ids = execute("tell application id \"\(bundleID)\"\n\(timeout)\nget id of every terminal whose name is \"\(marker)\"\nend timeout\nend tell")
            else { return nil }
            if let id = ids.atIndex(1)?.stringValue {
                // 没写回的话 Claude Code 不会自己改回来：它只在标题变了时才重写（10-30 实测）。
                // 读标题到写回之间 Claude 刚好换了状态字符的话，写回的是旧字符，等它下次换状态才改过来
                let original = terminals.first { $0.id == id }
                // 快照里没有这个 terminal（读快照之后才开的）也算没写回
                if original.map({ !write(titleSequence($0.title), to: tty) }) ?? true {
                    Log.write("Ghostty：标题没能写回，停在标记上，等 Claude Code 下次改标题")
                }
                return id
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        // 没等到：多半是 Ghostty 配了固定 title、不认 OSC 2，标题没变。
        // 也可能 Ghostty 忙了 1 秒以上、标记来晚了：那时不知道是哪个 terminal，标题停在标记上，等 Claude Code 下次改标题
        Log.write("Ghostty：没找到 tty 标记，退回按目录认")
        return nil
    }

    /// 进程没了是 nil。用 sysctl 而不是 proc_pidinfo：Ghostty 的直接子进程是 setuid root 的 `/usr/bin/login`，
    /// proc_pidinfo 读别的用户的进程会被拒（10-30 实测 EPERM），sysctl 不会（`ps` 也是这么读的）
    /// @see https://developer.apple.com/library/archive/qa/qa2004/qa1123.html
    private static func process(_ pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        // 没有这个进程时调用成功、size 是 0
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size else { return nil }
        return info
    }

    /// 进程的控制终端，如 `/dev/ttys006`；进程没了、没有控制终端是 nil。
    /// 用 `devname_r`：`devname` 返回静态缓冲区，不是线程安全的（man 3 devname）
    private static func tty(of pid: Int32) -> String? {
        guard let device = process(pid)?.kp_eproc.e_tdev, device != -1 else { return nil }  // NODEV：没有控制终端
        var name = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard devname_r(device, S_IFCHR, &name, Int32(name.count)) != nil else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// 非阻塞地写一次：Ghostty 卡住、输出缓冲满了就算失败，不挂住队列。
    /// 写的是 tty 的输出端（终端显示），不是 claude 的输入
    private static func write(_ bytes: [UInt8], to tty: String) -> Bool {
        let fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        // 只写进去一半：补一个 BEL 把 OSC 收尾，免得终端把 Claude 后面的输出当成标题吞掉
        if written > 0, written < bytes.count { _ = Darwin.write(fd, [0x07], 1) }
        return written == bytes.count
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
