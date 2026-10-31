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

/// 装、卸这类操作失败，带一句给用户看的原因（设置页显示 `localizedDescription`）
struct Failure: LocalizedError {
    var errorDescription: String?
}

extension FileManager {
    /// 用 `source` 的一份拷贝换掉 `destination`（文件或目录）：先拷到同一卷的临时目录再整体换上去，拷到一半失败时原来那份还在
    func replaceItem(at destination: URL, withCopyOf source: URL) throws {
        try createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = try url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination.deletingLastPathComponent(), create: true)
            .appendingPathComponent(destination.lastPathComponent)
        defer {
            // 临时目录，换上去之后已经空了；删不掉只占一个空目录
            do { try removeItem(at: staging.deletingLastPathComponent()) } catch { Log.write("删不掉临时目录：\(error.localizedDescription)") }
        }
        try copyItem(at: source, to: staging)
        if fileExists(atPath: destination.path) {
            _ = try replaceItemAt(destination, withItemAt: staging)
        } else {
            try moveItem(at: staging, to: destination)
        }
    }
}

/// 刘海展开（含弹卡）、收起、卡片放完回到面板、面板行数变化的弹簧，只在这里定义（docs/mascot.md §5「收起与展开」）。
/// 开了「减弱动态效果」就收紧成不回弹的（HIG Accessibility："Tightening animation springs to reduce bounce effects"）；
/// 每次取都看一眼系统设置，改了马上生效
/// @see https://developer.apple.com/design/human-interface-guidelines/accessibility
enum NotchSpring {
    static var page: Animation { spring(response: 0.42, dampingFraction: 0.84) }
    static var notchOpen: Animation { spring(response: 0.5, dampingFraction: 0.7) }
    static var notchClose: Animation { spring(response: 0.38, dampingFraction: 0.88) }

    private static func spring(response: Double, dampingFraction: Double) -> Animation {
        .spring(response: response, dampingFraction: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : dampingFraction)
    }
}
