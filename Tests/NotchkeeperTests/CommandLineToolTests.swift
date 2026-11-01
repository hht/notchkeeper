import Foundation
import Testing
@testable import Notchkeeper

/// 临时目录里的 `bin/pipctl`（装好的）和 `.local/bin/pipctl`（PATH 上的链接）
private struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pipctl-link-\(UUID().uuidString)")
    var target: URL { root.appendingPathComponent("bin/pipctl") }
    var link: URL { root.appendingPathComponent(".local/bin/pipctl") }

    init() throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: target)
    }
}

@Suite struct CommandLineToolLink {
    /// `.local/bin` 还不存在时一起建出来
    @Test func linkThenUnlink() throws {
        let s = try Sandbox()
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .absent)
        try CommandLineTool.createLink(s.link, target: s.target)
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .linked)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.link.path) == s.target.path)
        try CommandLineTool.removeLink(s.link, target: s.target)
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .absent)
        // 设置页开着时链接在终端里被删了：再点「移除链接」不报错
        try CommandLineTool.removeLink(s.link, target: s.target)
    }

    /// 那个名字已经被别的文件、或指向别处的链接占了：不覆盖，也不删
    @Test(arguments: [false, true])
    func occupiedIsLeftAlone(_ symlink: Bool) throws {
        let s = try Sandbox()
        try FileManager.default.createDirectory(at: s.link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if symlink {
            try FileManager.default.createSymbolicLink(atPath: s.link.path, withDestinationPath: "/usr/bin/true")
        } else {
            try Data("别人的".utf8).write(to: s.link)
        }
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .occupied)
        #expect(throws: (any Error).self) { try CommandLineTool.createLink(s.link, target: s.target) }
        #expect(throws: (any Error).self) { try CommandLineTool.removeLink(s.link, target: s.target) }
        if symlink {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: s.link.path) == "/usr/bin/true")
        } else {
            #expect(try String(contentsOf: s.link, encoding: .utf8) == "别人的")
        }
        #expect(CommandLineTool.linkState(s.link, target: s.target) == .occupied)
    }
}
