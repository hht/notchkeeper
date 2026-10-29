// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Notchkeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notchkeeper",
            dependencies: ["GuardCore", "GuardWatch"],
            path: "Sources/Notchkeeper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 出口守卫的纯逻辑：不 import SwiftUI / AppKit，不做 I/O
        .target(name: "GuardCore"),
        .testTarget(name: "GuardCoreTests", dependencies: ["GuardCore"]),
        // 出口守卫的三路观测（路由、Clash 进程、出口 IP），只做 I/O 和边界解析，不做判定
        .target(name: "GuardProbes", dependencies: ["GuardCore"]),
        .testTarget(name: "GuardProbesTests", dependencies: ["GuardProbes"]),
        // App 侧监听 guard-state.json 所在目录，变了就交给 GuardStateReader；GuardCore 管什么时候读，这里只做 I/O
        .target(name: "GuardWatch", dependencies: ["GuardCore"]),
        .testTarget(name: "GuardWatchTests", dependencies: ["GuardWatch"]),
        // 出口守卫后台进程：轮询三路探针、写 guard-state.json、verdict 变化时发分布式通知
        .executableTarget(name: "guardd", dependencies: ["GuardCore", "GuardProbes"]),
        .testTarget(name: "guarddTests", dependencies: ["guardd"]),
        // Claude Code 会话的回合状态：纯逻辑，只解码元数据，不做 I/O
        .target(name: "AgentCore"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        // 找主会话文件、只读尾部 64KB，交给 AgentCore 判定；App 进程内 2 秒轮询
        .target(name: "AgentWatch", dependencies: ["AgentCore"]),
        .testTarget(name: "AgentWatchTests", dependencies: ["AgentWatch"]),
    ]
)
