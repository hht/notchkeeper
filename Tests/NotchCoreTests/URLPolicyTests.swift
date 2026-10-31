import Foundation
import Testing
@testable import NotchCore

/// 卡片上「打开 URL」默认只放行 https，用户在设置里加的 scheme 也放行（用户 10-31）。
/// 自定义 scheme 能拉起别的 App 执行动作，所以不在白名单里的一律拦下
@Suite struct URLPolicyRules {
    @Test(arguments: ["https://example.com/x", "HTTPS://example.com"])
    func httpsAlwaysAllowed(_ s: String) {
        #expect(URLPolicy(schemes: []).allows(URL(string: s)!))
    }

    @Test(arguments: ["http://example.com", "file:///etc/hosts", "javascript:alert(1)", "raycast://extensions/x", "btt://trigger_named/?x"])
    func othersBlockedByDefault(_ s: String) {
        #expect(!URLPolicy(schemes: []).allows(URL(string: s)!))
    }

    /// 白名单里写成「Raycast」「raycast://」都算同一个 scheme
    @Test(arguments: ["raycast", "Raycast", "raycast://", " raycast "])
    func whitelistedSchemeAllowed(_ entry: String) {
        let policy = URLPolicy(schemes: [entry])
        #expect(policy.allows(URL(string: "raycast://extensions/x")!))
        #expect(!policy.allows(URL(string: "btt://x")!))
    }
}

/// 白名单写错（空条目）不能变成放行；几种怪写法的结果钉住
@Suite struct URLPolicyEdges {
    @Test(arguments: ["", "://", " "])
    func emptyEntryAllowsNothing(_ entry: String) {
        #expect(!URLPolicy(schemes: [entry]).allows(URL(string: "://x")!))
    }

    @Test func oddURLs() {
        let p = URLPolicy(schemes: [])
        #expect(!p.allows(URL(string: "javascript:https://x")!))
        #expect(URL(string: "HTTPS ://x") == nil)
        // 没有 host 的 https 放行：最多是浏览器打开一个坏链接
        #expect(p.allows(URL(string: "https:")!))
    }
}
