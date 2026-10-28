import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var shown = false
    @Published var anchor: UnitPoint = .top
}

/// 菜单栏图标下方的无边框面板；动画全部在 SwiftUI 里做（窗口本身只是透明容器）
@MainActor
final class PanelController {
    static let contentSize = CGSize(width: 380, height: 500)
    static let pad: CGFloat = 28  // 给阴影留的透明边

    private let panel: KeyablePanel
    private let model = PanelModel()
    private var monitors: [Any] = []
    private var windowSize: CGSize {
        CGSize(width: Self.contentSize.width + Self.pad * 2, height: Self.contentSize.height + Self.pad * 2)
    }

    var isOpen: Bool { model.shown }

    init(state: AppState, notch: NotchController) {
        panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let root = PanelRoot(model: model, state: state, notch: notch, close: { [weak self] in self?.close() })
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: windowSize)
        panel.setContentSize(windowSize)
        panel.contentView = host
    }

    func toggle(anchor: NSRect) { isOpen ? close() : open(anchor: anchor) }

    func open(anchor: NSRect) {
        let size = windowSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let vf = screen?.visibleFrame {
            x = min(max(x, vf.minX - Self.pad + 8), vf.maxX - size.width + Self.pad - 8)
        }
        let y = anchor.minY - 6 + Self.pad - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)

        let ax = (anchor.midX - (x + Self.pad)) / Self.contentSize.width
        model.anchor = UnitPoint(x: min(max(ax, 0), 1), y: 0)

        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.async { withAnimation(Motion.open) { self.model.shown = true } }
        installMonitors()
    }

    func close() {
        guard model.shown else { return }
        withAnimation(Motion.close) { model.shown = false }
        removeMonitors()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !self.model.shown { self.panel.orderOut(nil) }
        }
    }

    private func installMonitors() {
        removeMonitors()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            Task { @MainActor in self.close() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { ev in
            if ev.keyCode == 53 { // Esc
                Task { @MainActor in self.close() }
                return nil
            }
            return ev
        }) { monitors.append(l) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
