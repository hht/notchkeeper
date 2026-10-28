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
    ]
)
