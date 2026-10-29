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
// Modified for Notchkeeper. 本文件有一部分是从带这份声明的旧 Mascot/DundunView.swift 原样搬来的（犯困、熄屏锁屏 / 右耳未读），
// 按 CLAUDE.md 的过渡期规则保留，阶段 3 重写这些代码时一起删掉。

import AppKit
import SwiftUI
import QuartzCore
import DundunCore

/// 错误没看过：进入 error 起 30 分钟内右耳亮橙点，展开过刘海（看过面板）就灭（docs/dundun.md §2）
@MainActor
final class DundunEarState: ObservableObject {
    static let shared = DundunEarState()
    static let unreadFor: TimeInterval = 30 * 60

    @Published private(set) var errorUnread = false
    private var expiry: Task<Void, Never>?
    private var last: Look?

    /// 耳朵每次出现都会报一次当前造型；只有真的从别的造型进入 error 才算新的未读
    func entered(_ look: Look) {
        defer { last = look }
        guard look == .error, last != .error else { return }
        errorUnread = true
        expiry?.cancel()
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.unreadFor))
            guard !Task.isCancelled else { return }
            self?.errorUnread = false
        }
    }

    func markRead() {
        expiry?.cancel()
        expiry = nil
        errorUnread = false
    }
}

/// 右耳的指示：44 宽、刘海高的画布，圆点圆心 (44 − 17.5, H/2)，三蓝点整组再往左 3
struct DundunEarView: NSViewRepresentable {
    let indicator: EarIndicator
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> EarLayerView {
        let w = NotchLayout.earWidth
        return EarLayerView(size: CGSize(width: w, height: height),
                            dot: CGPoint(x: w - NotchLayout.earDotInset, y: height / 2),
                            dots: CGPoint(x: w - NotchLayout.earDotInset - NotchLayout.earDotsShift, y: height / 2),
                            indicator: indicator, reduceMotion: reduceMotion)
    }

    func updateNSView(_ v: EarLayerView, context: Context) {
        v.set(indicator, reduceMotion: reduceMotion)
    }
}

/// 右耳图层：点、三蓝点、空心环，危险时红点外圈柔和脉冲（docs/dundun.md §2、§5）。换指示时 0.2s 交叉淡化
@MainActor
final class EarLayerView: MascotLayerView {
    private let dot: CGPoint
    private let dots: CGPoint
    private var indicator: EarIndicator
    private var reduceMotion: Bool
    private var shown = CALayer()
    private var ring: CAShapeLayer?

    init(size: CGSize, dot: CGPoint, dots: CGPoint, indicator: EarIndicator, reduceMotion: Bool) {
        self.dot = dot
        self.dots = dots
        self.indicator = indicator
        self.reduceMotion = reduceMotion
        super.init(frame: CGRect(origin: .zero, size: size))
        shown = make()
    }

    func set(_ i: EarIndicator, reduceMotion rm: Bool) {
        guard i != indicator || rm != reduceMotion else { return }
        indicator = i
        reduceMotion = rm
        let old = shown
        quietly {
            // 淡出被撤掉（变得看不见）时 completion 也会调
            // @see https://developer.apple.com/documentation/quartzcore/catransaction/setcompletionblock(_:)
            CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
            old.opacity = 0
            shown = make()
            if active {
                fade(old, from: 1, duration: 0.2)
                fade(shown, from: 0, duration: 0.2)
            }
        }
        stopLoops()
        if active { startLoops() }
    }

    override func layer(for part: Part) -> CALayer? { part == .ring ? ring : nil }

    override func activeChanged(_ on: Bool) {
        if on { startLoops() }
    }

    private func startLoops() {
        guard indicator == .danger else { return }
        play(Choreography.earPulse(reduceMotion: reduceMotion), at: DundunDirector.shared.epoch, loop: true)
    }

    private func make() -> CALayer {
        let c = CALayer()
        c.frame = bounds
        ring = nil
        let color = indicator.color.cg
        func circle(_ center: CGPoint, _ r: CGFloat) -> CAShapeLayer {
            let s = CAShapeLayer()
            s.frame = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            s.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r), transform: nil)
            s.fillColor = color
            c.addSublayer(s)
            return s
        }
        switch indicator {
        case .none:
            break
        case .dots:
            // 直径 3，间距 2，总宽 13
            for dx in [-5.0, 0, 5] { _ = circle(CGPoint(x: dots.x + dx, y: dots.y), 1.5) }
        case .question, .error, .mismatch:
            _ = circle(dot, 3.5)
        case .unknown:
            // 7pt 外径、1pt 描边：路径半径 3
            let s = circle(dot, 3)
            s.fillColor = CGColor.clear
            s.strokeColor = color
            s.lineWidth = 1
        case .danger:
            let r = CGFloat(reduceMotion ? EarRing.still.radius : EarRing.pulse.radius)
            let s = circle(dot, r)
            s.fillColor = CGColor.clear
            s.strokeColor = color
            s.lineWidth = 1
            s.opacity = Float(reduceMotion ? EarRing.still.opacity : EarRing.pulse.opacity)
            ring = s
            _ = circle(dot, 3.5)
        }
        let scale = window?.backingScaleFactor ?? 2
        c.sublayers?.forEach { $0.contentsScale = scale }
        layer?.addSublayer(c)
        return c
    }
}
