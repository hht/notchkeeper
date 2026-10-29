import Foundation
import GuardCore
import GuardProbes

/// 回答：出口守卫的后台进程每一轮做什么——跑三路探针、交给 `EgressGuard` 判定、写状态文件、verdict 变化时通知 App。
/// 不判定（规则在 GuardCore），不探测细节（在 GuardProbes），不画界面，也不拦截（见 `onVerdictChange`）。
///
/// 网络路径（有没有物理网络）只用来给 unknown 标原因（offline / probeFailed），不影响 verdict。
///
/// 用法：`guardd` 一直轮询，SIGTERM / SIGINT 后在当前一步结束时退出；`guardd --once` 跑一轮、写文件、打印结果后退出。
/// 状态文件：`~/Library/Application Support/Notchkeeper/guard-state.json`（格式见 `GuardState`）；
/// 允许列表每轮从同目录的 `config.json` 重读（见 `AllowlistFile`）。
@main
enum Guardd {
    /// 拦截接缝：verdict 变化、状态文件写好之后调用一次。本片故意不实现。
    /// 甲（杀进程）和 killswitch 的取舍待 Haitao 定，见 docs/interception.md、docs/killswitch-integration.md。
    static let onVerdictChange: @Sendable (Verdict) -> Void = { _ in }

    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        guard args.isEmpty || args.elementsEqual(["--once"]) else {
            log("用法：guardd [--once]")
            exit(64) // EX_USAGE
        }
        let stateURL = GuardPaths.stateFile

        let loop = Task { await run(once: !args.isEmpty, stateURL: stateURL) }
        // 信号只用来取消轮询任务：正在 sleep 或等 HTTP 时立刻醒来，不写半截的一轮。
        // 必须用主队列：handler 在这里继承 main actor 隔离，放到别的队列上 Swift 6 运行时会断言失败（实测 SIGTRAP）。
        // @see https://developer.apple.com/documentation/dispatch/dispatchsource/makesignalsource(signal:queue:)
        let sources = [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { loop.cancel() }
            s.resume()
            return s
        }
        let status = await loop.value
        sources.forEach { $0.cancel() }
        exit(status)
    }

    static func run(once: Bool, stateURL: URL) async -> Int32 {
        var egressGuard = resumedGuard(stateURL: stateURL)
        var notified: Shown?
        var allowlistProblem: AllowlistFile.Problem?
        let clock = ContinuousClock()
        let probes = Probes.live() // 网络路径监视器常驻，整个进程只建一次
        while !Task.isCancelled {
            let start = clock.now
            let loaded = AllowlistFile.read()
            if loaded.problem != allowlistProblem {
                // 问题出现或变了才记一行，不每轮刷屏
                log(loaded.problem?.message ?? "config.json 的允许列表已恢复正常读取")
                allowlistProblem = loaded.problem
            }
            let allowlist = loaded.allowlist
            let round = await observe(deadline: start + PollSchedule.roundDeadline, clock: clock, probes: probes)
            if Task.isCancelled { break } // 探针被取消，这一轮的数据不完整
            let checkedAt = Date()
            let verdict = egressGuard.observe(round.observation, allowlist: allowlist, at: checkedAt)
            let state = GuardState(verdict: verdict, observation: round.observation, allowlist: allowlist,
                                   egressFailures: round.failures, networkPath: round.path,
                                   violatedSince: egressGuard.violatedSince, checkedAt: checkedAt)
            let shown = Shown(verdict: verdict, unknownReason: state.unknownReason)
            do {
                try StateFile.write(state.encoded(), to: stateURL)
                if shown != notified {
                    // 先写文件再通知：App 收到通知时读到的一定是这一轮。unknown 的原因变了也通知（文字要换）
                    DistributedNotificationCenter.default().postNotificationName(
                        .init(GuardState.changedNotification), object: nil, userInfo: nil, deliverImmediately: true)
                    if verdict != notified?.verdict { onVerdictChange(verdict) } // 拦截只关心 verdict
                    log("verdict: \(notified?.description ?? "-") → \(shown.description)")
                    notified = shown
                }
            } catch {
                // 写失败不更新 notified，下一轮重试写文件和通知
                log("写 \(GuardState.fileName) 失败：\(error)")
                if once { return 1 }
            }
            if once {
                print(summary(state))
                return 0
            }
            let next = PollSchedule.nextRoundStart(lastStart: start, lastEnd: clock.now, interval: PollSchedule.interval)
            do { try await Task.sleep(until: next, clock: clock) } catch { break } // 只有取消会抛
        }
        return 0
    }

    /// 启动时接续上一份状态文件里的粘性：KeepAlive 重启后第一轮若是 unknown / 出口不符，不能把 violated 覆盖掉、悄悄撤掉红卡。
    /// 只从解得开、同格式版本的 violated 接续，不看新旧（规则见 `EgressGuard.init(resuming:)`）。
    static func resumedGuard(stateURL: URL) -> EgressGuard {
        let g = EgressGuard(resuming: GuardState.resumable(from: try? Data(contentsOf: stateURL)))
        if g.verdict == .violated { log("接续上次的 violated：要一轮 healthy 才解除") }
        return g
    }

    /// 上次通知 App 时的显示内容：verdict 加 unknown 的原因
    struct Shown: Equatable, CustomStringConvertible {
        var verdict: Verdict
        var unknownReason: UnknownReason?
        var description: String { verdict.rawValue + (unknownReason.map { "(\($0.rawValue))" } ?? "") }
    }

    /// 一轮要跑的探针。测试换成桩；`live()` 是真实探针（网络路径监视器在这里创建，所以只调一次）。
    struct Probes: Sendable {
        var route: @Sendable () async -> String?
        var clash: @Sendable () -> Bool?
        var path: any NetworkPathSource
        var egress: EgressProbe

        static func live() -> Probes {
            Probes(route: { await RouteProbe.current() }, clash: { ClashProbe.current() },
                   path: LiveNetworkPath(), egress: .live)
        }
    }

    /// 一轮的探针结果。`path == nil` 是没拿到网络快照（没赶上截止或监视器还没回调）。
    struct Round {
        var observation: Observation
        var failures: [String: Int]
        var path: NetworkPath?
    }

    /// 路由 + Clash、出口 IP、网络路径三路并发，共用一个截止时间；各自单独截止，一路卡住不拖掉另两路的结果。
    /// Clash 是一次很快的系统调用，放到 GCD 线程，不占 Swift 并发的协作线程池；路由子进程超时会被结束（`RouteProbe.output`）。
    static func observe(deadline: ContinuousClock.Instant, clock: ContinuousClock, probes: Probes) async -> Round {
        let route = probes.route, clashProbe = probes.clash, pathSource = probes.path, egressProbe = probes.egress
        async let local = Deadline.run(by: deadline, clock: clock) { () async -> (String?, Bool?) in
            async let clash = withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async { c.resume(returning: clashProbe()) }
            }
            return (await route(), await clash)
        }
        async let egress = Deadline.run(by: deadline, clock: clock) { await egressProbe.current() }
        async let path = Deadline.run(by: deadline, clock: clock) { await pathSource.current() }
        let (observation, failures) = merge(local: await local, egress: await egress, egressEndpoints: egressProbe.endpoints.count)
        return Round(observation: observation, failures: failures, path: await path ?? nil)
    }

    /// 把赶上 / 没赶上截止的探针结果合成一轮观测。`nil` 是没赶上：只能算「没有结果」，绝不算「好」；
    /// 出口探针没赶上时每个回显服务记一次 timeout，排查时看得出是超时。
    static func merge(local: (String?, Bool?)?, egress: EgressProbe.Sample?, egressEndpoints: Int) -> (Observation, [String: Int]) {
        let sample = egress ?? EgressProbe.Sample(failures: [.timeout: egressEndpoints])
        let failures = Dictionary(uniqueKeysWithValues: sample.failures.map { ("\($0.key)", $0.value) })
        return (Observation(clashRunning: local?.1, routeInterface: local?.0, egressIPs: sample.ips), failures)
    }

    /// `--once` 的输出：只有判定和布尔摘要，没有 IP。
    static func summary(_ s: GuardState) -> String {
        func show(_ b: Bool?) -> String { b.map(String.init) ?? "unknown" }
        let failures = s.egressFailures.isEmpty ? "none"
            : s.egressFailures.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "verdict=\(s.verdict.rawValue) clashRunning=\(show(s.clashRunning)) routeOnTunnel=\(show(s.routeOnTunnel)) "
            + "egressMatches=\(show(s.egressMatches)) egressFailures=\(failures) unknownReason=\(s.unknownReason?.rawValue ?? "none")"
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("guardd: \(message)\n".utf8))
    }
}
