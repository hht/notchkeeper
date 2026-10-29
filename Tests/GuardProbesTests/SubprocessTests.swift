import Foundation
import Testing
@testable import GuardProbes

/// 路由探针的子进程：每轮有 8 秒截止，超时被取消时必须把子进程结束掉，不能让它拖住一轮。
@Suite struct SubprocessOutput {
    private let clock = ContinuousClock()

    @Test func returnsStdout() async {
        #expect(await RouteProbe.output(of: URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"]) == "hi\n")
    }

    @Test func nonZeroExitIsNil() async {
        #expect(await RouteProbe.output(of: URL(fileURLWithPath: "/usr/bin/false"), arguments: []) == nil)
    }

    @Test func cancelTerminatesChild() async {
        let begin = clock.now
        let task = Task { await RouteProbe.output(of: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"]) }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        #expect(await task.value == nil)
        #expect(clock.now - begin < .seconds(2))
    }

    /// 已经取消的任务不再启动子进程
    @Test func cancelledBeforeLaunchNeverRuns() async {
        let begin = clock.now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RouteProbe.output(of: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        }
        #expect(await task.value == nil)
        #expect(clock.now - begin < .seconds(1))
    }
}
