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

import QuartzCore
import SwiftUI

// MARK: - States and emotes (Coucou IslandTypes.swift)

/// 盾盾此刻的样子。第一批只接 idle、sleeping、dizzy 和三个守卫状态；
/// working / finished / error 和第二批的几项只是配置数据，还没有任何触发。
enum DundunState: String, CaseIterable {
    case idle, sleeping, working, finished, error, dizzy
    case guardUnknown, guardMismatch, guardViolated
    case thinking, searching, approval, question, ratelimit

    var isGuard: Bool { self == .guardUnknown || self == .guardMismatch || self == .guardViolated }

    /// 实际画哪个状态：守卫 > 晕 > 犯困（idle 且鼠标久不靠近）> 调用方给的底色。
    static func shown(base: DundunState, dizzy: Bool, drowsy: Bool) -> DundunState {
        if base.isGuard { return base }
        if dizzy { return .dizzy }
        return base == .idle && drowsy ? .sleeping : base
    }

    /// 从 prev 换到 next 要不要开心一下：只有黄盾（mismatch）回到非守卫状态。红盾恢复的开心跟着恢复卡走
    /// （卡里的盾盾出场就开心，见 `MascotEmote.cheer`），这样「红 → 灰 → 正常」也开心，而且和屏幕上的卡一致；
    /// unknown 只是暂时查不到出口，回到正常不庆祝（Emily 2026-10-28）。
    static func celebrates(from prev: DundunState, to next: DundunState) -> Bool {
        prev == .guardMismatch && !next.isGuard
    }
}

enum DundunEmote: String, CaseIterable {
    case love, surprised, proud, wink, yawn, happy, annoyed
}

// MARK: - Easing functions (same as prototype: E.out, E.inOut, E.back, E.lin)

enum Ease {
    static func out(_ t: CGFloat) -> CGFloat   { 1 - pow(1 - t, 3) }
    static func inOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4*t*t*t : 1 - pow(-2*t+2, 3)/2 }
    static func back(_ t: CGFloat) -> CGFloat  { let c1: CGFloat = 1.7; let c3 = c1+1; return 1+c3*pow(t-1,3)+c1*pow(t-1,2) }
    static func lin(_ t: CGFloat) -> CGFloat   { t }
}

// MARK: - Tween key: [target, duration_ms, easing]

struct TweenKey {
    let target: CGFloat
    let duration: CGFloat    // milliseconds
    let ease: (CGFloat) -> CGFloat
}


struct Tween {
    let property: String
    var keys: [TweenKey]
    var keyIndex: Int = 0
    var from: CGFloat
    var startTime: Double    // CACurrentMediaTime() * 1000
    var onComplete: (() -> Void)? = nil
}

// MARK: - Particle

struct Particle {
    enum ParticleType { case heart, star, spark, sweat, z }
    var type: ParticleType
    var x, y, vx, vy: CGFloat
    var age: Double        // seconds
    var life: Double
    var rot: CGFloat
    var size: CGFloat
}

// MARK: - State config (mirrors STATES in prototype)

struct DundunStateCfg {
    let color: CGColor
    let tint: CGFloat
    let eye: EyeShape
    let badge: BadgeType?
    let glow: CGColor
    let glowOpacity: CGFloat
    let bounces: Bool
    let scans: Bool
    let breathes: Bool
    let zz: Bool
    let sweat: Bool
    let look: CGPoint?     // fixed look direction
    let tilt: CGFloat
}

enum EyeShape: String {
    case pill, wide, dot, line, flat, happy, closed, spiral, heart, star, tired, wink
}

enum BadgeType: Equatable {
    case dots(CGColor)
    case bang(CGColor)
    case question(CGColor)
    case dot(CGColor)
}

/// 头顶小盾牌的三种画法（Emily `prototype/mascot-port-batch1.md` 第 3 节）。
enum ShieldKind { case hollow, solid, cracked }

// MARK: - Constants

enum DundunConst {
    static let eyeW: CGFloat  = 0.25
    static let eyeH: CGFloat  = 0.27
    static let eyeSp: CGFloat = 0.37
    static let eyeP: CGFloat  = -0.12
    static let baseTop    = CGColor.hex(0xF2EEE6)
    static let baseBottom = CGColor.hex(0xCFCAC0)
    static let ink        = CGColor(red: 0.102, green: 0.082, blue: 0.071, alpha: 1)  // #1A1412
    static let amber      = CGColor.hex(0xFFB020)
    static let red        = CGColor.hex(0xFF453A)
    static let grey       = CGColor.hex(0x8E8E93)
    static let orange     = CGColor.hex(0xFF8A3D)
}

extension CGColor {
    static func hex(_ v: UInt32) -> CGColor {
        CGColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - State configs

fileprivate func cfg(_ color: CGColor, tint: CGFloat, eye: EyeShape, badge: BadgeType?, glowOpacity: CGFloat,
                 bounces: Bool = false, scans: Bool = false, breathes: Bool = false, zz: Bool = false,
                 sweat: Bool = false, look: CGPoint? = nil, tilt: CGFloat = 0) -> DundunStateCfg {
    DundunStateCfg(color: color, tint: tint, eye: eye, badge: badge, glow: color, glowOpacity: glowOpacity,
                   bounces: bounces, scans: scans, breathes: breathes, zz: zz, sweat: sweat, look: look, tilt: tilt)
}

private let blue    = CGColor(red: 0.231, green: 0.620, blue: 1, alpha: 1)       // #3B9EFF
private let purple  = CGColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1)
private let indigo  = CGColor(red: 0.388, green: 0.396, blue: 0.949, alpha: 1)
private let cyan    = CGColor(red: 0.133, green: 0.827, blue: 0.933, alpha: 1)
private let green   = CGColor(red: 0.204, green: 0.831, blue: 0.600, alpha: 1)   // #34D399
private let rate    = CGColor(red: 0.984, green: 0.573, blue: 0.235, alpha: 1)
private let slate   = CGColor(red: 0.580, green: 0.635, blue: 0.722, alpha: 1)
private let pink    = CGColor(red: 0.957, green: 0.447, blue: 0.714, alpha: 1)

private let idleCfg = DundunStateCfg(color: DundunConst.baseTop, tint: 0, eye: .pill, badge: nil,
                                     glow: CGColor(red: 1, green: 1, blue: 1, alpha: 0.35), glowOpacity: 0.25,
                                     bounces: false, scans: false, breathes: false, zz: false, sweat: false,
                                     look: nil, tilt: 0)

let DundunStates: [DundunState: DundunStateCfg] = [
    .idle:      idleCfg,
    .working:   cfg(blue, tint: 0.72, eye: .pill, badge: .dots(blue), glowOpacity: 0.55),
    .thinking:  cfg(purple, tint: 0.72, eye: .pill, badge: .dots(purple), glowOpacity: 0.5,
                    look: CGPoint(x: 0.55, y: 0.55)),
    .searching: cfg(indigo, tint: 0.72, eye: .pill, badge: .dots(indigo), glowOpacity: 0.55, scans: true),
    .approval:  cfg(cyan, tint: 0.78, eye: .wide, badge: .bang(cyan),
                    glowOpacity: 0.6, bounces: true),
    .question:  cfg(cyan, tint: 0.75, eye: .pill, badge: .question(cyan), glowOpacity: 0.55, tilt: 0.17),
    .error:     cfg(DundunConst.orange, tint: 0.78, eye: .flat, badge: .dot(DundunConst.orange), glowOpacity: 0.55),
    .finished:  cfg(green, tint: 0.35, eye: .happy, badge: .dot(green), glowOpacity: 0.5),
    .ratelimit: cfg(rate, tint: 0.72, eye: .tired, badge: .dot(rate), glowOpacity: 0.45, sweat: true),
    .sleeping:  cfg(slate, tint: 0.32, eye: .closed, badge: nil, glowOpacity: 0.2, breathes: true, zz: true),
    .dizzy:     cfg(pink, tint: 0.7, eye: .spiral, badge: nil, glowOpacity: 0.55),
    // 守卫：角标换成头顶的盾牌。unknown 只是查不到出口，身体和 idle 一样，只多一面灰色空心盾；
    // mismatch 借 approval 的眼型和弹跳，颜色用琥珀（琥珀只给 mismatch，approval 用 question 的青色）；
    // violated 借 error（红色、抖一下）。红色只给 violated。
    .guardUnknown:  idleCfg,
    .guardMismatch: cfg(DundunConst.amber, tint: 0.78, eye: .wide, badge: nil, glowOpacity: 0.6, bounces: true),
    .guardViolated: cfg(DundunConst.red, tint: 0.78, eye: .flat, badge: nil, glowOpacity: 0.55),
]

// MARK: - Head geometry (Coucou MochiOutfitDrawing.swift)

struct EyeFrame {
    let sd: CGFloat   // -1 left, +1 right
    let x, y: CGFloat
    let fx, fy: CGFloat
}

func eyeFrames(R: CGFloat, yaw: CGFloat, pitch: CGFloat) -> [EyeFrame] {
    let rx = R * 1.14, ry = R * 0.88
    return [-1.0, 1.0].map { (sd: CGFloat) in
        let eyeYaw   = sd * DundunConst.eyeSp + yaw
        let eyePitch = DundunConst.eyeP + pitch
        let cp = cos(eyePitch)
        return EyeFrame(sd: sd, x: sin(eyeYaw) * cp * rx, y: -sin(eyePitch) * ry,
                        fx: max(0.18, cos(eyeYaw)), fy: max(0.18, cp))
    }
}
