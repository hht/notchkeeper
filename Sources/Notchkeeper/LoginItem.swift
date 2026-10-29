import AppKit
import ServiceManagement

/// 开机启动：SMAppService.mainApp（macOS 13+）。本机 ad-hoc 签名可用，但 App 换位置或重新签名后可能要重新打开开关。
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static var statusText: String {
        switch status {
        case .enabled: return "已启用"
        case .requiresApproval: return "需要在「系统设置 › 通用 › 登录项」里允许"
        case .notRegistered: return "未启用"
        case .notFound: return "找不到 App，可能被移动过。关掉再打开一次即可。"
        @unknown default: return "未知状态"
        }
    }

    /// 返回 nil 表示成功，否则是错误描述
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
