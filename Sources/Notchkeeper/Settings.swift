import AppKit
import SwiftUI

// MARK: - 设置页（通用 / 出口守卫 / 通知 / 关于）

enum SettingsSection: Int, CaseIterable, Identifiable {
    case general, exitGuard, notifications, about
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .exitGuard: return "出口守卫"
        case .notifications: return "通知"
        case .about: return "关于"
        }
    }
}

struct SettingsPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ConfigStore
    @State private var section: SettingsSection = .general
    @State private var forward = true
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(SettingsSection.allCases) { s in
                    Button { select(s) } label: {
                        Text(s.title)
                            .font(NK.caption.weight(.medium))
                            .foregroundStyle(section == s ? Color.primary : Color.secondary)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background {
                                if section == s {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.primary.opacity(0.1))
                                        .matchedGeometryEffect(id: "settings-pill", in: ns)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))

            ZStack(alignment: .top) {
                ScrollView(showsIndicators: false) {
                    content(section).padding(.bottom, 6)
                }
                .id(section)
                .transition(.asymmetric(
                    insertion: .offset(x: forward ? 30 : -30).combined(with: .opacity),
                    removal: .offset(x: forward ? -30 : 30).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
    }

    private func select(_ s: SettingsSection) {
        guard s != section else { return }
        forward = s.rawValue > section.rawValue
        DispatchQueue.main.async { withAnimation(Motion.page) { section = s } }
    }

    @ViewBuilder
    private func content(_ s: SettingsSection) -> some View {
        switch s {
        case .general: GeneralSettings(store: store)
        case .exitGuard: ExitGuardSettings(state: state, store: store)
        case .notifications: NotificationSettings(store: store)
        case .about: AboutSettings(state: state, store: store)
        }
    }
}

// MARK: 通用

struct GeneralSettings: View {
    @ObservedObject var store: ConfigStore
    @State private var loginText = LoginItem.statusText
    @State private var loginOn = LoginItem.isEnabled || LoginItem.status == .requiresApproval
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: NK.groupSpacing) {
            SettingsGroup("启动") {
                SettingsRow("开机自动启动", subtitle: loginError ?? loginText, symbol: "power",
                            subtitleTint: loginError != nil ? .red : nil) {
                    Toggle("", isOn: Binding(get: { loginOn }, set: setLogin))
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                if LoginItem.status == .requiresApproval {
                    RowDivider()
                    SettingsRow("打开「登录项」设置", symbol: "gearshape") {
                        Button("打开") { LoginItem.openSettings() }.controlSize(.small)
                    }
                }
            }
            SettingsGroup("外观") {
                SettingsRow("菜单栏图标", symbol: "menubar.rectangle") {
                    Picker("", selection: $store.config.iconStyle) {
                        ForEach(IconStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                RowDivider()
                SettingsRow("面板材质", subtitle: PanelMaterial.liquidGlassAvailable ? nil : "液态玻璃需要 macOS 26",
                            symbol: "square.on.square") {
                    Picker("", selection: $store.config.panelMaterial) {
                        ForEach(PanelMaterial.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    .disabled(!PanelMaterial.liquidGlassAvailable)
                }
                RowDivider()
                SettingsRow("提示音", subtitle: "红卡 Basso · 绿卡 Glass", symbol: "speaker.wave.2") {
                    MiniToggle(isOn: $store.config.soundEnabled)
                }
            }
            SettingsGroup("刘海") {
                SettingsRow("悬停刘海展开", subtitle: "显示出口和活跃会话；与 Vibe Island 同时开启会重叠",
                            symbol: "rectangle.topthird.inset.filled") {
                    MiniToggle(isOn: $store.config.hoverExpand)
                }
            }
        }
        .onAppear(perform: refreshLogin)
    }

    private func setLogin(_ on: Bool) {
        let err = LoginItem.set(on)
        loginError = err.map { "失败：\($0)" }
        store.config.launchAtLogin = on
        refreshLogin()
    }

    private func refreshLogin() {
        withAnimation(.easeOut(duration: 0.2)) {
            loginText = LoginItem.statusText
            loginOn = LoginItem.isEnabled || LoginItem.status == .requiresApproval
        }
    }
}

// MARK: 出口守卫

struct ExitGuardSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(spacing: NK.groupSpacing) {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("允许的出口 IPv4")
                AllowListEditor(state: state)
            }
            SettingsGroup("检测") {
                SettingsRow("检查间隔", subtitle: "通用 IP 回显服务（ipify / ipinfo / ifconfig.me）", symbol: "timer") {
                    Stepper(value: $store.config.checkIntervalSeconds, in: 5...300, step: 5) {
                        Text("\(store.config.checkIntervalSeconds) 秒")
                            .font(NK.mono).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    }
                    .controlSize(.small)
                }
                RowDivider()
                SettingsRow("出口异常自动弹红卡", symbol: "exclamationmark.shield") {
                    MiniToggle(isOn: $store.config.autoAlert)
                }
                RowDivider()
                SettingsRow("红卡常驻", subtitle: store.config.alertPersistent ? "直到出口恢复或手动关闭" : "和绿卡一样自动收起",
                            symbol: "pin") {
                    MiniToggle(isOn: $store.config.alertPersistent)
                }
            }
        }
    }
}

struct AllowListEditor: View {
    @ObservedObject var state: AppState
    @ObservedObject var store = ConfigStore.shared
    @State private var draft = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.config.allowlist, id: \.self) { ip in
                AllowRow(ip: ip, isCurrent: ip == state.exitIP) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state.removeAllowed(ip) }
                }
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .scale(scale: 0.9).combined(with: .opacity)))
            }
            HStack(spacing: 8) {
                TextField("新增，例如 203.0.113.10", text: $draft)
                    .textFieldStyle(.plain)
                    .font(NK.mono)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: NK.radiusSmall, style: .continuous)
                        .strokeBorder(invalid ? Color.red.opacity(0.7) : Color.primary.opacity(0.12)))
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        .frame(width: 34, height: 32)
                        .background(RoundedRectangle(cornerRadius: NK.radiusSmall, style: .continuous)
                            .fill(Color.accentColor.opacity(0.2)))
                }
                .buttonStyle(PressableStyle())
            }
            .offset(x: invalid ? -4 : 0)
            if invalid {
                Text("不是合法的 IPv4，或已在列表中").font(NK.footnote).foregroundStyle(.red).transition(.opacity)
            }
        }
    }

    private func add() {
        let ok = withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state.addAllowed(draft) }
        if ok {
            draft = ""
            withAnimation { invalid = false }
        } else {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.3)) { invalid = true }
        }
    }
}

// MARK: 通知

struct NotificationSettings: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(spacing: NK.groupSpacing) {
            SettingsGroup("完成卡片") {
                SettingsRow("自动收起", symbol: "timer") {
                    HStack(spacing: 8) {
                        Slider(value: $store.config.cardAutoDismissSeconds, in: 2...10, step: 1)
                            .controlSize(.mini).frame(width: 96)
                        Text("\(Int(store.config.cardAutoDismissSeconds)) 秒")
                            .font(NK.mono).monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                }
                RowDivider()
                SettingsRow("宿主 App 在前台时不提示", subtitle: "例如正在看着终端 / 编辑器时", symbol: "macwindow") {
                    MiniToggle(isOn: $store.config.suppressWhenHostFrontmost)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Agent")
                VStack(spacing: 0) {
                    ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { i, a in
                        if i > 0 { RowDivider() }
                        AgentRow(agent: a, isOn: Binding(
                            get: { store.config.agentEnabled(a) },
                            set: { store.config.agents[a.rawValue] = $0 }))
                    }
                }
                .groupCard()
                Text("每个 agent 只接 1 个“回合结束”钩子，子 agent、hook 续跑、手动中断都不会提示。钩子下一阶段安装；目前开关只保存偏好。")
                    .font(NK.footnote).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct AgentRow: View {
    let agent: AgentKind
    @Binding var isOn: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(agent.tint)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(agent.tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(NK.body.weight(.medium))
                HStack(spacing: 4) {
                    Image(systemName: "circle.dashed").font(.system(size: 9))
                    Text("未接入 · \(agent.hookMechanism)")
                    Image(systemName: "info.circle").font(.system(size: 9))
                        .help(agent.passiveSessionSupport
                              ? "悬停刘海的会话列表已能被动读取它的会话；完成提示下一阶段接入。"
                              : "完成提示下一阶段接入（只需 1 个钩子）。")
                }
                .font(NK.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if agent.passiveSessionSupport {
                Text("会话可见").font(.system(size: 9, weight: .medium)).foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }
            MiniToggle(isOn: $isOn)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.primary.opacity(hover ? 0.04 : 0))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

// MARK: 关于

struct AboutSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: ConfigStore

    private var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "0.2.0") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        VStack(spacing: NK.groupSpacing) {
            VStack(spacing: 6) {
                Mascot(mood: .happy, size: 54)
                Text("Notchkeeper").font(NK.title)
                Text("版本 \(version) · ad-hoc 本机签名").font(NK.caption).foregroundStyle(.secondary)
                Text("盯住出口 IP，在刘海里提示编程助手的进度。")
                    .font(NK.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)

            SettingsGroup("文件") {
                SettingsRow("配置文件", subtitle: tilde(store.url.path), symbol: "doc.text") {
                    HStack(spacing: 6) {
                        Button("打开") { store.openFile() }
                        Button("显示") { store.revealInFinder() }
                    }
                    .controlSize(.small)
                }
                RowDivider()
                SettingsRow("日志", subtitle: tilde(Log.url.path), symbol: "text.alignleft") {
                    Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }.controlSize(.small)
                }
            }
            Text("配置文件改动会自动热加载。界面与吉祥物为原创占位，未使用任何第三方品牌素材。")
                .font(NK.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tilde(_ p: String) -> String {
        p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

// MARK: - 通用设置组件

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(NK.caption.weight(.medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { SectionTitle(title) }
            VStack(spacing: 0) { content }.groupCard()
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var subtitleTint: Color?
    @ViewBuilder let trailing: Trailing
    @State private var hover = false

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, subtitleTint: Color? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.subtitleTint = subtitleTint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(NK.body)
                if let subtitle {
                    Text(subtitle).font(NK.footnote)
                        .foregroundStyle(subtitleTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                        .lineLimit(2).truncationMode(.middle)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 38)
        .background(Color.primary.opacity(hover ? 0.04 : 0))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.leading, 40)
    }
}

struct MiniToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
    }
}

extension View {
    func groupCard() -> some View {
        self
            .background(RoundedRectangle(cornerRadius: NK.radius, style: .continuous).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: NK.radius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: NK.radius, style: .continuous))
    }
}
