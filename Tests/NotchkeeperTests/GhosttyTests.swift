import Testing
@testable import Notchkeeper

private func terminal(_ id: String, _ dir: String) -> Ghostty.Terminal {
    Ghostty.Terminal(id: id, title: "zsh", workingDirectory: dir)
}

/// docs/agent-integration.md「跳转到 Ghostty」：标记找不到时退回按目录认，只有一个才算
@Suite struct GhosttyDirectoryFallback {
    private let terminals = [terminal("A", "/Users/u/p1"), terminal("B", "/Users/u/p2"), terminal("C", "/Users/u/p2")]

    @Test func uniqueDirectoryWins() {
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p1") == "A")
    }

    /// 同目录还开着 dev server 之类：认不出来，不随便挑一个
    @Test func sameDirectoryIsAmbiguous() {
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p2") == nil)
    }

    @Test func noDirectoryIsNil() {
        #expect(Ghostty.pick(terminals, cwd: "/elsewhere") == nil)
    }

    @Test func trailingSlashIsTheSameDirectory() {
        #expect(Ghostty.pick([terminal("A", "/Users/u/p1/")], cwd: "/Users/u/p1") == "A")
    }
}

/// 写回 tty 的标题来自 Ghostty（信任边界）：控制字符一律去掉，免得原标题里夹着转义序列被重放
@Suite struct GhosttyTitleSequence {
    @Test func wrapsTitleInOSC2() {
        #expect(Ghostty.titleSequence("✳ 修登录") == Array("\u{1B}]2;✳ 修登录\u{07}".utf8))
    }

    @Test func stripsControlCharacters() {
        #expect(Ghostty.titleSequence("a\u{1B}]0;x\u{07}b\u{9C}c\u{7F}\n") == Array("\u{1B}]2;a]0;xbc\u{07}".utf8))
    }
}

/// 只在 claude 直接跑在 Ghostty 的终端里时写标记：套在 tmux、nvim 的 :terminal 里时，OSC 2 被它们吃掉，写了恢复不了
@Suite struct GhosttyAncestry {
    private struct Proc { var parent: Int32; var tty: String? }
    /// claude 100 → zsh 90 → login 80 → Ghostty 70；tmux 里的 claude 200 → zsh 190 → tmux 180 → launchd 1；
    /// nvim :terminal 里的 claude 300（ttys9）→ zsh 290（ttys9）→ nvim 280（ttys1）→ zsh 270 → login 260（ttys1）→ Ghostty 70
    private let procs: [Int32: Proc] = [
        100: Proc(parent: 90, tty: "/dev/ttys1"), 90: Proc(parent: 80, tty: "/dev/ttys1"), 80: Proc(parent: 70, tty: "/dev/ttys1"),
        200: Proc(parent: 190, tty: "/dev/ttys2"), 190: Proc(parent: 180, tty: "/dev/ttys2"), 180: Proc(parent: 1, tty: nil),
        300: Proc(parent: 290, tty: "/dev/ttys9"), 290: Proc(parent: 280, tty: "/dev/ttys9"), 280: Proc(parent: 270, tty: "/dev/ttys3"),
        270: Proc(parent: 260, tty: "/dev/ttys3"), 260: Proc(parent: 70, tty: "/dev/ttys3"),
    ]

    private func tty(_ pid: Int32) -> String? {
        Ghostty.markableTTY(pid, ghostty: [70], parent: { procs[$0]?.parent }, tty: { procs[$0]?.tty })
    }

    @Test func directlyInGhostty() {
        #expect(tty(100) == "/dev/ttys1")
    }

    @Test func insideTmuxIsNot() {
        #expect(tty(200) == nil)
    }

    /// 祖先里有 Ghostty，但 claude 的 tty 是 nvim 开的，不是 Ghostty 开的
    @Test func insideNestedTerminalIsNot() {
        #expect(tty(300) == nil)
    }

    /// Ghostty 配了 `command = claude`：claude 自己就是 Ghostty 的直接子进程
    @Test func claudeIsGhosttysChild() {
        #expect(Ghostty.markableTTY(500, ghostty: [70], parent: { $0 == 500 ? 70 : nil }, tty: { $0 == 500 ? "/dev/ttys5" : nil }) == "/dev/ttys5")
    }

    @Test func noControllingTerminalIsNot() {
        #expect(Ghostty.markableTTY(600, ghostty: [70], parent: { $0 == 600 ? 70 : nil }, tty: { _ in nil }) == nil)
    }

    /// 进程中途没了（查不到父进程）
    @Test func vanishedProcessIsNot() {
        #expect(tty(400) == nil)
    }
}
