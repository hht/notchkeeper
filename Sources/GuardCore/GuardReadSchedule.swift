import Foundation

/// 回答：App 侧什么时候该重读 `guard-state.json`。
/// 纯状态机：喂进「目录变了」「读完了」两种事件和当前时间，给出下一次该读的时刻；不碰文件、不起定时器、不决定显示什么
/// （显示归 `GuardStateReader.display`）。文件监听和定时器在外层 `GuardStateWatcher`（GuardWatch target）。
///
/// 三个读的理由，取最早的：
/// - **目录事件**：guardd 每轮 temp 写 + rename，目录收到写事件；第一个事件起 `debounce` 内的事件合并成一次读。
///   以第一个事件起算而不是每来一个就往后推，持续不断的写也不会把读推迟到无限远。
/// - **过期时刻**：guardd 死了就不再写，等不到事件；按上次读到的 `checkedAt` 在 reader 判 stale 的那一刻（加一点余量）再读一次。
///   读到的文件已经过期就不挂（再读还是 stale），文件不存在或解不开时没有 `checkedAt`，也不挂。
/// - **兜底**：距上次读 `fallbackInterval`（默认 30 秒）一定再读一次，盖住事件丢失、时钟跳变、目录被删后重建这些情况。
public struct GuardReadSchedule: Equatable, Sendable {
    /// 过期时刻之后多等这么久再读：reader 的判定是「严格晚于」，加上定时器本身的误差
    static let staleSlack: TimeInterval = 0.1

    private let interval: Duration
    private let debounce: TimeInterval
    private let fallback: TimeInterval
    /// 有未处理的目录事件时，合并窗口结束的时刻；新建时等于 `now`，表示一开始就要读一次
    private var debounceEnd: Date?
    private var staleAt: Date?
    private var fallbackAt: Date

    public init(interval: Duration = PollSchedule.interval, debounce: Duration = .milliseconds(100),
                fallbackInterval: Duration = .seconds(30), now: Date) {
        self.interval = interval
        self.debounce = debounce.timeInterval
        self.fallback = fallbackInterval.timeInterval
        debounceEnd = now
        fallbackAt = now.addingTimeInterval(self.fallback)
    }

    public mutating func directoryChanged(at now: Date) {
        if debounceEnd == nil { debounceEnd = now.addingTimeInterval(debounce) }
    }

    /// `checkedAt` 是这次读到的 `GuardDisplay.checkedAt`（文件不存在、解不开时 `nil`）。
    public mutating func didRead(checkedAt: Date?, at now: Date) {
        debounceEnd = nil
        fallbackAt = now.addingTimeInterval(fallback)
        staleAt = checkedAt
            .map { GuardStateReader.staleDeadline(checkedAt: $0, interval: interval).addingTimeInterval(Self.staleSlack) }
            .flatMap { $0 > now ? $0 : nil }
    }

    public var nextReadAt: Date { [debounceEnd, staleAt].compactMap { $0 }.reduce(fallbackAt, min) }

    public func isReadDue(at now: Date) -> Bool { now >= nextReadAt }
}
