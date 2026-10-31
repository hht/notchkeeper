import Foundation

/// 回答：卡片上的「打开 URL」能不能打开。默认只放行 https；`urlSchemes` 里列的也放行（用户 10-31，设置 › 插件）。
/// 自定义 scheme（raycast://、btt:// 这类）能拉起别的 App 执行动作，不在白名单里就拦下。
/// 只管放不放行，不打开、不知道卡片
public struct URLPolicy: Sendable {
    private let schemes: Set<String>

    /// schemes：白名单，写成「Raycast」「raycast://」都行；写错的条目不算（不能变成放行），config.json 里手写的也按 `scheme(_:)` 认
    public init(schemes: [String]) {
        self.schemes = Set(schemes.compactMap(Self.scheme))
    }

    /// 白名单的一条：小写、去掉「://」；不合 RFC 3986 scheme 语法（字母开头，只有字母、数字、+ - .）的、https（本来就放行）不收
    /// @see https://www.rfc-editor.org/rfc/rfc3986#section-3.1
    public static func scheme(_ entry: String) -> String? {
        var s = entry.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasSuffix("://") { s.removeLast(3) }
        guard let first = s.unicodeScalars.first, ("a"..."z").contains(first), s != "https",
              s.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0) })
        else { return nil }
        return s
    }

    public func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || schemes.contains(scheme)
    }
}
