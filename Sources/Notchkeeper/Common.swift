import AppKit
import SwiftUI

/// 第一次点击即可响应（非激活面板里不用先点一下“激活”）
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PressableStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

enum Apps {
    /// 切到这个 App：开着就拉到前面，没开就打开。false 表示没装这个 App。
    /// 交给 `/usr/bin/open -b`：macOS 14 起激活是协作式的，刘海面板不激活自己、让不出前台。
    /// 10-31 实测从后台进程调：`NSRunningApplication.activate()` 和 `NSWorkspace.openApplication` 都切不过去，
    /// `open -b` 和 AppleScript `activate` 能切；后者每个目标 App 都要先弹「自动化」权限，所以用前者。
    /// bundle id 作为参数传，不经过 shell
    /// @see https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(options:)
    @discardableResult
    static func activate(_ bundleID: String) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return false }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", bundleID]
        do { try open.run() } catch { Log.write("切换 App 失败：\((error as NSError).domain) \((error as NSError).code)") }
        return true
    }
}

/// 刘海展开（含弹卡）、收起、卡片放完回到面板、面板行数变化的弹簧，只在这里定义（docs/mascot.md §5「收起与展开」）
enum NotchSpring {
    static let page = Animation.spring(response: 0.42, dampingFraction: 0.84)
    static let notchOpen = Animation.spring(response: 0.5, dampingFraction: 0.7)
    static let notchClose = Animation.spring(response: 0.38, dampingFraction: 0.88)
}
