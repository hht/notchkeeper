import AppKit
import SwiftUI
import DundunCore

// 设置窗口：按 macOS 系统设置的布局，只用原生控件。
// 每个开关直接绑定 ConfigStore，改了立刻写盘，不在视图里缓存配置值。

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notch, exitGuard, notifications, dundun, stateTest, about
    var id: Self { self }

    /// 侧边栏分组，组与组之间空一行
    static let groups: [[SettingsPane]] = [[.general, .notch], [.exitGuard],
                                           [.notifications, .dundun], [.stateTest], [.about]]

    var title: String {
        switch self {
        case .general: return "通用"
        case .notch: return "刘海与外观"
        case .exitGuard: return "出口守卫"
        case .notifications: return "通知"
        case .dundun: return "盾盾"
        case .stateTest: return "状态测试"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .notch: return "rectangle.topthird.inset.filled"
        case .exitGuard: return "shield.lefthalf.filled"
        case .notifications: return "bell.badge.fill"
        case .dundun: return "face.smiling.inverse"
        case .stateTest: return "testtube.2"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .notch: return .blue
        case .exitGuard: return .green
        case .notifications: return .red
        case .dundun: return .orange
        case .stateTest: return .purple
        case .about: return .gray
        }
    }
}

/// 关掉窗口后 SwiftUI 视图会卸载，选中的页和白名单输入框里的半截地址放这里
@MainActor
final class SettingsModel: ObservableObject {
    @Published var pane: SettingsPane = .general
    @Published var allowDraft = ""
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var state: AppState
    @ObservedObject var store: ConfigStore
    let notch: NotchController

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.pane }, set: { if let p = $0 { model.pane = p } })) {
                Button { model.pane = .exitGuard } label: { StatusCard(presentation: state.presentation) }
                    .buttonStyle(.plain)
                ForEach(SettingsPane.groups, id: \.self) { group in
                    Section {
                        ForEach(group) { p in
                            Label { Text(p.title) } icon: { SettingsIcon(symbol: p.symbol, color: p.color) }
                                .tag(p)
                        }
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(215)
        } detail: {
            detail
                .formStyle(.grouped)
                .navigationTitle(model.pane.title)
                .safeAreaInset(edge: .top) {
                    if store.fileUnreadable { ConfigUnreadableBanner(store: store) }
                }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.pane {
        case .general: GeneralPane()
        case .notch: NotchPane(store: store)
        case .exitGuard: ExitGuardPane(model: model, state: state, store: store)
        case .notifications: NotificationsPane(store: store)
        case .dundun: DundunPane(store: store)
        case .stateTest: StateTestPane(overrides: notch.overrides, state: state, notch: notch)
        case .about: AboutPane(store: store)
        }
    }
}

/// config.json 解不开时，改了也存不进去（ConfigStore 不覆盖原文件），所以先说清楚，并把改配置的控件禁掉
private struct ConfigUnreadableBanner: View {
    let store: ConfigStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("配置文件解不开，设置暂时改不了。改好文件后自动恢复。")
            Spacer()
            Button("打开配置文件") { store.openFile() }.controlSize(.small)
        }
        .font(.callout)
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

/// 系统设置式图标：20×20 圆角 5 的色块，白色符号
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color.gradient)
            .frame(width: 20, height: 20)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
    }
}

/// 侧边栏顶部的状态卡，点它跳到「出口守卫」
private struct StatusCard: View {
    let presentation: GuardPresentation

    var body: some View {
        HStack(spacing: 10) {
            DundunView(state: presentation.mascotState, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notchkeeper").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    GuardDot(presentation: presentation, size: 6)
                    Text(presentation.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    /// SMAppService 的状态不会通知 SwiftUI：存一份，改完开关和每次出现时重读
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var confirmQuit = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle(isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                                     set: setLogin)) {
                    Text("登录时打开")
                    Text(loginError ?? LoginItem.text(loginStatus))
                }
                if loginStatus == .requiresApproval {
                    LabeledContent("在系统设置中批准") {
                        Button("打开…") { LoginItem.openSettings() }.controlSize(.small)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("退出 Notchkeeper…") { confirmQuit = true }
                }
            } footer: {
                Text("退出后刘海和卡片提示会停止，后台守卫照常运行；要停守卫请用卸载脚本。")
            }
        }
        .onAppear { loginStatus = LoginItem.status } // 可能刚在系统设置里批准过
        .confirmationDialog("退出 Notchkeeper？", isPresented: $confirmQuit) {
            Button("退出", role: .destructive) { AppDelegate.quit(reason: "设置里点了退出") }
        } message: {
            Text("退出后刘海和卡片提示会停止，后台守卫照常运行；要停守卫请用卸载脚本。")
        }
    }

    private func setLogin(_ on: Bool) {
        loginError = LoginItem.set(on)
        loginStatus = LoginItem.status
    }
}

// MARK: - 刘海与外观

private struct NotchPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section("刘海") {
                Toggle(isOn: $store.config.hoverExpand) {
                    Text("鼠标悬停时展开")
                    Text("显示出口状态和活跃会话")
                }
            }
            .disabled(store.fileUnreadable)
            Section("动态效果") {
                LabeledContent {
                    Button("打开辅助功能设置…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display")!)
                    }
                    .controlSize(.small)
                } label: {
                    Text("减弱动态效果：跟随系统")
                    Text(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "系统已开启" : "系统未开启")
                }
            }
        }
    }
}

// MARK: - 出口守卫

private struct ExitGuardPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var state: AppState
    @ObservedObject var store: ConfigStore
    @State private var invalid = false

    var body: some View {
        let p = state.presentation
        Form {
            Section("当前状态") {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        GuardDot(presentation: p, size: 6)
                        Text(p.title)
                    }
                }
                // 和刘海展开后的出口是同一个值（GuardStateReader 的 egressIP），完整显示，可选中拷贝
                LabeledContent("当前出口") {
                    Text(state.display.egressIP ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(p.tone == .mismatch ? AnyShapeStyle(p.color) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                }
                // guardd 最后一次写文件的时间；守卫不响应时它会停在过去，正好说明问题
                LabeledContent("上次检查") {
                    if let d = state.display.checkedAt { Text("\(d, style: .relative)前") } else { Text("—") }
                }
            }
            Section {
                ForEach(store.config.allowlist, id: \.self) { ip in
                    LabeledContent {
                        Button { state.removeAllowed(ip) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("移除 \(ip)")
                    } label: {
                        Text(ip).monospacedDigit()
                        if ip == state.display.egressIP { Text("当前出口") }
                    }
                }
                HStack {
                    TextField("新增", text: $model.allowDraft, prompt: Text("例如 198.51.100.10"))
                        .onSubmit(add)
                        .onChange(of: model.allowDraft) { invalid = false }
                    Button("添加", action: add).disabled(model.allowDraft.isEmpty)
                }
            } header: {
                Text("允许的出口 IPv4")
            } footer: {
                if invalid {
                    Text("不是有效的 IPv4 地址，或已在列表里。").foregroundStyle(.red)
                } else if store.fileUnreadable {
                    // guardd 只解 allowlist，别的键坏了它照样读到真实列表，这里却是默认值
                    Text("配置文件解不开，这里显示的是默认设置，不是文件里的列表。")
                } else if store.config.allowlist.isEmpty {
                    Text("列表为空时守卫无法判断出口是否正确，只能显示「暂时查不到出口」（没走隧道仍会报不合规）。")
                }
            }
            .disabled(store.fileUnreadable)
            Section("提示") {
                Toggle("出口不合规时弹出红卡", isOn: $store.config.autoAlert)
                Toggle("红卡一直保留，直到恢复", isOn: $store.config.alertPersistent)
            }
            .disabled(store.fileUnreadable)
        }
    }

    private func add() {
        if state.addAllowed(model.allowDraft) { model.allowDraft = "" } else { invalid = true }
    }
}

// MARK: - 通知

private struct NotificationsPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                LabeledContent("完成卡显示时长") {
                    HStack {
                        Slider(value: $store.config.cardAutoDismissSeconds, in: 2...10, step: 1)
                            .labelsHidden()
                        Text("\(Int(store.config.cardAutoDismissSeconds)) 秒").monospacedDigit()
                    }
                }
            } header: {
                Text("卡片")
            }
            Section("声音") {
                Toggle(isOn: $store.config.soundEnabled) {
                    Text("提示音")
                    Text("完成 Glass · 出口不合规 Basso")
                }
            }
        }
        .disabled(store.fileUnreadable)
    }
}

// MARK: - 盾盾

private struct DundunPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    DundunView(state: .idle, size: 40)
                    Text("盾盾").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                Toggle(isOn: $store.config.dundunFollowsMouse) {
                    Text("跟随鼠标")
                    Text("眼睛看着鼠标、身体往那边歪；鼠标到刘海上时探头。关掉后眼睛一直看正前方")
                }
            }
            .disabled(store.fileUnreadable)
        }
    }
}

// MARK: - 状态测试（只在内存里，见 StateTest.swift）

private struct StateTestPane: View {
    @ObservedObject var overrides: NotchOverrides
    @ObservedObject var state: AppState
    let notch: NotchController

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    DundunView(state: overrides.mascot(real: state.presentation.mascotState), size: 40)
                        .environment(\.dundunLiteral, overrides.dundun != nil)
                    Text(overrides.dundun.map { "强制：\($0.title)" } ?? "真实状态：\(state.presentation.title)")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                Picker("盾盾", selection: Binding(get: { overrides.dundun }, set: { notch.force($0) })) {
                    Text("真实状态").tag(DundunTestState?.none)
                    Divider()
                    ForEach(DundunTestState.allCases) { s in
                        Text(s.title).tag(DundunTestState?.some(s))
                    }
                }
                Picker("刘海", selection: Binding(get: { overrides.pin }, set: { notch.setPin($0) })) {
                    ForEach(NotchPin.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("强制显示")
            } footer: {
                Text("只改盾盾和刘海的样子，不改出口判定，也不弹红卡、不响；真的红卡照常弹出。不写任何文件，重开 App 就恢复。")
            }
            DundunCueSection()
            Section {
                HStack {
                    Spacer()
                    Button("恢复真实状态") { notch.restoreRealState() }
                        .disabled(overrides.isReal)
                }
            }
        }
    }
}

/// 「播放动作」：看得见的盾盾（左耳、上面的预览）各播一次，不管当前造型。只在内存里
private struct DundunCueSection: View {
    var body: some View {
        Section {
            HStack {
                ForEach(IdleMotion.allCases, id: \.self) { m in
                    Button(m.title) { DundunDirector.shared.play(.idle(m)) }
                }
                Button("眨眼") { DundunDirector.shared.play(.blink(double: false)) }
            }
        } header: {
            Text("播放动作")
        } footer: {
            Text("看得见的盾盾各播一次；开了「减弱动态效果」时只有眨眼。不写任何文件。")
        }
    }
}

private extension IdleMotion {
    var title: String {
        switch self {
        case .lookAround: return "张望"
        case .curiousTilt: return "歪头"
        case .peekSide: return "侧身探看"
        case .hop: return "小跳"
        case .shake: return "抖一抖"
        case .spin: return "转一圈"
        }
    }
}

// MARK: - 关于

private struct AboutPane: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    DundunView(state: .idle, size: 64, emote: .beaming)
                    Text("Notchkeeper").font(.title3.weight(.semibold))
                    Text("版本 \(version)（本机签名）").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            Section("文件") {
                LabeledContent {
                    HStack {
                        Button("打开") { store.openFile() }
                        Button("在访达中显示") { store.revealInFinder() }
                    }
                    .controlSize(.small)
                } label: {
                    Text("配置文件")
                    Text(tilde(store.url.path))
                }
                LabeledContent {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }
                        .controlSize(.small)
                } label: {
                    Text("日志")
                    Text(tilde(Log.url.path))
                }
            }
            Section("致谢") {
                Text("改编自 Coucou（MIT），仅供自用")
            }
        }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
    }

    private func tilde(_ p: String) -> String { (p as NSString).abbreviatingWithTildeInPath }
}
