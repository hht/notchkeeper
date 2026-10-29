import Foundation
import Testing
@testable import GuardCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// 按 guardd 实际写的格式拼文件（`GuardState.encoded()`），再按需改字段
private func file(_ verdict: Verdict = .healthy, age: TimeInterval = 0, schema: Int = 1) throws -> Data {
    var s = GuardState(verdict: verdict, observation: Observation(clashRunning: true, routeInterface: "utun1024", egressIPs: []),
                       allowlist: [], egressFailures: [:],
                       networkPath: NetworkPath(physicalInterfaceSatisfied: true, hasDefaultRoute: true), checkedAt: now.addingTimeInterval(-age))
    s.schemaVersion = schema
    return try s.encoded()
}

private func read(_ data: Data?) -> GuardDisplay { GuardStateReader.display(data: data, now: now) }

@Suite struct GuardStateReading {
    @Test(arguments: [Verdict.healthy, .egressMismatch, .unknown, .violated])
    func freshVerdictIsShownAsIs(_ v: Verdict) throws {
        #expect(read(try file(v, age: 3)) == GuardDisplay(verdict: v, checkedAt: now.addingTimeInterval(-3), reason: .fresh,
                                                          unknownReason: v == .unknown ? .probeFailed : nil, lastVerdict: v))
    }

    @Test func missingFileIsUnknown() {
        #expect(read(nil) == GuardDisplay(verdict: .unknown, checkedAt: nil, reason: .missing))
    }

    @Test(arguments: ["", "{not json", #"{"schemaVersion":1}"#, #"{"schemaVersion":1,"verdict":"bogus","checkedAt":"2027-01-15T08:00:00Z","egressFailures":{}}"#])
    func undecodableIsUnknown(_ json: String) {
        #expect(read(Data(json.utf8)) == GuardDisplay(verdict: .unknown, checkedAt: nil, reason: .unreadable))
    }

    @Test func newerSchemaIsUnknown() throws {
        #expect(read(try file(.healthy, schema: 2)) == GuardDisplay(verdict: .unknown, checkedAt: nil, reason: .newerSchema))
    }

    /// 新版本格式可能整个变了，只要 schemaVersion 读得出来就报 newerSchema，而不是 unreadable
    @Test func newerSchemaWithUnknownShapeIsNewerSchema() {
        #expect(read(Data(#"{"schemaVersion":7,"verdict":{"x":1}}"#.utf8)).reason == .newerSchema)
    }

    @Test func staleAfterThreeIntervals() throws {
        #expect(read(try file(.healthy, age: 15)).reason == .fresh)
        #expect(read(try file(.healthy, age: 16)) == GuardDisplay(verdict: .unknown, checkedAt: now.addingTimeInterval(-16), reason: .stale,
                                                                  lastVerdict: .healthy))
    }

    /// 粘性归 guardd：guardd 不在跑了，过期的 violated 读成 unknown；红卡是否保留由 App 按 lastVerdict 决定
    @Test func staleViolatedIsUnknown() throws {
        #expect(read(try file(.violated, age: 60)).verdict == .unknown)
    }

    @Test func clockJumpIntoFutureIsUnknown() throws {
        #expect(read(try file(.healthy, age: -5)).reason == .fresh)
        #expect(read(try file(.violated, age: -6)) == GuardDisplay(verdict: .unknown, checkedAt: now.addingTimeInterval(6), reason: .clockSkew,
                                                                   lastVerdict: .violated))
    }

    @Test func intervalIsInjectable() throws {
        #expect(GuardStateReader.display(data: try file(.healthy, age: 20), now: now, interval: .seconds(10)).reason == .fresh)
        #expect(GuardStateReader.display(data: try file(.healthy, age: 31), now: now, interval: .seconds(10)).reason == .stale)
    }

    @Test func defaultIntervalIsThePollInterval() throws {
        #expect(read(try file(.healthy, age: 16)).reason == .stale) // 5 秒 × 3
    }
}

@Suite struct GuardFileLocations {
    @Test func appAndGuarddShareOneDirectory() {
        #expect(GuardPaths.stateFile.lastPathComponent == "guard-state.json")
        #expect(GuardPaths.configFile.lastPathComponent == "config.json")
        #expect(GuardPaths.stateFile.deletingLastPathComponent() == GuardPaths.configFile.deletingLastPathComponent())
        #expect(GuardPaths.stateFile.path.hasSuffix("/Library/Application Support/Notchkeeper/guard-state.json"))
    }
}
