import AppKit
import Symbols

/// 菜单栏图标。用 NSImageView 子视图承载 SF Symbol，以便使用符号替换 / 弹跳动效。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let iconView = PassthroughImageView()
    private let menu: NSMenu
    private var current: GuardStatus = .unknown
    var onLeftClick: (() -> Void)?
    var onMenuWillOpen: (() -> Void)?

    init(menu: NSMenu) {
        self.menu = menu
        super.init()
        menu.delegate = self
        guard let button = item.button else { return }
        button.image = nil
        button.title = ""
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyDown
        button.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Notchkeeper"
        render(.unknown, animated: false, bounce: false)
    }

    var buttonScreenFrame: NSRect? {
        guard let b = item.button, let w = b.window else { return nil }
        return w.convertToScreen(b.convert(b.bounds, to: nil))
    }

    private(set) var style: IconStyle = .filled

    func setStyle(_ s: IconStyle) {
        guard s != style else { return }
        style = s
        render(current, animated: false, bounce: false)
    }

    func update(_ status: GuardStatus, animated: Bool) {
        let changed = status != current
        current = status
        render(status, animated: animated && changed, bounce: animated && changed && status == .unhealthy)
    }

    private func symbolName(_ s: GuardStatus) -> String {
        guard style == .outline else { return s.symbol }
        switch s {
        case .healthy: return "checkmark.shield"
        case .unhealthy: return "xmark.shield"
        case .unknown: return "shield"
        }
    }

    /// 单色样式下正常 / 未知跟随菜单栏颜色，异常仍然标红
    private func tint(_ s: GuardStatus) -> NSColor? {
        if style == .mono { return s == .unhealthy ? .systemRed : nil }
        return s.nsColor
    }

    private func render(_ status: GuardStatus, animated: Bool, bounce: Bool) {
        guard let img = NSImage(systemSymbolName: symbolName(status), accessibilityDescription: status.title) else { return }
        item.button?.setAccessibilityLabel("Notchkeeper：\(status.title)")
        item.button?.toolTip = "Notchkeeper · \(status.title)"
        if animated {
            iconView.setSymbolImage(img, contentTransition: .replace)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.allowsImplicitAnimation = true
                iconView.contentTintColor = tint(status)
            }
        } else {
            iconView.image = img
            iconView.contentTintColor = tint(status)
        }
        if bounce { iconView.addSymbolEffect(.bounce) }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            onLeftClick?()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { onMenuWillOpen?() }
}

final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
