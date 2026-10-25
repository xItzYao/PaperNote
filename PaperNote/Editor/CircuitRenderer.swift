import UIKit

/// 畫電路圖：元件符號、導線、接點圓點、交叉跨線
enum CircuitRenderer {
    static let hopRadius: CGFloat = 5
    static let dotRadius: CGFloat = 3.5

    /// 在目前的 UIKit context 中畫；rect 的左上角是電路圖座標原點
    static func draw(_ d: CircuitData, in rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        let color = UIColor(hex: d.colorHex)
        for c in d.components { drawComponent(c, color: color, lineWidth: d.lineWidth) }
        drawWires(d, color: color)
        color.setFill()
        for p in d.junctions() {
            UIBezierPath(ovalIn: CGRect(x: p.x - dotRadius, y: p.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)).fill()
        }
        ctx.restoreGState()
    }

    static func drawComponent(_ c: CircuitComponent, color: UIColor, lineWidth: CGFloat, labels: Bool = true) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.concatenate(CircuitGeometry.transform(c))
        color.setStroke()
        color.setFill()
        let (stroke, fill) = symbol(c)
        stroke.lineWidth = lineWidth
        stroke.lineCapStyle = .round
        stroke.lineJoinStyle = .round
        stroke.stroke()
        fill.fill()
        ctx.restoreGState()
        if labels, let b = CircuitGeometry.blockLayout(c) { drawBlockLabels(c, b, color: color) }
    }

    /// 方塊元件的文字：標題與每支接腳的名字。位置跟著旋轉、翻轉，但字永遠是正的
    private static func drawBlockLabels(_ c: CircuitComponent, _ b: CircuitBlockLayout, color: UIColor) {
        let t = CircuitGeometry.transform(c)
        let inner = b.halfWidth - 11
        func text(_ name: String, at p: CGPoint, size: CGFloat, bold: Bool = false) {
            let inverted = name.hasPrefix("~")
            let label = inverted ? String(name.dropFirst()) : name
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                                                         .foregroundColor: color]
            let str = NSAttributedString(string: label, attributes: attrs)
            let sz = str.size()
            let q = p.applying(t)
            let origin = CGPoint(x: q.x - sz.width / 2, y: q.y - sz.height / 2)
            str.draw(at: origin)
            if inverted {
                // 反相：字上面畫一條橫線
                let bar = UIBezierPath()
                bar.move(to: CGPoint(x: origin.x, y: origin.y + 1.5))
                bar.addLine(to: CGPoint(x: origin.x + sz.width, y: origin.y + 1.5))
                bar.lineWidth = 0.8
                color.setStroke()
                bar.stroke()
            }
        }
        for (name, y) in zip(b.left, b.sideOffsets(b.left.count)) where b.clock.map({ b.left[$0] != name }) ?? true {
            text(name, at: CGPoint(x: -inner, y: y), size: 8)
        }
        for (name, y) in zip(b.right, b.sideOffsets(b.right.count)) { text(name, at: CGPoint(x: inner, y: y), size: 8) }
        for (name, x) in zip(b.bottom, CircuitGeometry.spread(b.bottom.count)) { text(name, at: CGPoint(x: x, y: b.bottomEdge(at: x) - 7), size: 8) }
        text(b.title, at: CGPoint(x: 0, y: -b.height / 2 - 7), size: 9, bold: true)
    }

    /// 導線：水平段遇到沒有接在一起的交叉點，畫半圓跨過去
    static func drawWires(_ d: CircuitData, color: UIColor) {
        let crossings = d.crossings()
        let path = UIBezierPath()
        for (wi, w) in d.wires.enumerated() where w.points.count >= 2 {
            path.move(to: w.points[0])
            for si in 0..<(w.points.count - 1) {
                let a = w.points[si], b = w.points[si + 1]
                let xs = crossings.filter { $0.wire == wi && $0.segment == si }.map(\.x)
                if a.y == b.y, !xs.isEmpty {
                    let right = b.x > a.x
                    for x in xs.sorted(by: right ? (<) : (>)) {
                        let r = hopRadius
                        path.addLine(to: CGPoint(x: right ? x - r : x + r, y: a.y))
                        // 從左往右：經過上方（clockwise）；從右往左：反方向
                        path.addArc(withCenter: CGPoint(x: x, y: a.y), radius: r,
                                    startAngle: right ? .pi : 0, endAngle: right ? 2 * .pi : .pi, clockwise: right)
                    }
                }
                path.addLine(to: b)
            }
        }
        path.lineWidth = d.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    // MARK: - 符號（元件座標：中心為原點、預設朝右）

    private static func line(_ p: UIBezierPath, _ a: CGPoint, _ b: CGPoint) {
        p.move(to: a)
        p.addLine(to: b)
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// 回傳（要描邊的路徑, 要填滿的路徑）
    static func symbol(_ c: CircuitComponent) -> (UIBezierPath, UIBezierPath) {
        let s = UIBezierPath()
        let f = UIBezierPath()
        switch c.part {
        case .resistor:
            line(s, pt(-30, 0), pt(-20, 0))
            s.move(to: pt(-20, 0))
            for k in 0..<6 {
                s.addLine(to: pt(-20 + 40 * CGFloat(2 * k + 1) / 12, k % 2 == 0 ? -7 : 7))
            }
            s.addLine(to: pt(20, 0))
            s.addLine(to: pt(30, 0))
        case .capacitor:
            line(s, pt(-30, 0), pt(-4, 0))
            line(s, pt(4, 0), pt(30, 0))
            line(s, pt(-4, -12), pt(-4, 12))
            line(s, pt(4, -12), pt(4, 12))
        case .inductor:
            line(s, pt(-30, 0), pt(-20, 0))
            s.move(to: pt(-20, 0))
            for cx in [-15, -5, 5, 15] as [CGFloat] {
                s.addArc(withCenter: pt(cx, 0), radius: 5, startAngle: .pi, endAngle: 2 * .pi, clockwise: true)
            }
            s.addLine(to: pt(30, 0))
        case .voltageSource:
            s.append(UIBezierPath(ovalIn: CGRect(x: -15, y: -15, width: 30, height: 30)))
            line(s, pt(-30, 0), pt(-15, 0))
            line(s, pt(15, 0), pt(30, 0))
            line(s, pt(-11, 0), pt(-3, 0))
            line(s, pt(-7, -4), pt(-7, 4))
            line(s, pt(3, 0), pt(11, 0))
        case .currentSource:
            s.append(UIBezierPath(ovalIn: CGRect(x: -15, y: -15, width: 30, height: 30)))
            line(s, pt(-30, 0), pt(-15, 0))
            line(s, pt(15, 0), pt(30, 0))
            line(s, pt(-9, 0), pt(5, 0))
            f.move(to: pt(10, 0))
            f.addLine(to: pt(3, -5))
            f.addLine(to: pt(3, 5))
            f.close()
        case .ground:
            line(s, pt(0, -20), pt(0, 0))
            line(s, pt(-12, 0), pt(12, 0))
            line(s, pt(-8, 5), pt(8, 5))
            line(s, pt(-4, 10), pt(4, 10))
        case .vdd:
            line(s, pt(0, 20), pt(0, 0))
            line(s, pt(-12, 0), pt(12, 0))
            line(s, pt(0, 0), pt(0, -8))
            f.move(to: pt(0, -14))
            f.addLine(to: pt(-5, -6))
            f.addLine(to: pt(5, -6))
            f.close()
        case .nmos, .pmos:
            let isP = c.part == .pmos
            line(s, pt(-30, 0), pt(isP ? -18 : -12, 0))
            if isP { s.append(UIBezierPath(ovalIn: CGRect(x: -18, y: -3, width: 6, height: 6))) }
            line(s, pt(-12, -14), pt(-12, 14))
            line(s, pt(-6, -16), pt(-6, 16))
            s.move(to: pt(-6, -10)); s.addLine(to: pt(10, -10)); s.addLine(to: pt(10, -30))
            s.move(to: pt(-6, 10)); s.addLine(to: pt(10, 10)); s.addLine(to: pt(10, 30))
            if isP {
                // 箭頭朝內（指向通道）
                f.move(to: pt(-2, 10)); f.addLine(to: pt(5, 6)); f.addLine(to: pt(5, 14)); f.close()
            } else {
                // 箭頭朝外（指向源極）
                f.move(to: pt(6, 10)); f.addLine(to: pt(-1, 6)); f.addLine(to: pt(-1, 14)); f.close()
            }
        case .notGate, .bufferGate:
            s.move(to: pt(-15, -15)); s.addLine(to: pt(-15, 15)); s.addLine(to: pt(15, 0)); s.close()
            line(s, pt(-30, 0), pt(-15, 0))
            if c.part == .notGate {
                s.append(UIBezierPath(ovalIn: CGRect(x: 15, y: -4, width: 8, height: 8)))
                line(s, pt(23, 0), pt(30, 0))
            } else {
                line(s, pt(15, 0), pt(30, 0))
            }
        case .dFlipFlop, .dLatch, .mux, .decoder, .encoder:
            if let b = CircuitGeometry.blockLayout(c) { blockSymbol(b, s) }
        default:
            gateSymbol(c, s)
        }
        return (s, f)
    }

    /// 方塊元件：長方形本體、每支接腳的引線；時脈腳畫三角形
    private static func blockSymbol(_ b: CircuitBlockLayout, _ s: UIBezierPath) {
        let w = b.halfWidth, h = b.height / 2, x = b.pinX
        if b.trapezoid {
            // 多工器：左邊寬、右邊窄的梯形
            let k = b.trapezoidInset
            s.move(to: pt(-w, -h))
            s.addLine(to: pt(w, -h + k))
            s.addLine(to: pt(w, h - k))
            s.addLine(to: pt(-w, h))
            s.close()
        } else {
            s.append(UIBezierPath(rect: CGRect(x: -w, y: -h, width: w * 2, height: h * 2)))
        }
        for y in b.sideOffsets(b.left.count) { line(s, pt(-x, y), pt(-w, y)) }
        for y in b.sideOffsets(b.right.count) { line(s, pt(w, y), pt(x, y)) }
        for px in CircuitGeometry.spread(b.bottom.count) { line(s, pt(px, b.bottomEdge(at: px)), pt(px, h + 20)) }
        if let k = b.clock {
            let y = b.sideOffsets(b.left.count)[k]
            s.move(to: pt(-w, y - 6))
            s.addLine(to: pt(-w + 9, y))
            s.addLine(to: pt(-w, y + 6))
        }
    }

    /// 多輸入邏輯閘
    private static func gateSymbol(_ c: CircuitComponent, _ s: UIBezierPath) {
        let h = CircuitGeometry.gateHeight(c)
        let half = h / 2
        let isOrFamily = c.part == .orGate || c.part == .norGate || c.part == .xorGate || c.part == .xnorGate
        let isXor = c.part == .xorGate || c.part == .xnorGate
        if isOrFamily {
            s.move(to: pt(-20, -half))
            s.addQuadCurve(to: pt(half, 0), controlPoint: pt(half / 2, -half))
            s.addQuadCurve(to: pt(-20, half), controlPoint: pt(half / 2, half))
            s.addQuadCurve(to: pt(-20, -half), controlPoint: pt(-10, 0))
            if isXor {
                s.move(to: pt(-26, half))
                s.addQuadCurve(to: pt(-26, -half), controlPoint: pt(-16, 0))
            }
        } else {
            s.move(to: pt(-20, -half))
            s.addLine(to: pt(0, -half))
            s.addArc(withCenter: .zero, radius: half, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
            s.addLine(to: pt(-20, half))
            s.close()
        }
        // 輸入引腳：接到本體左緣（OR 類接到內凹的弧線）
        for p in CircuitGeometry.localPins(c).dropLast() {
            var endX: CGFloat = -20
            if isOrFamily {
                let t = (1 - 2 * p.y / h) / 2
                endX = (isXor ? -26 : -20) + 20 * t * (1 - t)
            }
            line(s, p, pt(endX, p.y))
        }
        // 輸出
        let outX = CircuitGeometry.gateOutputX(c)
        if c.part.hasOutputBubble {
            s.append(UIBezierPath(ovalIn: CGRect(x: half, y: -4, width: 8, height: 8)))
            line(s, pt(half + 8, 0), pt(outX, 0))
        } else {
            line(s, pt(half, 0), pt(outX, 0))
        }
    }

    /// 工具列用的元件小圖示
    static func icon(_ part: CircuitPart, size: CGFloat = 30) -> UIImage {
        let c = CircuitComponent(part: part, position: .zero, inputs: 2)
        let b = CircuitGeometry.localBounds(c).insetBy(dx: -2, dy: -2)
        let scale = min(size / b.width, size / b.height)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { rc in
            let ctx = rc.cgContext
            ctx.translateBy(x: size / 2, y: size / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -b.midX, y: -b.midY)
            drawComponent(c, color: .label, lineWidth: 1.6 / scale, labels: false)
        }.withRenderingMode(.alwaysTemplate)
    }
}
