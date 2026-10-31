import Darwin
import Foundation
import FirewallCore
import os

/// 回答：一轮和一条命令具体怎么执行——加锁、读状态、按 `FirewallState` 给的动作调 pfctl、记结果、写两个文件。
/// 不判定（在 FirewallCore），不知道是谁调的（launchd 或 osascript）。
enum Helper {
    enum Command: String {
        case enable, keep, disable
    }

    enum Failure: Error, Equatable {
        case command(FirewallCommandError)
        /// 状态文件读不出来：不覆盖它（原文件留给人看），先跑恢复脚本
        case stateUnreadable
        case busy
        case io(String)
    }

    /// LaunchDaemon 的启动参数：隧道网卡名、装哪种规则
    struct RoundConfig {
        let tunnel: String
        let scope: FirewallRules.Scope
        let rules: FirewallRules

        init?(tunnel: String, scope: FirewallRules.Scope) {
            guard let rules = FirewallRules(tunnel: tunnel, scope: scope) else { return nil }
            (self.tunnel, self.scope, self.rules) = (tunnel, scope, rules)
        }
    }

    static let log = Logger(subsystem: FirewallPaths.label, category: "helper")

    /// 一轮（docs/firewall.md §4「LaunchDaemon 每一轮」）。等不到锁返回 `nil`，什么都不做，下一轮再来
    static func round(_ sys: FirewallSystem, _ config: RoundConfig) -> FirewallStatus? {
        locked(sys) { () -> FirewallStatus in
            let moment = sys.moment()
            let stateURL = sys.directory.appendingPathComponent(FirewallState.fileName)
            let restored = restore(stateURL)
            var state = FirewallState(bootSession: moment.bootSession)
            if case .valid(let s) = restored { state = s }
            // 读不出来的状态文件不覆盖：按 off 办，原文件留给人看
            let writable = restored != .unreadable
            func save() -> Bool {
                guard writable else { return false }
                do {
                    try AtomicFile.write(state.encoded(), to: stateURL, mode: 0o600)
                    return true
                } catch {
                    log.error("写状态文件失败：\(error, privacy: .public)")
                    return false
                }
            }
            let pf = { (args: [String], input: String?) in sys.run("/sbin/pfctl", args, input) }

            let references = { () -> Set<String>? in
                let out = pf(["-s", "References"], nil)
                return out.succeeded ? PFOutput.tokens(fromReferences: out.stdout) : nil
            }

            let anchor = pf(["-a", FirewallPaths.anchor, "-sr"], nil)
            let snapshot = PFSnapshot(anchorEmpty: anchor.succeeded && anchor.stdout.allSatisfy(\.isWhitespace), tokens: references())
            var actions = state.tick(at: moment, pf: snapshot, rules: config.rules)
            var failed: [PFStep] = []
            // 先确认状态文件写得进去：写不进去时拿到的 token 记不下来，下一轮又 -E，引用越涨越多
            if !save(), actions.contains(.enable) {
                actions.removeAll { $0 == .enable }
                failed.append(.enable)
            }
            for action in actions {
                let out = switch action {
                case .load(let r): pf(["-a", FirewallPaths.anchor, "-f", "-"], r.text)
                case .enable: pf(["-E"], nil)
                case .flush: pf(["-a", FirewallPaths.anchor, "-F", "rules"], nil)
                case .release(let token): pf(["-X", token], nil)
                }
                guard out.succeeded else {
                    log.error("pfctl \(action.step.rawValue, privacy: .public) 失败（\(out.status)）：\(out.stderr, privacy: .public)")
                    failed.append(action.step)
                    continue
                }
                state.record(action, token: action == .enable ? PFOutput.token(fromEnable: out.stderr) : nil)
                _ = save() // 做成一件就落盘：拿到 token 后中途崩了（恢复脚本 bootout 也算），下一轮和恢复脚本都知道引用在手里
                if action == .enable {
                    state.confirmReference(liveTokens: references())
                    _ = save()
                }
            }

            var check: FirewallCheck?
            if state.mode != .off {
                // 哪条读失败了就传空串，对应的那项判不过
                let stdout = { (out: Output) in out.succeeded ? out.stdout : "" }
                check = state.check(mainRules: stdout(pf(["-sr"], nil)),
                                    anchorRules: stdout(pf(["-a", FirewallPaths.anchor, "-vsr"], nil)),
                                    info: stdout(pf(["-s", "info"], nil)),
                                    interfaces: stdout(sys.run("/sbin/ifconfig", ["-l"], nil)), tunnel: config.tunnel)
            }
            _ = save()

            let now = sys.now()
            // 换规则那轮装失败时 anchor 里还是旧规则，不能说成这一轮的
            var status = FirewallStatus(mode: .off, scope: state.loadedRules == config.rules ? config.scope : nil, check: check,
                                        failedSteps: failed, checkedAt: now)
            switch state.mode {
            case .off: status.mode = writable ? .off : .stateUnreadable
            case .trial(let deadline):
                status.mode = .trial
                status.trialEndsAt = now.addingTimeInterval(TimeInterval(deadline.milliseconds - moment.now.milliseconds) / 1000)
            case .on: status.mode = .on
            }
            do {
                try AtomicFile.write(status.encoded(), to: sys.directory.appendingPathComponent(FirewallStatus.fileName), mode: 0o644)
            } catch {
                log.error("写状态摘要失败：\(error, privacy: .public)")
            }
            return status
        }
    }

    /// 开启 / 保留 / 关闭：只改状态文件，再让守护进程马上跑一轮。对 pf 做什么只在一轮里决定
    static func command(_ command: Command, _ sys: FirewallSystem) throws(Failure) {
        let done: Void? = try locked(sys) { () throws(Failure) in
            let moment = sys.moment()
            let stateURL = sys.directory.appendingPathComponent(FirewallState.fileName)
            var state = FirewallState(bootSession: moment.bootSession)
            switch restore(stateURL) {
            case .valid(let s): state = s
            case .missing: break
            // 坏文件不覆盖。关闭照样算成功：读不出状态时每一轮本来就按 off 办
            case .unreadable: if command == .disable { return } else { throw .stateUnreadable }
            }
            do throws(FirewallCommandError) {
                switch command {
                case .enable: try state.enable(at: moment)
                case .keep: try state.keep(at: moment)
                case .disable: state.disable()
                }
            } catch {
                throw .command(error)
            }
            do { try AtomicFile.write(state.encoded(), to: stateURL, mode: 0o600) } catch { throw .io("写状态文件失败：\(error)") }
        }
        guard done != nil else { throw .busy }
        let kick = sys.run("/bin/launchctl", ["kickstart", "system/\(FirewallPaths.label)"], nil)
        guard kick.succeeded else { throw .io("状态已改，但没能让守护进程马上跑一轮（\(kick.stderr)）；10 秒内它会自己跑") }
    }

    private static func restore(_ url: URL) -> FirewallState.Restored {
        do {
            return FirewallState.restore(from: try Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return .missing
        } catch {
            log.error("读不了状态文件：\(error, privacy: .public)")
            return .unreadable
        }
    }

    /// 一轮和命令互斥。锁文件 root 0600：普通用户打不开，锁不住它。等 `sys.lockTimeout` 还拿不到返回 `nil`；进程退出锁自动放开。
    /// 锁文件打不开（目录没了）时照样往下做：同时在跑的只可能是另一个 root 的一轮或命令，比一轮不跑、试运行不回滚好
    private static func locked<T, E: Error>(_ sys: FirewallSystem, _ body: () throws(E) -> T) throws(E) -> T? {
        let fd = open(sys.directory.appendingPathComponent(FirewallPaths.lockFile).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        defer { if fd >= 0 { close(fd) } }
        if fd >= 0 {
            // 按单调时钟等：等锁时系统时间被往回调，也不会一直等下去
            let deadline = ContinuousClock.now + .seconds(sys.lockTimeout)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard ContinuousClock.now < deadline else {
                    log.error("等了 \(Int(sys.lockTimeout)) 秒没拿到锁")
                    return nil
                }
                usleep(100_000)
            }
        } else {
            log.error("打不开锁文件（\(errno)），不加锁往下做")
        }
        return try body()
    }
}
