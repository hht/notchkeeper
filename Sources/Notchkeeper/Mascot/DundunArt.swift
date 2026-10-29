import SwiftUI
import DundunCore

// 盾盾的画法（dundun-final-spec.md §1.1、§2.1、§2.2、§2.3、§10）：Canvas + Path，身体是正圆 + 竖直线性渐变，
// 没有描边、高光、阴影、盾牌。路径逐字照抄规格里的 SVG，旋转只转渐变端点和眼睛，圆本身不转。
// DundunCore 给出每一帧画什么（纯值），这里只管怎么画。

// MARK: - SVG path

/// 规格里的 SVG path 只用到 M L H V Q A Z（含小写相对形式），这里照 SVG 1.1 §8.3 解析；
/// 椭圆弧按附录 F.6.5 换成圆心参数，再用变换过的单位圆弧画出来。
/// @see https://www.w3.org/TR/SVG11/paths.html#PathData
/// @see https://www.w3.org/TR/SVG11/implnote.html#ArcConversionEndpointToCenter
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var tokens = tokenize(d)[...]
        var cur = CGPoint.zero, start = CGPoint.zero
        var cmd: Character = "M"
        func num() -> CGFloat {
            guard case .number(let v)? = tokens.first else { return 0 }
            tokens.removeFirst()
            return v
        }
        while let t = tokens.first {
            if case .command(let c) = t { cmd = c; tokens.removeFirst() }
            let rel = cmd.isLowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            switch cmd.uppercased().first! {
            case "M":
                cur = pt(num(), num()); start = cur
                path.move(to: cur)
                cmd = rel ? "l" : "L"   // M 后面跟着的坐标对按 L 处理
            case "L": cur = pt(num(), num()); path.addLine(to: cur)
            case "H": let x = num(); cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
            case "V": let y = num(); cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
            case "Q":
                let c = pt(num(), num()), e = pt(num(), num())
                path.addQuadCurve(to: e, control: c); cur = e
            case "A":
                let rx = num(), ry = num(), phi = num(), large = num() != 0, sweep = num() != 0
                let e = pt(num(), num())
                arc(&path, from: cur, to: e, rx: rx, ry: ry, phi: phi * .pi / 180, large: large, sweep: sweep)
                cur = e
            case "Z":
                path.closeSubpath(); cur = start
            default:
                tokens.removeFirst()
            }
            if cmd == "Z" || cmd == "z" {
                // Z 不带参数；后面要是直接跟数字就不合法，丢掉
                while case .number? = tokens.first { tokens.removeFirst() }
            }
        }
        return path
    }

    private enum Token { case command(Character), number(CGFloat) }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        var s = ""
        func flush() { if let v = Double(s) { out.append(.number(CGFloat(v))) }; s = "" }
        for ch in d {
            if ch.isLetter && ch != "e" {
                flush(); out.append(.command(ch))
            } else if ch == "-" && !s.isEmpty && s.last != "e" {
                flush(); s = "-"
            } else if ch == "." && s.contains(".") {
                flush(); s = "."
            } else if ch == " " || ch == "," {
                flush()
            } else {
                s.append(ch)
            }
        }
        flush()
        return out
    }

    private static func arc(_ path: inout Path, from p1: CGPoint, to p2: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, phi: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        guard rx > 0, ry > 0, p1 != p2 else { path.addLine(to: p2); return }
        let c = cos(phi), s = sin(phi)
        let hx = (p1.x - p2.x) / 2, hy = (p1.y - p2.y) / 2
        let x1 = c * hx + s * hy, y1 = -s * hx + c * hy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let k = (large == sweep ? -1 : 1) * sqrt(max(0, num / den))
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = c * cx1 - s * cy1 + (p1.x + p2.x) / 2
        let cy = s * cx1 + c * cy1 + (p1.y + p2.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat { atan2(ux * vy - uy * vx, ux * vx + uy * vy) }
        let t1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var dt = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi }
        if sweep && dt < 0 { dt += 2 * .pi }
        let m = CGAffineTransform(scaleX: rx, y: ry).concatenating(CGAffineTransform(rotationAngle: phi)).concatenating(CGAffineTransform(translationX: cx, y: cy))
        path.addRelativeArc(center: .zero, radius: 1, startAngle: .radians(Double(t1)), delta: .radians(Double(dt)), transform: m)
    }
}

// MARK: - 形状

/// 一块要画的形状：路径 + 填充或描边
struct ArtShape {
    enum Style {
        case fill
        case stroke(CGFloat, cap: CGLineCap = .butt, join: CGLineJoin = .miter)
    }
    var path: Path
    var style: Style
    var color: Color
    var opacity: Double = 1

    var isStroke: Bool { if case .stroke = style { return true } else { return false } }

    func draw(in ctx: GraphicsContext) {
        var c = ctx
        c.opacity *= opacity
        switch style {
        case .fill: c.fill(path, with: .color(color))
        case .stroke(let w, let cap, let join): c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: cap, lineJoin: join))
        }
    }
}

extension RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}

private func hex(_ v: UInt32) -> Color { RGB(hex: v).color }
private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, rx: CGFloat = 0) -> Path {
    rx > 0 ? Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: rx) : Path(CGRect(x: x, y: y, width: w, height: h))
}
private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

/// 墨色 #16171A（§1.1）
let dundunInk = hex(0x16171A)

// MARK: - 眼睛（§2.1）

enum EyeArt {
    /// 一只眼的形状，坐标是 20pt 画布单位（40pt 用同一套单位，画的时候整体 ×2）
    static func shapes(_ geom: EyeGeom, _ scale: DundunScale) -> [ArtShape] {
        let large = scale == .large
        func fill(_ p: Path) -> [ArtShape] { [ArtShape(path: p, style: .fill, color: dundunInk)] }
        func stroke(_ p: Path, _ w: CGFloat, cap: CGLineCap = .round, join: CGLineJoin = .round) -> [ArtShape] {
            [ArtShape(path: p, style: .stroke(w, cap: cap, join: join), color: dundunInk)]
        }
        switch geom {
        case .pill(let r):
            return fill(Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2))
        case .ellipse(let c, let rx, let ry):
            return fill(Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry)))
        case .quad(let a, let b, let c, let d, let radius):
            let xs = [a.x, b.x, c.x, d.x], ys = [a.y, b.y, c.y, d.y]
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let axis = Set(xs).count == 2 && Set(ys).count == 2
            if radius > 0 && axis { return fill(Path(roundedRect: box, cornerRadius: radius)) }
            var p = Path()
            p.addLines([a, b, c, d]); p.closeSubpath()
            return fill(p)
        case .polyline(let a, let b, let c, let d):
            var p = Path()
            p.addLines([a, b, c, d])
            return stroke(p, 1)
        case .curve(let a, let k, let b):
            var p = Path()
            p.move(to: a); p.addQuadCurve(to: b, control: k)
            return stroke(p, 0.9)
        case .flip(.rect(let r)):
            return fill(Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2))
        case .flip(.ellipse(let c, let a, let b, let cc, let d)):
            let m = CGAffineTransform(a: a, b: b, c: cc, d: d, tx: c.x, ty: c.y)
            return fill(Path(ellipseIn: CGRect(x: -1.05, y: -1.55, width: 2.1, height: 3.1)).applying(m))
        case .art(let kind, let right):
            return art(kind, right: right, large: large)
        }
    }

    /// 不相容眼形，逐字照抄 §2.1 的 SVG；右眼一般是左眼 +7（err 右眼是镜像，另给路径）
    private static func art(_ kind: EyeKind, right: Bool, large: Bool) -> [ArtShape] {
        let dx: CGFloat = right ? 7 : 0
        let shift = CGAffineTransform(translationX: dx, y: 0)
        func svg(_ d: String) -> Path { SVGPath.parse(d).applying(shift) }
        func fill(_ p: Path) -> [ArtShape] { [ArtShape(path: p, style: .fill, color: dundunInk)] }
        func stroke(_ p: Path, _ w: CGFloat, cap: CGLineCap = .round, join: CGLineJoin = .round) -> [ArtShape] {
            [ArtShape(path: p, style: .stroke(w, cap: cap, join: join), color: dundunInk)]
        }
        switch (kind, large) {
        case (.think, false):
            return right ? stroke(SVGPath.parse("M16 17.5 L19 16.5"), 1) : fill(rect(10, 15, 2, 2, rx: 1))
        case (.think, true):
            return right ? stroke(SVGPath.parse("M15.9 17.55 L19.1 16.45"), 0.9) : fill(circle(11.05, 15.95, 1.05))
        case (.focus, false): return fill(svg("M8.5 15.5 H12.5 V16.5 A2 2 0 0 1 8.5 16.5 Z"))
        case (.focus, true): return fill(svg("M8.4 15.55 H12.6 V16.45 A2.1 2.05 0 0 1 8.4 16.45 Z"))
        case (.spark, false): return fill(svg("M8.5 16.5 H10 V15 H11 V16.5 H12.5 V17.5 H11 V19 H10 V17.5 H8.5 Z"))
        case (.spark, true): return fill(svg("M10.5 15 Q10.85 16.65 12.5 17 Q10.85 17.35 10.5 19 Q10.15 17.35 8.5 17 Q10.15 16.65 10.5 15 Z"))
        case (.err, false):
            return stroke(SVGPath.parse(right ? "M18.5 15.5 L16.5 17 L18.5 18.5" : "M9.5 15.5 L11.5 17 L9.5 18.5"), 1)
        case (.err, true):
            return stroke(SVGPath.parse(right ? "M18.55 15.55 L16.45 17 L18.55 18.45" : "M9.45 15.55 L11.55 17 L9.45 18.45"), 0.85)
        case (.dizzy, false):
            return stroke(rect(9.5 + dx, 16, 2, 2, rx: 1), 1)
        case (.dizzy, true):
            let x = right ? "17.5" : "10.5"
            return stroke(SVGPath.parse("M\(x) 17 m.35 0 a.35 .35 0 1 0 -.7 0 a.7 .7 0 1 0 1.4 0 a1.05 1.05 0 1 0 -2.1 0 a1.4 1.4 0 1 0 2.8 0"), 0.55, cap: .round, join: .miter)
        default:
            // 相容类眼形不走这里（EyeGeom.of 给的是参数化几何）
            return shapes(EyeGeom.of(kind, large ? .large : .small, right: right), large ? .large : .small)
        }
    }

    /// 过渡眨眼的压扁（3A.3）：绕眼睛外框的竖直中心压高度；close = 1 时实心眼剩 1pt（40pt .9）横线、描边眼压成一条线。
    /// 20pt 压扁后的高度落在 0.5pt 网格上（3A.2）
    static func squashed(_ shapes: [ArtShape], close: Double, scale: DundunScale) -> [ArtShape] {
        guard close > 0, let first = shapes.first else { return shapes }
        let box = shapes.dropFirst().reduce(first.path.boundingRect) { $0.union($1.path.boundingRect) }
        guard box.height > 0 else { return shapes }
        let line: CGFloat = shapes.allSatisfy(\.isStroke) ? 0 : (scale == .small ? 1 : 0.9)
        var h = box.height + (min(line, box.height) - box.height) * CGFloat(close)
        if scale == .small { h = (h * 2).rounded() / 2 }
        let sy = max(h, 0.001) / box.height
        let m = CGAffineTransform(translationX: 0, y: box.midY).scaledBy(x: 1, y: sy).translatedBy(x: 0, y: -box.midY)
        return shapes.map { var s = $0; s.path = s.path.applying(m); return s }
    }
}

// MARK: - 装饰（§2.2）

enum DecoArt {
    static func shapes(_ deco: DundunDeco, _ scale: DundunScale) -> [ArtShape] {
        let large = scale == .large
        switch deco {
        case .none:
            return []
        case .sleeping(let a, let b, let c):
            let w: CGFloat = large ? 0.8 : 1
            let paths = large
                ? ["M20 4.9 H23 L20 7.1 H23", "M23.5 1.4 H27.5 L23.5 4.6 H27.5", "M28.5 -3.6 H33.5 L28.5 0.6 H33.5"]
                : ["M20 5 H23 L20 7 H23", "M23.5 1.5 H27.5 L23.5 4.5 H27.5"]
            return zip(paths, [a, b, c]).compactMap { d, o in
                o.map { ArtShape(path: SVGPath.parse(d), style: .stroke(w, cap: .butt, join: .round), color: hex(0xB9C3F0), opacity: $0) }
            }
        case .thinking(let lit):
            // 云是一组：几个圆和矩形叠在一起、整组 .95 不透明度，所以合成一条路径（同向非零绕数 = 并集）填一次
            var cloud = Path()
            cloud.addPath(circle(22, 4.5, 1.5)); cloud.addPath(circle(24.5, 3.5, 2)); cloud.addPath(circle(26.5, 4.5, 1.5))
            cloud.addRect(CGRect(x: 22, y: 4, width: 4.5, height: 2))
            var out = [ArtShape(path: cloud, style: .fill, color: hex(0xE9E2FB), opacity: 0.95),
                       ArtShape(path: circle(19.5, 6.5, 1), style: .fill, color: hex(0xE9E2FB), opacity: 0.95)]
            for i in 0..<3 {
                let dot = large ? circle(22.5 + 2 * CGFloat(i), 4.6, 0.55) : rect(22 + 2 * CGFloat(i), 4, 1, 1)
                out.append(ArtShape(path: dot, style: .fill, color: hex(lit == i ? 0x7C5CE0 : 0xBFB2EE)))
            }
            return out
        case .question(let s):
            var bubble = Path()
            bubble.addPath(rect(20, 1, 7.5, 5, rx: 2))
            bubble.addPath(SVGPath.parse("M21 5.5 L23 5.5 L20.5 8 Z"))
            var out = [ArtShape(path: bubble, style: .fill, color: hex(0xCFF3F7))]
            if large {
                out.append(ArtShape(path: SVGPath.parse("M22.75 2.75 Q22.9 1.85 23.85 1.85 Q24.85 1.85 24.85 2.75 Q24.85 3.35 24.1 3.7 Q23.75 3.9 23.75 4.35"),
                                    style: .stroke(0.55, cap: .round, join: .round), color: dundunInk))
                out.append(ArtShape(path: circle(23.75, 5.15, 0.32), style: .fill, color: dundunInk))
            }
            return scaled(out, CGFloat(s), about: CGPoint(x: 21, y: 6.5))
        case .finished(let big, let small, let bigRadius):
            var out: [ArtShape] = []
            if let big {
                let star = SVGPath.parse("M24.5 1 L25.250 2.750 L27 3.5 L25.250 4.250 L24.5 6 L23.750 4.250 L22 3.5 L23.750 2.750 Z")
                out += scaled([ArtShape(path: star, style: .fill, color: hex(0xFFD66B), opacity: big)], CGFloat(bigRadius / 2.5), about: CGPoint(x: 24.5, y: 3.5))
            }
            if let small {
                let star = SVGPath.parse("M21 5.25 L21.375 6.125 L22.25 6.5 L21.375 6.875 L21 7.75 L20.625 6.875 L19.75 6.5 L20.625 6.125 Z")
                out.append(ArtShape(path: star, style: .fill, color: hex(0xFFD66B), opacity: small))
            }
            return out
        case .error(let op):
            return [ArtShape(path: SVGPath.parse("M22.5 2 L26.5 6 M26.5 2 L22.5 6"), style: .stroke(large ? 1.1 : 1.5, cap: .round, join: .round), color: hex(0xFF8A3D), opacity: op)]
        case .mismatch(let on):
            guard on else { return [] }
            let tri = SVGPath.parse("M24.5 1.5 L28 7.5 L21 7.5 Z")
            var out = [ArtShape(path: tri, style: .fill, color: hex(0xFFB020))]
            if large { out.append(ArtShape(path: tri, style: .stroke(0.5, cap: .butt, join: .round), color: hex(0xFFB020))) }
            out.append(ArtShape(path: rect(24, 3.5, 1, 2), style: .fill, color: dundunInk))
            out.append(ArtShape(path: rect(24, 6, 1, 1), style: .fill, color: dundunInk))
            return out
        case .stale:
            var p = Path()
            p.addRect(CGRect(x: 22, y: 1.5, width: 5, height: 1)); p.addRect(CGRect(x: 22, y: 6.5, width: 5, height: 1))
            p.addPath(SVGPath.parse("M22.5 2.5 H26.5 L24.5 4.5 Z M24.5 4.5 L26.5 6.5 H22.5 Z"))
            return [ArtShape(path: p, style: .fill, color: hex(0xB7A27A))]
        case .danger(let op):
            var p = Path()
            for r in [CGRect(x: 21.5, y: 1.5, width: 1.5, height: 3.5), CGRect(x: 21.5, y: 6, width: 1.5, height: 1.5),
                      CGRect(x: 25, y: 1.5, width: 1.5, height: 3.5), CGRect(x: 25, y: 6, width: 1.5, height: 1.5)] { p.addRect(r) }
            return [ArtShape(path: p, style: .fill, color: hex(0xFF453A), opacity: op)]
        }
    }

    static func scaled(_ shapes: [ArtShape], _ s: CGFloat, about c: CGPoint) -> [ArtShape] {
        guard s != 1 else { return shapes }
        let m = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: s, y: s).translatedBy(x: -c.x, y: -c.y)
        return shapes.map { var a = $0; a.path = a.path.applying(m); return a }
    }
}

// MARK: - 画一整帧

enum DundunPainter {
    /// 在 GraphicsContext 里画一帧。ctx 的坐标：20pt = 28×28 画布（1 单位 = 1pt），40pt = 80×68pt 画布（viewBox (-4,-6,40,34)，1 单位 = 2pt）。
    /// 想画成别的尺寸，调用方先对 ctx 整体缩放
    static func draw(_ r: DundunRender, scale: DundunScale, in ctx: GraphicsContext) {
        var ctx = ctx
        if scale == .large {
            ctx.scaleBy(x: 2, y: 2)
            ctx.translateBy(x: 4, y: 6)
        }
        let c0 = DundunGeometry.bodyCenter, R = DundunGeometry.bodyRadius
        let c = CGPoint(x: c0.x + r.dx, y: c0.y + r.dy)

        // 身体：正圆不转；渐变 0 = 顶、1 = 底，端点绕圆心转 rotation（§1.1）
        let a = CGFloat(r.rotation * .pi / 180)
        let up = CGPoint(x: R * sin(a), y: -R * cos(a))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)),
                 with: .linearGradient(Gradient(colors: [r.colors.top.color, r.colors.bottom.color]),
                                       startPoint: CGPoint(x: c.x + up.x, y: c.y + up.y),
                                       endPoint: CGPoint(x: c.x - up.x, y: c.y - up.y)))

        // 眼睛：跟身体位移，绕身体中心转
        var eyes = ctx
        eyes.translateBy(x: c.x, y: c.y)
        eyes.rotate(by: .degrees(r.rotation))
        eyes.translateBy(x: -c0.x, y: -c0.y)
        for e in [r.left, r.right].compactMap({ $0 }) {
            var ec = eyes
            ec.translateBy(x: e.offset.x, y: e.offset.y)
            for s in EyeArt.squashed(EyeArt.shapes(e.geom, scale), close: e.close, scale: scale) { s.draw(in: ec) }
        }

        // 装饰：画布坐标，不跟位移和旋转；过渡里的缩放绕装饰自己的中心（3A.2）
        for d in r.decos {
            var shapes = DecoArt.shapes(d.deco, scale)
            guard let first = shapes.first else { continue }
            if d.scale != 1 {
                let box = shapes.dropFirst().reduce(first.path.boundingRect) { $0.union($1.path.boundingRect) }
                shapes = DecoArt.scaled(shapes, CGFloat(d.scale), about: CGPoint(x: box.midX, y: box.midY))
            }
            var dc = ctx
            dc.opacity *= d.opacity
            if shapes.count > 1 && d.opacity < 1 {
                // 多块叠着的装饰整体淡入淡出，先画进一层再整体乘不透明度，重叠处不会更深
                dc.drawLayer { layer in for s in shapes { s.draw(in: layer) } }
            } else {
                for s in shapes { s.draw(in: dc) }
            }
        }
    }
}

// MARK: - 右耳（§2.3）

enum EarPainter {
    /// center = 7pt 圆点的圆心；三颗点右缘比圆点右缘再往里 0.5pt，整组中心在 center.x − 3（见 NotchEars）
    static func draw(_ r: EarRender, dotCenter c: CGPoint, dotsCenter d: CGPoint, in ctx: GraphicsContext) {
        for l in r.layers {
            var lc = ctx
            lc.opacity *= l.opacity
            let color = l.color.color
            switch l.shape {
            case .dots:
                for i in -1...1 { lc.fill(circle(d.x + 5 * CGFloat(i), d.y, 1.5), with: .color(color)) }
            case .dot:
                lc.fill(circle(c.x, c.y, 3.5), with: .color(color))
            }
            if let ring = l.ring {
                var rc = lc
                rc.opacity *= ring.opacity
                rc.stroke(circle(c.x, c.y, ring.radius), with: .color(color), lineWidth: 1)
            }
        }
    }
}
