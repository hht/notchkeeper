#if DEBUG
import AppKit
import SwiftUI
import DundunCore

/// `Notchkeeper --cpu-bench <场景> [秒数]`：量盾盾左耳（20pt）+ 右耳的 CPU 和重画次数（dundun-final-spec.md §8）。
/// 只在 DEBUG 构建里有，和 --selftest 一样先进临时 HOME；不抢单实例锁、不建 AppDelegate、不碰 guardd，
/// 窗口放在所有屏幕之外，鼠标只用合成的位置（`DundunMouse.location`），不读也不动真鼠标。
/// 场景：idle（鼠标不动）、mouse（合成鼠标绕圈）、sleeping、switch（每秒切 3 次状态）、baseline（不放盾盾）。
/// 10Hz 采样本进程 CPU 时间（CLOCK_PROCESS_CPUTIME_ID）和 Canvas 绘制次数，结束时打印一行 JSON。
@MainActor
enum CpuBench {
    static func run(scenario: String, seconds: Double) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let center = CGPoint(x: -3000, y: -3000)
        let start = Date()
        switch scenario {
        case "mouse":
            // 合成鼠标：半径 160pt、4s 一圈，绕着盾盾转
            DundunMouse.location = {
                let a = Date().timeIntervalSince(start) * 2 * .pi / 4
                return CGPoint(x: center.x + 160 * cos(a), y: center.y + 160 * sin(a))
            }
        default:
            DundunMouse.location = { CGPoint(x: center.x + 200, y: center.y + 40) }
        }

        let looks: [DundunLook] = [.working, .thinking, .question, .idle, .finished, .danger, .error, .mismatch]
        let first: DundunLook = scenario == "sleeping" ? .sleeping : .idle
        let driver = DundunDriver(scale: .small, look: first)
        let ear = EarDriver()
        driver.screenCenter = { center }
        let w = NotchLayout.earWidth
        let content = HStack(spacing: 0) {
            if scenario != "baseline" {
                DundunFrameView(driver: driver, size: CGSize(width: 28, height: 28)).frame(width: 28, height: 28)
                EarFrameView(driver: ear, dot: CGPoint(x: w - 17.5, y: 16), dots: CGPoint(x: w - 20.5, y: 16))
                    .frame(width: w, height: 32)
            }
        }
        .frame(width: 80, height: 32)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.frame.size = CGSize(width: 80, height: 32)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 80, height: 32),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        if scenario != "baseline" {
            driver.setVisible(true)
            ear.setVisible(true)
            ear.set(.for(first, errorUnread: false))
        }

        var switcher: Timer?
        if scenario == "switch" {
            var i = 0
            let t = Timer(timeInterval: 1.0 / 3, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let l = looks[i % looks.count]
                    i += 1
                    driver.setLook(l)
                    ear.set(.for(l, errorUnread: l == .error))
                }
            }
            RunLoop.main.add(t, forMode: .common)
            switcher = t
        }

        func cpu() -> Double {
            var ts = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
            return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
        }
        // 先让窗口和 SwiftUI 稳定 1s 再量
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        var samples: [Double] = []
        var draws: [Int] = []
        var lastCPU = cpu(), lastWall = Date(), lastDraws = DundunStats.shared.snapshot.draws
        let s0 = DundunStats.shared.snapshot, d0 = DundunStats.shared.drawSeconds
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: min(end, lastWall.addingTimeInterval(0.1)))
            let now = Date(), c = cpu(), d = DundunStats.shared.snapshot.draws
            let dt = now.timeIntervalSince(lastWall)
            guard dt > 0.05 else { continue }
            samples.append((c - lastCPU) / dt * 100)
            draws.append(d - lastDraws)
            (lastCPU, lastWall, lastDraws) = (c, now, d)
        }
        switcher?.invalidate()
        let s1 = DundunStats.shared.snapshot, d1 = DundunStats.shared.drawSeconds
        window.close()

        let sorted = samples.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        let avg = samples.reduce(0, +) / Double(max(samples.count, 1))
        // 任意 1s（10 个连续采样）里最多画了几次
        var maxPerSec = 0
        if draws.count >= 10 { for i in 0...(draws.count - 10) { maxPerSec = max(maxPerSec, draws[i..<(i + 10)].reduce(0, +)) } }
        let r: [String: Any] = [
            "scenario": scenario, "seconds": seconds, "samples": samples.count,
            "cpuAvg": (avg * 100).rounded() / 100, "cpuP95": (p95 * 100).rounded() / 100,
            "drawsPerSec": (Double(s1.draws - s0.draws) / seconds * 100).rounded() / 100,
            "maxDrawsIn1s": maxPerSec,
            // Canvas 绘制闭包本身占的 CPU（%），和窗口在不在屏幕上无关
            "drawCPUPct": ((d1 - d0) / seconds * 100 * 1000).rounded() / 1000,
            "usPerDraw": s1.draws > s0.draws ? ((d1 - d0) / Double(s1.draws - s0.draws) * 1e6).rounded() : 0,
            "stepCommitsPerSec": (Double(s1.steps - s0.steps) / seconds * 100).rounded() / 100,
            "transitionCommits": s1.transitions - s0.transitions,
            "mouseSamplesPerSec": (Double(s1.samples - s0.samples) / seconds * 100).rounded() / 100,
            "occlusionVisible": window.occlusionState.contains(.visible),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { return false }
        print(String(decoding: json, as: UTF8.self))
        return true
    }
}
#endif
