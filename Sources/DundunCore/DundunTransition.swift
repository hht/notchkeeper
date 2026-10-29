import CoreGraphics

// 规格 3A「状态切换过渡」：状态 A → 状态 B 的那一段。纯值类型，输入起点快照、目标状态、开始时刻、
// 是否进入危险 / 减弱动态效果，输出某时刻的渲染帧和下一次重画时刻（3A.6）。

/// 3A.3 的五种眼形过渡
public enum EyeTransition: String, CaseIterable, Sendable {
    /// 眼形相同：眼睛不动
    case none = "—"
    /// 同一相容类：直接插值
    case interp = "插"
    /// 过渡眨眼：压成横线 → 换眼形 → 展开
    case blink = "眨"
    /// 从横线出发：跳过压扁段
    case blinkUp = "眨↑"
    /// 到横线：压成横线就是终态
    case blinkDown = "眨↓"

    /// 相容类（3A.3）：A 实心圆 / 椭圆，B 弧线，C 平线 / 斜线；其它眼形自成一类
    static func family(_ k: EyeKind) -> Int? {
        switch k {
        case .round, .big: return 0
        case .sleep, .happy: return 1
        case .blink, .danger: return 2
        case .think, .focus, .spark, .err, .dizzy: return nil
        }
    }

    /// 3A.3 的规则 1–5，按眼形选
    public static func rule(from a: EyeKind, to b: EyeKind) -> EyeTransition {
        if a == b { return .none }
        if let fa = family(a), fa == family(b) { return .interp }
        if a == .blink { return .blinkUp }
        if b == .blink { return .blinkDown }
        return .blink
    }

    /// 3A.3 的 12 × 12 矩阵，行 = 从、列 = 到，顺序同 `DundunLook.allCases`
    /// （空闲 睡着 思考 工作 等你回答 完成 出错 被打断 晕 mismatch stale 危险）。逐格照抄规格
    public static let matrix: [[EyeTransition]] = [
        "— 眨 眨 眨 眨 眨 眨 眨↓ 眨 插 插 眨",
        "眨 — 眨 眨 眨 插 眨 眨↓ 眨 眨 眨 眨",
        "眨 眨 — 眨 眨 眨 眨 眨↓ 眨 眨 眨 眨",
        "眨 眨 眨 — 眨 眨 眨 眨↓ 眨 眨 眨 眨",
        "眨 眨 眨 眨 — 眨 眨 眨↓ 眨 眨 眨 眨",
        "眨 插 眨 眨 眨 — 眨 眨↓ 眨 眨 眨 眨",
        "眨 眨 眨 眨 眨 眨 — 眨↓ 眨 眨 眨 眨",
        "眨↑ 眨↑ 眨↑ 眨↑ 眨↑ 眨↑ 眨↑ — 眨↑ 眨↑ 眨↑ 插",
        "眨 眨 眨 眨 眨 眨 眨 眨↓ — 眨 眨 眨",
        "插 眨 眨 眨 眨 眨 眨 眨↓ 眨 — — 眨",
        "插 眨 眨 眨 眨 眨 眨 眨↓ 眨 — — 眨",
        "眨 眨 眨 眨 眨 眨 眨 插 眨 眨 眨 —",
    ].map { row in row.split(separator: " ").map { EyeTransition(rawValue: String($0))! } }

    public static func matrix(from a: DundunLook, to b: DundunLook) -> EyeTransition {
        let all = DundunLook.allCases
        return matrix[all.firstIndex(of: a)!][all.firstIndex(of: b)!]
    }
}

public struct DundunTransition: Sendable {
    public let start: Double
    public let duration: Double
    public let curve: Curve
    public let from: DundunRender
    public let to: DundunLook
    public let scale: DundunScale
    public let mode: EyeTransition
    /// 减弱动态效果：只留颜色过渡（3A.4）
    public let colorOnly: Bool

    public var end: Double { start + duration }

    /// - Parameter from: 切换那一刻屏幕上的渲染帧（可能本身就是过渡中途的插值结果）
    public init(from: DundunRender, to: DundunLook, at start: Double, scale: DundunScale, reduceMotion: Bool) {
        self.from = from
        self.to = to
        self.start = start
        self.scale = scale
        colorOnly = reduceMotion
        if reduceMotion {
            duration = 0.15
            curve = .easeInOut
        } else if to == .danger && from.look != .danger {
            // 进入危险：整段 0.2s easeOut，分项按比例缩短（3A.1、3A.3 规则 6）
            duration = 0.2
            curve = .easeOut
        } else {
            duration = 0.3
            curve = .easeInOut
        }
        // 3A.4：正处在过渡眨眼的闭眼阶段时被打断，直接从横线展开（相当于眨↑）
        if from.closing {
            mode = to.eyes == .blink ? .blinkDown : .blinkUp
        } else {
            mode = EyeTransition.rule(from: from.eyeKind, to: to.eyes)
        }
    }

    public func isActive(at t: Double) -> Bool { t < end }

    /// 过渡窗口内最高 60fps 连续重画（3A.5）；窗口结束后 nil，交回步进调度
    public func nextRedraw(after t: Double) -> Double? {
        guard t < end else { return nil }
        return Frames60.next(after: t, start: start, end: end)
    }

    /// 压扁段占整段的比例：0.12 / 0.3 = 0.08 / 0.2 = 0.4
    static let squash = 0.4
    /// 旧装饰淡出段：0.1 / 0.3（进入危险按比例缩）
    static let fade = 1.0 / 3

    /// t 时刻的帧。target = 新状态第 0 帧（新状态的 0ms = 过渡结束时刻，3A.1）
    public func render(at t: Double, target: DundunRender) -> DundunRender {
        let u = max(0, min(1, (t - start) / duration))
        if u >= 1 { return target }
        let p = curve(u)
        var out = target
        out.colors = BodyColors.mix(from.colors, target.colors, p)
        if colorOnly { return out }

        // 位置和姿态：从当前值过渡到新状态第 0 帧（3A.2）
        out.dx = from.dx + (target.dx - from.dx) * CGFloat(p)
        out.dy = from.dy + (target.dy - from.dy) * CGFloat(p)
        var r0 = from.rotation.truncatingRemainder(dividingBy: 360)
        if r0 > 180 { r0 -= 360 }
        if r0 < -180 { r0 += 360 }
        out.rotation = r0 + (target.rotation - r0) * p

        eyes(&out, u: u, p: p, target: target)
        decos(&out, u: u, target: target)
        return out
    }

    private func eyes(_ out: inout DundunRender, u: Double, p: Double, target: DundunRender) {
        func offset(_ a: EyeDraw?, _ b: EyeDraw?) -> CGPoint {
            let o0 = a?.offset ?? .zero, o1 = b?.offset ?? .zero
            return CGPoint(x: o0.x + (o1.x - o0.x) * CGFloat(p), y: o0.y + (o1.y - o0.y) * CGFloat(p))
        }
        func pair(_ f: (EyeDraw?, EyeDraw?) -> EyeDraw?) {
            out.left = f(from.left, target.left)
            out.right = f(from.right, target.right)
        }
        var mode = self.mode
        if mode == .none || mode == .interp {
            // 几何对不上（比如快照是小动作的逐帧眼、或者少画了一只）就退回过渡眨眼
            let ok = [(from.left, target.left), (from.right, target.right)].allSatisfy { a, b in
                guard let a, let b else { return false }
                return EyeGeom.lerp(a.geom, b.geom, 0.5, scale) != nil
            }
            if !ok { mode = .blink }
        }
        switch mode {
        case .none, .interp:
            pair { a, b in
                guard let a, let b, let g = EyeGeom.lerp(a.geom, b.geom, p, scale) else { return b }
                return EyeDraw(geom: g, offset: offset(a, b), close: a.close * (1 - p))
            }
            out.closing = false
        case .blink, .blinkUp, .blinkDown:
            let s = Self.squash
            if u < s {
                // 闭眼段：旧眼压成 1pt 横线（眨↑ 已经是横线，保持）
                let k = mode == .blinkUp ? 1 : Curve.easeIn(u / s)
                pair { a, b in
                    guard let a else { return nil }
                    return EyeDraw(geom: a.geom, offset: offset(a, b), close: a.close + (1 - a.close) * k)
                }
                out.closing = true
            } else if mode == .blinkDown {
                // 到横线：压成横线就是终态，0.12–0.3s 不再变
                pair { a, b in b.map { EyeDraw(geom: $0.geom, offset: offset(a, $0), close: 0) } }
                out.closing = false
            } else {
                // 展开段：换成新眼形的压扁版，easeOut 展开
                let k = 1 - Curve.easeOut((u - s) / (1 - s))
                pair { a, b in b.map { EyeDraw(geom: $0.geom, offset: offset(a, $0), close: k) } }
                out.closing = false
            }
        }
    }

    private func decos(_ out: inout DundunRender, u: Double, target: DundunRender) {
        let f = Self.fade
        let want = target.decos.first
        var list: [DecoDraw] = []
        // 旧装饰：0–0.1s 线性淡出
        for d in from.decos where d.deco.id != want?.deco.id {
            let o = d.opacity * (1 - min(1, u / f))
            if o > 0 { list.append(DecoDraw(deco: d.deco, opacity: o, scale: d.scale)) }
        }
        if let want {
            if let same = from.decos.first(where: { $0.deco.id == want.deco.id }) {
                // 同一个装饰：不动（如果快照里它正在淡入，就从当前值接着走到 1）
                let p = Curve.easeOut(u)
                list.append(DecoDraw(deco: want.deco, opacity: same.opacity + (1 - same.opacity) * p, scale: same.scale + (1 - same.scale) * p))
            } else if u > f + Track.eps {
                // 新装饰：0.1s 起 0.2s easeOut，缩放 80% → 100%、不透明度 0 → 1
                let v = Curve.easeOut((u - f) / (1 - f))
                list.append(DecoDraw(deco: want.deco, opacity: v, scale: 0.8 + 0.2 * v))
            }
        }
        out.decos = list
    }
}

/// 过渡帧的时刻：从过渡开始按 1/60 s 的网格取（不累加，避免误差），最后一帧落在 end 上
enum Frames60 {
    static func next(after t: Double, start: Double, end: Double) -> Double? {
        guard t < end - Track.eps else { return nil }
        let k = ((t - start) * 60 + Track.eps * 60).rounded(.down) + 1
        let n = start + k / 60
        return n >= end - Track.eps ? end : n
    }
}
