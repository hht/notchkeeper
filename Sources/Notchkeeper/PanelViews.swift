import AppKit
import SwiftUI

enum PanelTab: Int, CaseIterable, Identifiable {
    case status, allow, block, logs
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .status: return "状态"
        case .allow: return "允许出口"
        case .block: return "拦截"
        case .logs: return "日志"
        }
    }
    var symbol: String {
        switch self {
        case .status: return "shield.lefthalf.filled"
        case .allow: return "checklist"
        case .block: return "hand.raised.fill"
        case .logs: return "text.alignleft"
        }
    }
}

struct PanelRoot: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var state: AppState
    let notch: NotchController
    let close: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        PanelContent(state: state, notch: notch)
            .frame(width: PanelController.contentSize.width, height: PanelController.contentSize.height)
            .background(VisualEffect(material: .popover))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
            .scaleEffect(model.shown ? 1 : 0.55, anchor: model.anchor)
            .opacity(model.shown ? 1 : 0)
            .blur(radius: model.shown ? 0 : 8)
            .offset(y: model.shown ? 0 : -6)
            .padding(PanelController.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct PanelContent: View {
    @ObservedObject var state: AppState
    let notch: NotchController
    @State private var tab: PanelTab = .status
    @State private var forward = true
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 12) {
            header
            tabBar
            ZStack(alignment: .top) {
                page(tab)
                    .id(tab)
                    .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            footer
        }
        .padding(16)
    }

    private var pageTransition: AnyTransition {
        let dx: CGFloat = 46
        return .asymmetric(
            insertion: .offset(x: forward ? dx : -dx).combined(with: .opacity).combined(with: .scale(scale: 0.98)),
            removal: .offset(x: forward ? -dx : dx).combined(with: .opacity).combined(with: .scale(scale: 0.98))
        )
    }

    private func select(_ t: PanelTab) {
        guard t != tab else { return }
        forward = t.rawValue > tab.rawValue
        DispatchQueue.main.async { withAnimation(Motion.page) { tab = t } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // 吉祥物插槽（占位，原创角色稍后替换）
            Mascot(mood: state.status.mood, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notchkeeper").font(.system(size: 15, weight: .semibold))
                Text(state.status.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: state.status)
            }
            Spacer()
            Button { state.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(state.checking ? 360 : 0))
                    .animation(state.checking ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                               value: state.checking)
                    .frame(width: 28, height: 28)
                    .hoverCard(14, base: 0.07)
            }
            .buttonStyle(PressableStyle())
            .help("立即检查出口")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { t in
                Button { select(t) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 11, weight: .semibold))
                        Text(t.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        if tab == t {
                            Capsule()
                                .fill(Color.primary.opacity(0.12))
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "tab-pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private func page(_ t: PanelTab) -> some View {
        switch t {
        case .status: StatusPage(state: state, notch: notch)
        case .allow: AllowPage(state: state)
        case .block: BlockPage()
        case .logs: LogPage(state: state)
        }
    }

    private var footer: some View {
        HStack {
            Text("M1 预览 · 仅界面，暂不拦截")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(PressableStyle())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .hoverCard(8, base: 0.05)
        }
    }
}

// MARK: - 状态

struct StatusPage: View {
    @ObservedObject var state: AppState
    let notch: NotchController
    @State private var glow = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                hero
                row("Clash 内核", value: "M2 检测（占位）", symbol: "cpu", placeholder: true)
                row("utun 路由", value: "M2 检测（占位）", symbol: "point.3.connected.trianglepath.dotted", placeholder: true)
                demo
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [state.status.color.opacity(0.45), .clear],
                                         center: .center, startRadius: 4, endRadius: 46))
                    .scaleEffect(glow ? 1.12 : 0.9)
                    .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: glow)
                Image(systemName: state.status.symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(state.status.color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 92, height: 80)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: state.status)
            .onAppear { glow = true }

            Text(state.status.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("当前出口 IPv4").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(state.exitIP ?? (state.checking ? "获取中…" : "—"))
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4), value: state.exitIP)
                HStack(spacing: 4) {
                    if let d = state.lastChecked {
                        Text("上次检查").foregroundStyle(.tertiary)
                        Text(d, style: .relative).foregroundStyle(.tertiary)
                        Text("前").foregroundStyle(.tertiary)
                    }
                    Text("· 来源 api.ipify.org").foregroundStyle(.tertiary)
                }
                .font(.system(size: 10))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .hoverCard(16, base: 0.05)
    }

    private func row(_ title: String, value: String, symbol: String, placeholder: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
            Text(title).font(.system(size: 13))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(placeholder ? .tertiary : .secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .hoverCard()
    }

    private var demo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("刘海卡片演示").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                demoButton("出口异常", symbol: "exclamationmark.shield.fill", tint: .red) {
                    notch.show(.exitAlert(ip: state.exitIP)); state.addLog("演示：出口异常卡片", .warn)
                }
                demoButton("任务完成", symbol: "checkmark.seal.fill", tint: .green) {
                    notch.show(.taskDone()); state.addLog("演示：任务完成卡片", .ok)
                }
            }
            Toggle(isOn: $state.simulateUnhealthy) {
                Text("模拟出口异常（看图标变色 + 自动红卡）").font(.system(size: 12))
            }
            .toggleStyle(.switch).controlSize(.mini)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .hoverCard()
        }
        .padding(.top, 4)
    }

    private func demoButton(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.15)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 允许出口

struct AllowPage: View {
    @ObservedObject var state: AppState
    @State private var draft = ""
    @State private var invalid = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("出口 IPv4 在此列表中才视为健康").font(.system(size: 11)).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(state.allowlist, id: \.self) { ip in
                        AllowRow(ip: ip, isCurrent: ip == state.exitIP) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { state.removeAllowed(ip) }
                        }
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .scale(scale: 0.9).combined(with: .opacity)))
                    }
                }
                HStack(spacing: 8) {
                    TextField("新增，例如 203.0.113.10", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(invalid ? Color.red.opacity(0.7) : Color.primary.opacity(0.12)))
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                            .frame(width: 36, height: 34)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.2)))
                    }
                    .buttonStyle(PressableStyle())
                }
                .offset(x: invalid ? -4 : 0)
                if invalid {
                    Text("不是合法的 IPv4，或已在列表中").font(.system(size: 11)).foregroundStyle(.red)
                        .transition(.opacity)
                }
                Toggle(isOn: $state.autoAlert) {
                    Text("出口异常时自动弹出刘海红卡").font(.system(size: 12))
                }
                .toggleStyle(.switch).controlSize(.mini)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .hoverCard()
                Text("M1 暂存在 UserDefaults；M2 改为可热加载的 JSON 配置。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
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

struct AllowRow: View {
    let ip: String
    let isCurrent: Bool
    let onDelete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.green : Color.secondary)
                .font(.system(size: 13))
            Text(ip).font(.system(size: 13, design: .monospaced))
            if isCurrent {
                Text("当前出口").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(PressableStyle())
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.1 : 0.06)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// MARK: - 拦截（占位）

struct BlockPage: View {
    @State private var opts = [true, true, true, true]
    private let items: [(String, String)] = [
        ("结束 Claude 桌面端", "macwindow"),
        ("结束 claude CLI（含编辑器拉起的）", "terminal"),
        ("关闭浏览器里的 claude.ai 标签", "safari"),
        ("CLI 启动前检查（shim 拒绝启动）", "lock.shield"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill")
                    Text("占位：M2 实现，当前开关不生效")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.orange.opacity(0.12)))

                ForEach(items.indices, id: \.self) { i in
                    Toggle(isOn: $opts[i]) {
                        HStack(spacing: 10) {
                            Image(systemName: items[i].1).foregroundStyle(.secondary).frame(width: 20)
                            Text(items[i].0).font(.system(size: 13))
                        }
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .disabled(true)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .hoverCard()
                }

                Text("拦截记录").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 6)
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.shield").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("暂无拦截记录").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .hoverCard(14, base: 0.04)
            }
        }
    }
}

// MARK: - 日志

struct LogPage: View {
    @ObservedObject var state: AppState
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("本次运行 · 不记录 IP").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { withAnimation(.spring(response: 0.35)) { state.clearLogs() } }
                    .buttonStyle(PressableStyle())
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if state.logs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("暂无日志").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(state.logs) { e in
                            HStack(spacing: 8) {
                                Circle().fill(color(e.kind)).frame(width: 6, height: 6)
                                Text(Self.fmt.string(from: e.date))
                                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(e.text).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .hoverCard(9, base: 0.04)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.logs.count)
                }
            }
        }
    }

    private func color(_ k: LogEntry.Kind) -> Color {
        switch k {
        case .info: return .secondary
        case .warn: return .red
        case .ok: return .green
        }
    }
}
