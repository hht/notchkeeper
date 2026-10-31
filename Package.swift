// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Notchkeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notchkeeper",
            dependencies: ["AgentCore", "GuardCore", "GuardWatch", "MascotCore", "NotchCore", "PluginCore"],
            path: "Sources/Notchkeeper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // App 外壳里离不开 AppKit、SwiftUI 或真文件的部分（config.json 读写、Ghostty 跳转、mod 安装、视图量高度等）
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
        // Pip 此刻是什么造型、做什么动作：造型数据、眼形补间、球面位置、动作编排（[Track]）、空闲调度、犯困 / 回正 / 晕的时钟、跟随鼠标。纯值类型，只依赖 CoreGraphics
        .target(name: "MascotCore"),
        .testTarget(name: "MascotCoreTests", dependencies: ["MascotCore"]),
        // Claude Code 会话此刻在什么状态、回合什么时候结束：解析 ~/.claude/sessions/<pid>.json、跟踪回合（docs/agent-integration.md）。纯值类型，不读目录、不查进程
        .target(name: "AgentCore"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        // 卡上写什么、刘海此刻放哪张卡、放多久、放出来时响不响：红卡一层 + 临时卡队列（docs/ui.md「卡片」）；守卫读数画成什么、红卡挂上还是撤掉（docs/egress-guard.md）；
        // 各插件多急、收起时谁上位、面板一行画什么；刘海三种形态各多大；config.json 有哪些设置。纯值类型，不知道卡长什么样、不放声音、不起定时器
        .target(name: "NotchCore", dependencies: ["AgentCore", "GuardCore", "MascotCore"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore", "AgentCore", "GuardCore", "MascotCore"]),
        // 外部插件发来的一条消息合不合法、变成哪张卡或面板里哪一行：解析收件箱里的消息和插件登记、限流、过期，跟踪活动。纯值类型，不读目录
        .target(name: "PluginCore", dependencies: ["GuardCore", "NotchCore"]),
        .testTarget(name: "PluginCoreTests", dependencies: ["PluginCore", "NotchCore"]),
        // 外部插件的命令行：`nk notify …` 把一张卡写进收件箱（先写 tmp/ 再 rename 到 new/），格式由 PluginCore 校验
        .executableTarget(name: "nk", dependencies: ["PluginCore"]),
        .testTarget(name: "nkTests", dependencies: ["nk", "PluginCore", "NotchCore"]),
        // 终端插件（Resources/plugins/terminal/notchkeeper.zsh）：用真的 zsh 跑，假的 nk 记下参数
        .testTarget(name: "TerminalPluginTests"),
    ]
)
