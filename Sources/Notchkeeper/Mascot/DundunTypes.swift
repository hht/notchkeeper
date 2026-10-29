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
// Modified for Notchkeeper.

import CoreGraphics

// MARK: - States (Coucou IslandTypes.swift)

/// 盾盾此刻的状态（画成哪个造型见 `DundunState.look`，造型表见 docs/dundun.md §2）。
/// 守卫的四个来自 guardd；空闲 / 睡着 / 晕由盾盾自己定；其余由「状态测试」或之后接上的 agent 事件给。
enum DundunState {
    case idle, sleeping, working, finished, error, dizzy
    case guardUnknown, guardMismatch, guardViolated
    case thinking, question
    case interrupted, guardStale

    var isGuard: Bool { self == .guardUnknown || self == .guardMismatch || self == .guardViolated || self == .guardStale }

    /// 实际画哪个状态：守卫 > 晕 > 犯困（idle 且鼠标久不靠近）> 调用方给的底色。
    static func shown(base: DundunState, dizzy: Bool, drowsy: Bool) -> DundunState {
        if base.isGuard { return base }
        if dizzy { return .dizzy }
        return base == .idle && drowsy ? .sleeping : base
    }
}

// MARK: - Constants

/// 守卫提示用的颜色（卡片、刘海边框）。盾盾自己的颜色在 DundunCore（§2.3）
enum DundunConst {
    static let amber = CGColor.hex(0xFFB020)
    static let red   = CGColor.hex(0xFF453A)
}

extension CGColor {
    static func hex(_ v: UInt32) -> CGColor {
        CGColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
