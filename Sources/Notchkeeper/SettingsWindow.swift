import AppKit
import SwiftUI

/// 设置窗口：普通 NSWindow（标题栏透明、内容铺满），宽度固定 715，高度可调。
/// 第一次打开居中，之后记住位置；关掉窗口不退出 App。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 715, height: 560)
    private static let autosaveName = "NotchkeeperSettings"

    private let model = SettingsModel()
    private let state: AppState
    private let notch: NotchController
    private lazy var window: NSWindow = makeWindow()

    init(state: AppState, notch: NotchController) {
        self.state = state
        self.notch = notch
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { model.pane = pane }
        if window.contentViewController == nil {
            let frame = window.frame
            window.contentViewController = hostingController()
            window.setFrame(frame, display: false)  // 换内容控制器会按内容尺寸改窗口大小，保持原位置和大小
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 关掉后卸载 SwiftUI 视图，隐藏的窗口不留任何刷新；选中页和输入框草稿在 model 里，重新打开不丢
    func windowWillClose(_ notification: Notification) {
        window.contentViewController = nil
    }

    private func hostingController() -> NSViewController {
        let host = NSHostingController(rootView: SettingsView(model: model, state: state, store: ConfigStore.shared, notch: notch))
        // 让 navigationTitle 和工具栏交给窗口显示，与系统设置一致
        // @see https://developer.apple.com/documentation/swiftui/nshostingcontroller/scenebridgingoptions
        host.sceneBridgingOptions = [.title, .toolbars]
        return host
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: true)
        w.titlebarAppearsTransparent = true
        w.toolbar = NSToolbar()  // 有工具栏，页面标题才会像系统设置那样靠左显示在详情栏顶部
        w.toolbarStyle = .unified
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: Self.size.width, height: 460)
        w.contentMaxSize = NSSize(width: Self.size.width, height: .greatestFiniteMagnitude)
        w.delegate = self
        // @see https://developer.apple.com/documentation/appkit/nswindow/setframeautosavename(_:)
        if !w.setFrameUsingName(Self.autosaveName) { w.center() }
        w.setFrameAutosaveName(Self.autosaveName)
        return w
    }
}
