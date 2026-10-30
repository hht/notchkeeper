import Foundation

/// 临时卡片的倒计时：鼠标停在卡片上时暂停，移开后从剩下的时间继续
public struct CardCountdown: Equatable, Sendable {
    public let total: TimeInterval
    private var remainingAtResume: TimeInterval
    /// nil 表示暂停中
    private var resumedAt: Date?

    public init(total: TimeInterval, now: Date) {
        self.total = total
        remainingAtResume = total
        resumedAt = now
    }

    public var isPaused: Bool { resumedAt == nil }

    public func remaining(at now: Date) -> TimeInterval {
        guard let r = resumedAt else { return remainingAtResume }
        return max(0, remainingAtResume - now.timeIntervalSince(r))
    }

    public mutating func pause(at now: Date) {
        guard !isPaused else { return }
        remainingAtResume = remaining(at: now)
        resumedAt = nil
    }

    public mutating func resume(at now: Date) {
        guard isPaused else { return }
        resumedAt = now
    }
}
