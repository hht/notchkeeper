import Foundation

/// 回答：卡片上的「打开 URL」能不能打开。默认只放行 https；config.json 的 `urlSchemes` 里列的也放行（用户 10-31；第 5 刀进设置页）。
/// 自定义 scheme（raycast://、btt:// 这类）能拉起别的 App 执行动作，不在白名单里就拦下。
/// 只管放不放行，不打开、不知道卡片
public struct URLPolicy: Sendable {
    private let schemes: Set<String>

    /// schemes：白名单，写成「Raycast」「raycast://」都行；写错的空条目不算（不能变成放行）
    public init(schemes: [String]) {
        self.schemes = Set(schemes.compactMap { entry in
            var s = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if s.hasSuffix("://") { s.removeLast(3) }
            return s.isEmpty ? nil : s
        })
    }

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || schemes.contains(scheme)
    }
}
