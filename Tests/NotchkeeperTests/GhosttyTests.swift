import Testing
@testable import Notchkeeper

private func terminal(_ id: String, _ title: String, _ dir: String) -> Ghostty.Terminal {
    Ghostty.Terminal(id: id, title: title, workingDirectory: dir)
}

/// docs/agent-integration.md「跳转到 Ghostty」：先按目录认，同目录有好几个再按会话名对标题
@Suite struct GhosttyMatching {
    private let terminals = [
        terminal("A", "✳ 修登录", "/Users/u/p1"),
        terminal("B", "◐ 写测试", "/Users/u/p2"),
        terminal("C", "✳ 写文档", "/Users/u/p2"),
        terminal("D", "zsh", "/Users/u"),
    ]

    @Test func uniqueDirectoryWins() {
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p1", name: nil) == "A")
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p1", name: "对不上的名字") == "A")
    }

    /// 标题前面是 Claude Code 的状态字符（✳ 空闲，◐ ◑ 等转圈）
    @Test func sameDirectoryMatchesTitleWithoutStatusGlyph() {
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p2", name: "写测试") == "B")
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p2", name: "写文档") == "C")
    }

    @Test func sameDirectoryWithoutMatchingNameIsAmbiguous() {
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p2", name: nil) == nil)
        #expect(Ghostty.pick(terminals, cwd: "/Users/u/p2", name: "写") == nil)
    }

    /// 同目录两个窗口标题也一样：认不出来，不随便挑一个
    @Test func duplicateTitlesAreAmbiguous() {
        #expect(Ghostty.pick([terminal("X", "✳ 写文档", "/p"), terminal("Y", "◐ 写文档", "/p")], cwd: "/p", name: "写文档") == nil)
    }

    /// 名字只是标题的一部分不算
    @Test func partialTitleDoesNotMatch() {
        #expect(Ghostty.pick([terminal("X", "✳ 不写文档", "/p"), terminal("Y", "✳ 别的", "/p")], cwd: "/p", name: "写文档") == nil)
    }

    /// 目录对不上任何一个（会话不在 Ghostty 里）：再按名字在全部里找
    @Test func noDirectoryFallsBackToTitle() {
        #expect(Ghostty.pick(terminals, cwd: "/elsewhere", name: "修登录") == "A")
        #expect(Ghostty.pick(terminals, cwd: "/elsewhere", name: nil) == nil)
    }

    @Test func trailingSlashIsTheSameDirectory() {
        #expect(Ghostty.pick([terminal("A", "zsh", "/Users/u/p1/")], cwd: "/Users/u/p1", name: nil) == "A")
    }
}
