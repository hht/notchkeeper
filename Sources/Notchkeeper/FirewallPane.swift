import AppKit
import FirewallCore
import SwiftUI

/// 设置 › 防火墙：开关、状态、试运行倒计时和「保留」，以及装、卸（`FirewallInstaller`）。状态只看状态摘要（`FirewallReading`），
/// 页面看得见时每 2 秒重读一次（被遮挡、最小化、锁屏时停）；开启、保留、关闭、装、卸每次都先用一句话说清会发生什么，再弹管理员密码框，之后等守护进程跑完那一轮再放开开关。
/// 不靠 config.json，配置文件解不开也能用
struct FirewallPane: View {
    @State private var reading = FirewallInstaller.reading(now: Date()).reading
    /// 开启、保留、关闭开始的时刻（命令成功才记）：`FirewallReading.settled` 之前开关还不能信，守护进程那一轮可能还没写完
    @State private var waitingSince: Date?
    @State private var visible = false
    @State private var tunnel = "utun1024"
    @State private var confirmInstall = false
    @State private var confirmEnable = false
    @State private var confirmUninstall = false
    @State private var working = false
    @State private var error: String?
    /// 装完、卸完的一句话：脚本的输出普通用户看不懂，结果用一句话说
    @State private var notice: String?

    private var installed: Bool { reading != .notInstalled }

    var body: some View {
        Form {
            if installed {
                Section {
                    Toggle(isOn: Binding(get: { reading.switchedOn }, set: { $0 ? (confirmEnable = true) : disable() })) {
                        Text("防火墙")
                        if waitingSince != nil {
                            Text("等守护进程确认…").foregroundStyle(.secondary)
                        } else {
                            FirewallStatusLine(reading: reading, live: visible)
                        }
                    }
                    .disabled(working || waitingSince != nil)
                    if case .trial = reading {
                        LabeledContent {
                            Button("保留", action: keep).disabled(!reading.canKeep || working || waitingSince != nil)
                        } label: {
                            Text(reading.canKeep ? String(localized: "网络正常就点「保留」，之后一直开着，重启也开着")
                                                 : String(localized: "出了问题不能保留：什么都不用做，到时自动关掉"))
                        }
                    }
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else if let notice {
                        Text(notice).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("开着时，没走 Clash 隧道的流量除局域网、Clash 直连的地址和国内 IP 外一律拦下。每次开启先试运行 2 分钟，不点「保留」自动关掉。开启、保留、关闭都要管理员密码。")
                }
            }
            Section {
                LabeledContent {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        if installed {
                            Button("卸载…") { confirmUninstall = true }
                        } else {
                            Button("安装…") { confirmInstall = true }
                        }
                    }
                    .disabled(working)
                } label: {
                    Text(installed ? "卸载" : "安装")
                    if !installed, let error {
                        Text(error).foregroundStyle(.red)
                    } else if !installed, let notice {
                        Text(notice)
                    } else {
                        Text(installed ? String(localized: "清掉守护进程、规则和文件，开着的话立即放开，断网时也用它") : String(localized: "未安装"))
                    }
                }
                if !installed {
                    TextField("隧道网卡", text: $tunnel, prompt: Text("utun1024"))
                        .disabled(working)
                }
            } footer: {
                if !installed {
                    Text("安装要管理员密码，装完是关着的，什么都不拦。隧道网卡填 Clash 的 TUN 网卡名，只收 utun 加数字（Clash Verge 默认 utun1024）：填错了开启后会把外网全拦掉。")
                }
            }
        }
        .confirmationDialog("安装防火墙？", isPresented: $confirmInstall) {
            Button("安装", action: install)
        } message: {
            Text("装完是关着的，什么都不拦，要用时再打开。要管理员密码。")
        }
        .confirmationDialog("开启防火墙？", isPresented: $confirmEnable) {
            Button("开启试运行", action: enable)
        } message: {
            Text("没走 Clash 隧道的流量除局域网、Clash 直连的地址和国内 IP 外都会被拦下。先试运行 2 分钟：网断了什么都不用做，到时自动关掉；没问题就点「保留」。开启时从 Clash Verge 读一次节点和国内 IP 段，之后换了订阅要关掉再开。")
        }
        .confirmationDialog("卸载防火墙？", isPresented: $confirmUninstall) {
            Button("卸载", role: .destructive, action: uninstall)
        } message: {
            Text("清掉守护进程、规则和文件，开着的话立即放开。要管理员密码。")
        }
        .background(WindowVisibility(visible: $visible))
        // 看得见才读（看不见就不调度）：守护进程 10 秒一轮，2 秒一读够及时
        .task(id: visible) {
            while visible, !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func enable() {
        command("已开启试运行") { try await FirewallInstaller.enable() }
    }

    private func keep() {
        command("已保留") { try await FirewallInstaller.keep() }
    }

    private func disable() {
        command("已关闭") { try await FirewallInstaller.disable() }
    }

    /// 开启、保留、关闭：结果看开关那一行，不另说
    private func command(_ log: String, _ run: @escaping @MainActor () async throws -> FirewallInstaller.Outcome) {
        let started = Date()
        perform {
            guard try await run() == .done else { return }
            waitingSince = started
            Log.write("防火墙：\(log)")
        }
    }

    private func refresh() {
        let now = Date()
        let r = FirewallInstaller.reading(now: now)
        reading = r.reading
        if let since = waitingSince, FirewallReading.settled(checkedAt: r.checkedAt, commandStarted: since, now: now) {
            waitingSince = nil
        }
    }

    private func install() {
        let tunnel = tunnel.trimmingCharacters(in: .whitespaces)
        perform {
            let staged = try FirewallInstaller.stage()
            defer { FirewallInstaller.discard(staged) }
            guard try await FirewallInstaller.install(staged, tunnel: tunnel) == .done else { return }
            Log.write("防火墙：已安装")
            notice = String(localized: "已安装，现在是关着的，什么都不拦")
        }
    }

    private func uninstall() {
        perform {
            let staged = try FirewallInstaller.stage()
            defer { FirewallInstaller.discard(staged) }
            guard try await FirewallInstaller.uninstall(staged) == .done else { return }
            Log.write("防火墙：已卸载")
            notice = String(localized: "已卸载，规则和文件都清掉了")
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        working = true
        error = nil
        notice = nil
        Task {
            do {
                try await work()
            } catch {
                self.error = String(localized: "操作失败：\(error.localizedDescription)")
                Log.write("防火墙：操作失败")
            }
            refresh()
            working = false
        }
    }
}

/// 开关下面那一行：试运行时倒计时（只在这一行上每秒刷新）
private struct FirewallStatusLine: View {
    let reading: FirewallReading
    /// 看不见时不走秒
    let live: Bool

    var body: some View {
        switch reading {
        case .trial(let endsAt?, let problem):
            // 出了问题也留着倒计时：最需要「什么都不做，到点自动关掉」这句的时候
            if live {
                TimelineView(.periodic(from: .now, by: 1)) { context in Self.countdown(endsAt, at: context.date) }
            } else {
                Self.countdown(endsAt, at: Date())
            }
            if let problem { Text(Self.text(problem)).foregroundStyle(.red) }
        default:
            Text(Self.caption(reading)).foregroundStyle(Self.isWarning(reading) ? Color.red : .secondary)
        }
    }

    private static func countdown(_ endsAt: Date, at now: Date) -> Text {
        let left = max(0, Int(endsAt.timeIntervalSince(now).rounded(.up)))
        return Text(left > 0 ? String(localized: "试运行中，还剩 \(left / 60):\(String(format: "%02d", left % 60))，到时自动关掉")
                             : String(localized: "试运行到期，正在关掉"))
    }

    private static func caption(_ r: FirewallReading) -> String {
        switch r {
        case .notInstalled: return String(localized: "未安装")
        case .off(nil): return String(localized: "关着，什么都不拦")
        case .trial(_, nil): return String(localized: "试运行中，到时自动关掉")
        case .on(nil): return String(localized: "已保护")
        case .off(let p?), .trial(_, let p?), .on(let p?), .unknown(let p): return text(p)
        }
    }

    private static func isWarning(_ r: FirewallReading) -> Bool {
        switch r {
        case .notInstalled, .off(nil), .trial(_, nil), .on(nil): return false
        default: return true
        }
    }

    private static func text(_ p: FirewallReading.Problem) -> String {
        switch p {
        case .noSummary: return String(localized: "还没有状态：刚装上或刚卸到一半，稍等几秒；一直这样就卸载重装")
        case .unreadable: return String(localized: "状态摘要读不出来")
        case .stale: return String(localized: "异常：守护进程 30 秒没有更新状态，说不清在不在拦；关掉或卸载")
        case .stateUnreadable: return String(localized: "防火墙状态文件读不出来，现在按关着办；要再开，先卸载再装")
        case .testRules: return String(localized: "装的是测试规则，只拦去测试地址的流量，不算保护")
        case .rulesNotLoaded: return String(localized: "规则这一轮没装上，下一轮重做；现在可能没在拦")
        case .tunnelMissing: return String(localized: "隧道网卡不在（Clash 没开 TUN，或网卡名填错）：现在外网全被拦下")
        case .checkFailed: return String(localized: "异常：核对没通过（pf 被停、规则被换掉或隧道网卡不在），可能没在拦")
        case .failedSteps: return String(localized: "有 pf 动作没做成，下一轮重做；关着时规则也可能还在")
        }
    }
}

/// 所在窗口看不看得见（被遮挡、最小化、锁屏都算看不见）
/// @see https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification
private struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe { Probe { visible = $0 } }
    func updateNSView(_ view: Probe, context: Context) { view.onChange = { visible = $0 } }

    final class Probe: NSView {
        var onChange: (Bool) -> Void

        init(_ onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { preconditionFailure("只从代码创建") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(report), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            report()
        }

        @objc private func report() {
            let v = window?.occlusionState.contains(.visible) == true
            // 在视图更新当中改 SwiftUI 状态会报警告：放到下一轮
            DispatchQueue.main.async { [onChange] in onChange(v) }
        }
    }
}
