// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Notchkeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Notchkeeper",
            path: "Sources/Notchkeeper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 出口守卫的纯逻辑：不 import SwiftUI / AppKit，不做 I/O
        .target(name: "GuardCore"),
        .testTarget(name: "GuardCoreTests", dependencies: ["GuardCore"]),
        // 出口守卫的三路观测（路由、Clash 进程、出口 IP），只做 I/O 和边界解析，不做判定
        .target(name: "GuardProbes", dependencies: ["GuardCore"]),
        .testTarget(name: "GuardProbesTests", dependencies: ["GuardProbes"]),
        // 出口守卫后台进程：轮询三路探针、写 guard-state.json、verdict 变化时发分布式通知
        .executableTarget(name: "guardd", dependencies: ["GuardCore", "GuardProbes"]),
        .testTarget(name: "guarddTests", dependencies: ["guardd"]),
    ]
)
