import Foundation
import Testing
@testable import Notchkeeper

/// `claude plugin list --json` 的输出（2.1.296 实测的字段，只留用到的）
private func list(_ entries: [(id: String, enabled: Bool)]) -> Data {
    try! JSONSerialization.data(withJSONObject: entries.map { ["id": $0.id, "version": "1.0.0", "scope": "user", "enabled": $0.enabled] })
}

@Suite struct ClaudeModStatus {
    @Test func installedWhenListedAndEnabled() throws {
        #expect(try ClaudeMod.status(fromList: list([("swift-lsp@claude-plugins-official", true), ("notchkeeper@notchkeeper", true)])) == .installed)
    }

    @Test func disabledWhenListedButOff() throws {
        #expect(try ClaudeMod.status(fromList: list([("notchkeeper@notchkeeper", false)])) == .disabled)
    }

    @Test func notInstalledWhenAbsent() throws {
        #expect(try ClaudeMod.status(fromList: list([("swift-lsp@claude-plugins-official", true)])) == .notInstalled)
        #expect(try ClaudeMod.status(fromList: list([])) == .notInstalled)
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try ClaudeMod.status(fromList: Data("Error: not logged in".utf8)) }
    }
}
