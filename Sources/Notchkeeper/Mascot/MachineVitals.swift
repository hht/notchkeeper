// Ported from Coucou (https://github.com/louis-cfm/coucou @ 47d1c2d).
//
// MIT License
//
// Copyright (c) 2026 Louis Raillé
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Modified for Notchkeeper. Character used for personal, private use only — see AGENTS.md:49.

import Combine
import Darwin
import Foundation
import IOKit.ps

/// How the Mac is doing, as 盾盾 shows it: a busy processor makes him sweat, a warm Mac
/// flushes him, short memory puffs him up, a low battery makes him tired, then asleep.
///
/// It only reads while a 盾盾 is on screen (each canvas holds it open while it is visible),
/// every few seconds. Everything stays on the Mac and nothing is logged.
@MainActor
final class MachineVitals: ObservableObject {
    static let shared = MachineVitals()

    /// What 盾盾 shows, read by his canvases every frame.
    @Published private(set) var mood = DundunMood.calm

    /// Settings → 「盾盾感知 Mac 状态」 (`NKConfig.dundunFeelsTheMac`).
    private var enabled: Bool { ConfigStore.shared.config.dundunFeelsTheMac }

    private var timer: Timer?
    private var thermalObserver: NSObjectProtocol?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var memoryLevel: CGFloat = 0
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var cpu: Double = 0
    private var busySamples = 0
    private var viewers = 0
    private var configSub: AnyCancellable?

    private init() {
        configSub = ConfigStore.shared.$config.map(\.dundunFeelsTheMac).removeDuplicates()
            .dropFirst().sink { [weak self] on in
                // @Published sends before the new value is stored, so it is passed in.
                MainActor.assumeIsolated { self?.refreshRunning(enabled: on) }
            }
    }

    /// A canvas came on screen. Pair every call with `release()`.
    func retain() { viewers += 1; refreshRunning() }

    /// A canvas left the screen.
    func release() { viewers = max(0, viewers - 1); refreshRunning() }

    private func refreshRunning(enabled: Bool? = nil) {
        let enabled = enabled ?? self.enabled
        let run = enabled && viewers > 0
        if run, timer == nil {
            lastTicks = nil
            watchMemory()
            thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            sample()
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !run, timer != nil {
            timer?.invalidate()
            timer = nil
            thermalObserver.map(NotificationCenter.default.removeObserver)
            thermalObserver = nil
            memoryPressure?.cancel()
            memoryPressure = nil
            if !enabled { mood = .calm }
        }
    }

    // MARK: - Reading the Mac

    private func sample() {
        guard enabled else { return }
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
            }
            lastTicks = ticks
        }
        // Two readings in a row above 80 %: a short spike does not make him sweat.
        busySamples = cpu >= 0.8 ? busySamples + 1 : 0

        var next = DundunMood()
        next.busy = busySamples >= 2 ? CGFloat(min(1, (cpu - 0.6) / 0.3)) : 0
        switch ProcessInfo.processInfo.thermalState {
        case .fair:     next.hot = 0.4
        case .serious:  next.hot = 0.8
        case .critical: next.hot = 1
        default:        next.hot = 0
        }
        next.full = memoryLevel
        if let b = Self.readBattery(), !b.onPower {
            next.tired = b.percent < 20 ? 1 : 0
            next.asleep = b.percent < 10
        }
        if next != mood { mood = next }
    }

    private func watchMemory() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressure?.data else { return }
                self.memoryLevel = event.contains(.critical) ? 1 : (event.contains(.warning) ? 0.6 : 0)
                self.sample()
            }
        }
        source.resume()
        memoryPressure = source
    }

    /// All the processor time since boot: (busy, total) ticks over every core.
    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// The internal battery: its charge and whether the Mac is plugged in. Nil on a desktop Mac.
    private static func readBattery() -> (percent: Int, onPower: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else { return nil }
        for source in list as Array {
            guard let desc = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onPower = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (Int((Double(current) / Double(max) * 100).rounded()), onPower)
        }
        return nil
    }
}
