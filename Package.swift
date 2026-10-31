// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Notchkeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notchkeeper",
            dependencies: ["AgentCore", "GuardCore", "GuardWatch", "MascotCore", "NotchCore"],
            path: "Sources/Notchkeeper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // App 外壳里还没挪进核心 target 的逻辑（目前是 config.json 的读写）
        .testTarget(name: "NotchkeeperTests", dependencies: ["Notchkeeper"]),
        // 出口守卫的纯逻辑：不 import SwiftUI / AppKit，不做 I/O
        .target(name: "GuardCore"),
        .testTarget(name: "GuardCoreTests", dependencies: ["GuardCore"]),
        // 出口守卫的三路观测（路由、Clash 进程、出口 IP），只做 I/O 和边界解析，不做判定
        .target(name: "GuardProbes", dependencies: ["GuardCore"]),
        .testTarget(name: "GuardProbesTests", dependencies: ["GuardProbes"]),
        // App 侧监听 guard-state.json 所在目录，变了就交给 GuardStateReader；GuardCore 管什么时候读，这里只做 I/O
        .target(name: "GuardWatch", dependencies: ["GuardCore"]),
        .testTarget(name: "GuardWatchTests", dependencies: ["GuardWatch"]),
        // 出口守卫后台进程：轮询三路探针、写 guard-state.json（App 用 GuardWatch 监听这个文件）
        .executableTarget(name: "guardd", dependencies: ["GuardCore", "GuardProbes"]),
        .testTarget(name: "guarddTests", dependencies: ["guardd"]),
        // 盾盾此刻是什么造型、做什么动作：造型数据、眼形补间、球面位置、动作编排（[Track]）、空闲调度、跟随鼠标。纯值类型，只依赖 CoreGraphics
        .target(name: "MascotCore"),
        .testTarget(name: "MascotCoreTests", dependencies: ["MascotCore"]),
        // Claude Code 会话此刻在什么状态、回合什么时候结束：解析 ~/.claude/sessions/<pid>.json、跟踪回合（docs/agent-integration.md）。纯值类型，不读目录、不查进程
        .target(name: "AgentCore"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        // 刘海此刻放哪张卡、放多久、放出来时响不响：红卡一层 + 临时卡队列（docs/ui.md「卡片」）；守卫读数画成什么、红卡挂上还是撤掉（docs/egress-guard.md）。纯值类型，不知道卡长什么样、不放声音、不起定时器
        .target(name: "NotchCore", dependencies: ["GuardCore", "MascotCore"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore", "GuardCore", "MascotCore"]),
    ]
)
