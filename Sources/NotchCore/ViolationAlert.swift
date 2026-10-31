import Foundation
import GuardCore

/// 回答：守卫又读了一份之后，红卡该挂上、换副标题、撤掉还是不动；撤掉时弹不弹恢复卡。
/// 「用户关掉的是哪一次违规」「这次违规弹过红卡没有」只在这里记（docs/egress-guard.md、docs/ui.md「卡片」）。
/// 纯状态机：红卡什么时候在台面上归 `CardQueue`，卡长什么样归 App。
public struct ViolationAlert: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// 新的一次违规：红卡插到最前，`sounds` 决定响不响 Basso
        case raise(GuardPresentation.Alert)
        /// 红卡已经挂着：只换副标题，不重弹、不重响
        case replaceDetail(GuardPresentation.Alert)
        /// 读到 healthy：撤掉红卡；recovered 时弹恢复卡
        case clear(recovered: Bool)
    }

    private var display: GuardDisplay
    /// nil = 没关掉过；.some(x) = 用户关掉了 violatedSince 为 x 的那次。只在内存：App 重启后红卡再出现一次，宁可多提醒
    private var dismissedViolationSince: Date??
    /// 挂着的红卡的副标题；nil = 没挂着
    private var shown: GuardPresentation.Alert?
    /// 这次违规弹过红卡：回到 healthy 才弹恢复卡。中间断网、守卫不响应、用户关掉红卡都算同一次
    private var alerted = false
    /// 设置里出口守卫插件开着：关着时照常判定，但不挂红卡、不弹恢复卡
    private var enabled = true

    public init(_ d: GuardDisplay) { display = d }

    public var presentation: GuardPresentation { GuardPresentation(display, dismissedViolationSince: dismissedViolationSince) }

    /// 每读一次守卫状态调用一次。autoAlert：设置「出口异常时弹出红卡」
    public mutating func read(_ d: GuardDisplay, autoAlert: Bool) -> Action {
        display = d
        if d.verdict == .healthy { dismissedViolationSince = nil }
        guard enabled else { return .none }
        if presentation.status == .healthy {
            defer { shown = nil; alerted = false }
            return shown != nil || alerted ? .clear(recovered: alerted) : .none
        }
        guard let alert = presentation.alert, autoAlert else { return .none }
        alerted = true
        switch shown {
        case nil: shown = alert; return .raise(alert)
        case alert: return .none
        case .some: shown = alert; return .replaceDetail(alert)
        }
    }

    /// 开关出口守卫插件。关掉：撤红卡、不弹恢复卡（关的是提醒，不是判定）；打开：按最近一份状态读一次
    public mutating func setEnabled(_ on: Bool, autoAlert: Bool) -> Action {
        guard on != enabled else { return .none }
        enabled = on
        if on { return read(display, autoAlert: autoAlert) }
        defer { shown = nil; alerted = false }
        return shown != nil ? .clear(recovered: false) : .none
    }

    /// 红卡收起了、违规没恢复（用户点了 ×，或不常驻的红卡到时）。只在违规还挂着时记下，演示红卡关掉不算
    public mutating func dismiss() {
        shown = nil
        guard presentation.holdsViolation else { return }
        dismissedViolationSince = .some(display.violatedSince)
    }

    #if DEBUG
    /// scripts/demo.sh alert：挂一张红卡，下次读到 healthy 撤掉，不弹恢复卡。只有 DEBUG 构建听 demo.sh
    public mutating func demo() -> Action {
        shown = .violated
        return .raise(.violated)
    }
    #endif
}
