import Foundation
import Testing
@testable import guardd

@Suite struct StateFileWriting {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("guardd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    /// 只有 Haitao 自己可读写；建目录、首次写入都是 0600
    @Test func writesOwnerOnly() throws {
        let file = try scratch().appendingPathComponent("sub/guard-state.json")
        try StateFile.write(Data("a".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("a".utf8))
        #expect(try mode(file) == 0o600)
    }

    /// 覆盖已有文件：内容整份替换，权限收回 0600，不留临时文件
    @Test func replacesWholeFileAndLeavesNoTemp() throws {
        let dir = try scratch()
        let file = dir.appendingPathComponent("guard-state.json")
        try Data("old-and-longer".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try StateFile.write(Data("new".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
        #expect(try mode(file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["guard-state.json"])
    }
}
