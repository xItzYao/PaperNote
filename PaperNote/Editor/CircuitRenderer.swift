import UIKit

/// 畫電路圖：元件符號、導線、接點圓點、交叉跨線
enum CircuitRenderer {
    static let hopRadius: CGFloat = 5
    static let dotRadius: CGFloat = 3.5
    /// 橡皮擦擦到、筆尖還沒離開的元件和導線
    static let erasingColor = UIColor(white: 0.55, alpha: 0.45)

    /// 在目前的 UIKit context 中畫；rect 的左上角是電路圖座標原點。
    /// erasing 裡的元件、導線畫成透明灰色，其他的畫成刪掉它們之後的樣子（接點、跨線也一樣）
    static func draw(_ d: CircuitData, in rect: CGRect, erasing: Set<UUID> = []) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        // 符號、線寬、跨線、圓點一起縮放
        ctx.scaleBy(x: d.scale, y: d.scale)
        var kept = d, erased = d
        kept.components.removeAll { erasing.contains($0.id) }
        kept.wires.removeAll { erasing.contains($0.id) }
        erased.components.removeAll { !erasing.contains($0.id) }
        erased.wires.removeAll { !erasing.contains($0.id) }
        drawContent(erased, color: erasingColor)
        drawContent(kept, color: UIColor(hex: d.colorHex))
        ctx.restoreGState()
    }

    private static func drawContent(_ d: CircuitData, color: UIColor) {
        for c in d.components { drawComponent(c, color: color, lineWidth: d.lineWidth) }
        drawWires(d, color: color)
        color.setFill()
        for p in d.junctions() {
            UIBezierPath(ovalIn: CGRect(x: p.x - dotRadius, y: p.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)).fill()
        }
        drawNames(d, color: color)
    }

    static func wireLabelFont(_ size: CGFloat) -> UIFont { .systemFont(ofSize: size, weight: .medium) }

    /// 名稱的字：R_1、x^2 畫成上下標
    static func nameString(_ text: String, size: CGFloat, color: UIColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in CircuitText.runs(text) {
            let small = size * CircuitText.scriptScale
            switch run.script {
            case .normal:
                out.append(NSAttributedString(string: run.text, attributes: [.font: wireLabelFont(size), .foregroundColor: color]))
            case .sub:
                out.append(NSAttributedString(string: run.text, attributes: [.font: wireLabelFont(small), .foregroundColor: color, .baselineOffset: -size * 0.2]))
            case .sup:
                out.append(NSAttributedString(string: run.text, attributes: [.font: wireLabelFont(small), .foregroundColor: color, .baselineOffset: size * 0.35]))
            }
        }
        return out
    }

    /// 導線名稱、元件名稱：字的中心在名稱的位置
    static func drawNames(_ d: CircuitData, color: UIColor) {
        let names = d.wires.map { ($0.label, $0.labelPosition, $0.labelFont) }
            + d.components.map { ($0.name, $0.namePosition, $0.nameFont) }
        for case let (text?, c?, size) in names where !text.isEmpty {
            let str = nameString(text, size: size, color: color)
            let sz = str.size()
            str.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
        }
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

    /// 方塊元件上的一段字（電路圖座標的中心點）；inverted＝反相，字上面畫一條橫線
    struct BlockText {
        var text: String
        var center: CGPoint
        var size: CGFloat
        var bold: Bool
        var inverted: Bool
    }

    /// 方塊元件的文字：標題與每支接腳的名字。位置跟著旋轉、翻轉，但字永遠是正的
    static func blockTexts(_ c: CircuitComponent, _ b: CircuitBlockLayout) -> [BlockText] {
        let t = CircuitGeometry.transform(c)
        let inner = b.halfWidth - 11
        var out: [BlockText] = []
        func text(_ name: String, at p: CGPoint, size: CGFloat, bold: Bool = false) {
            let inverted = name.hasPrefix("~")
            out.append(BlockText(text: inverted ? String(name.dropFirst()) : name, center: p.applying(t), size: size, bold: bold, inverted: inverted))
        }
        for (name, y) in zip(b.left, b.sideOffsets(b.left.count)) where b.clock.map({ b.left[$0] != name }) ?? true {
            text(name, at: CGPoint(x: -inner, y: y), size: 8)
        }
        for (name, y) in zip(b.right, b.sideOffsets(b.right.count)) { text(name, at: CGPoint(x: inner, y: y), size: 8) }
        for (name, x) in zip(b.bottom, CircuitGeometry.spread(b.bottom.count)) { text(name, at: CGPoint(x: x, y: b.bottomEdge(at: x) - 7), size: 8) }
        // ALU 的標題寫在本體裡（缺口右邊）；其他寫在上面
        text(b.title, at: b.notch ? CGPoint(x: 2, y: 0) : CGPoint(x: 0, y: -b.height / 2 - 7), size: 9, bold: true)
        return out
    }

    private static func drawBlockLabels(_ c: CircuitComponent, _ b: CircuitBlockLayout, color: UIColor) {
        for item in blockTexts(c, b) {
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: item.size, weight: item.bold ? .semibold : .regular),
                                                         .foregroundColor: color]
            let str = NSAttributedString(string: item.text, attributes: attrs)
            let sz = str.size()
            let origin = CGPoint(x: item.center.x - sz.width / 2, y: item.center.y - sz.height / 2)
            str.draw(at: origin)
            if item.inverted {
                // 反相：字上面畫一條橫線
                let bar = UIBezierPath()
                bar.move(to: CGPoint(x: origin.x, y: origin.y + 1.5))
                bar.addLine(to: CGPoint(x: origin.x + sz.width, y: origin.y + 1.5))
                bar.lineWidth = 0.8
                color.setStroke()
                bar.stroke()
            }
        }
    }

    static func drawWires(_ d: CircuitData, color: UIColor) {
        let path = wirePath(d)
        path.lineWidth = d.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// 導線：遇到沒有接在一起的交叉點，畫半圓跨過去（水平段往上、垂直段往右）
    static func wirePath(_ d: CircuitData) -> UIBezierPath {
        let crossings = d.crossings()
        let path = UIBezierPath()
        let r = hopRadius
        for (wi, w) in d.wires.enumerated() where w.points.count >= 2 {
            path.move(to: w.points[0])
            for si in 0..<(w.points.count - 1) {
                let a = w.points[si], b = w.points[si + 1]
                let hops = crossings.filter { $0.wire == wi && $0.segment == si }.map(\.at)
                if a.y == b.y, !hops.isEmpty {
                    let right = b.x > a.x
                    for x in hops.sorted(by: right ? (<) : (>)) {
                        path.addLine(to: CGPoint(x: right ? x - r : x + r, y: a.y))
                        // 從左往右：經過上方（clockwise）；從右往左：反方向
                        path.addArc(withCenter: CGPoint(x: x, y: a.y), radius: r,
                                    startAngle: right ? .pi : 0, endAngle: right ? 2 * .pi : .pi, clockwise: right)
                    }
                } else if a.x == b.x, !hops.isEmpty {
                    let down = b.y > a.y
                    for y in hops.sorted(by: down ? (<) : (>)) {
                        path.addLine(to: CGPoint(x: a.x, y: down ? y - r : y + r))
                        // 從上往下：經過右側（clockwise）；從下往上：反方向
                        path.addArc(withCenter: CGPoint(x: a.x, y: y), radius: r,
                                    startAngle: down ? -.pi / 2 : .pi / 2, endAngle: down ? .pi / 2 : -.pi / 2, clockwise: down)
                    }
                }
                path.addLine(to: b)
            }
        }
        return path
    }

    // MARK: - 符號（元件座標：中心為原點、預設朝右）

    private static func line(_ p: UIBezierPath, _ a: CGPoint, _ b: CGPoint) {
        p.move(to: a)
        p.addLine(to: b)
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// 實心箭頭：尖端在 tip，從 from 的方向來
    private static func head(_ f: UIBezierPath, tip: CGPoint, from: CGPoint, size s: CGFloat = 7) {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        let bx = tip.x - ux * s, by = tip.y - uy * s, w = s * 0.6
        f.move(to: tip)
        f.addLine(to: pt(bx - uy * w, by + ux * w))
        f.addLine(to: pt(bx + uy * w, by - ux * w))
        f.close()
    }

    /// 帶箭頭的線（可變元件的斜箭頭、LED 的光）
    private static func arrow(_ s: UIBezierPath, _ f: UIBezierPath, from: CGPoint, to: CGPoint, size: CGFloat = 6) {
        line(s, from, to)
        head(f, tip: to, from: from, size: size)
    }

    private static func zigzag(_ s: UIBezierPath) {
        line(s, pt(-30, 0), pt(-20, 0))
        s.move(to: pt(-20, 0))
        for k in 0..<6 {
            s.addLine(to: pt(-20 + 40 * CGFloat(2 * k + 1) / 12, k % 2 == 0 ? -7 : 7))
        }
        s.addLine(to: pt(20, 0))
        s.addLine(to: pt(30, 0))
    }

    private static func diodeBody(_ s: UIBezierPath) {
        line(s, pt(-30, 0), pt(-8, 0))
        s.move(to: pt(-8, -9)); s.addLine(to: pt(-8, 9)); s.addLine(to: pt(8, 0)); s.close()
        line(s, pt(8, -9), pt(8, 9))
        line(s, pt(8, 0), pt(30, 0))
    }

    /// 圓形本體和左右引腳（電源、儀表、燈泡、混頻器）
    private static func circleBody(_ s: UIBezierPath) {
        s.append(UIBezierPath(ovalIn: CGRect(x: -15, y: -15, width: 30, height: 30)))
        line(s, pt(-30, 0), pt(-15, 0))
        line(s, pt(15, 0), pt(30, 0))
    }

    private static func diamondBody(_ s: UIBezierPath) {
        s.move(to: pt(-16, 0)); s.addLine(to: pt(0, -16)); s.addLine(to: pt(16, 0)); s.addLine(to: pt(0, 16)); s.close()
        line(s, pt(-30, 0), pt(-16, 0))
        line(s, pt(16, 0), pt(30, 0))
    }

    /// 開關的兩個接點
    private static func switchContacts(_ s: UIBezierPath, right: [CGPoint]) {
        line(s, pt(-30, 0), pt(-14, 0))
        s.append(UIBezierPath(ovalIn: CGRect(x: -14, y: -2, width: 4, height: 4)))
        for p in right {
            s.append(UIBezierPath(ovalIn: CGRect(x: p.x, y: p.y - 2, width: 4, height: 4)))
            line(s, pt(p.x + 4, p.y), pt(30, p.y))
        }
    }

    /// 放大器的兩個輸入和正負號（上面是負、下面是正）
    private static func ampInputs(_ s: UIBezierPath) {
        for y in [-20, 20] as [CGFloat] { line(s, pt(-40, y), pt(-24, y)) }
        line(s, pt(-20, -20), pt(-14, -20))
        line(s, pt(-20, 20), pt(-14, 20))
        line(s, pt(-17, 17), pt(-17, 23))
    }

    private static func ampTriangle(_ s: UIBezierPath) {
        s.move(to: pt(-24, -30)); s.addLine(to: pt(-24, 30)); s.addLine(to: pt(26, 0)); s.close()
    }

    /// 雙極性、IGBT 的集極和射極；箭頭在射極那條線上，outward＝朝外
    private static func bipolarLegs(_ s: UIBezierPath, _ f: UIBezierPath, baseX x: CGFloat, outward: Bool) {
        s.move(to: pt(x, -6)); s.addLine(to: pt(10, -20)); s.addLine(to: pt(10, -30))
        s.move(to: pt(x, 6)); s.addLine(to: pt(10, 20)); s.addLine(to: pt(10, 30))
        let a = pt(x, 6), b = pt(10, 20)
        if outward {
            head(f, tip: b, from: a)
        } else {
            head(f, tip: pt(a.x + (b.x - a.x) * 0.3, a.y + (b.y - a.y) * 0.3), from: b)
        }
    }

    /// 儀表的字母（A、V、Ω）用線條畫，匯出 SVG 時和其他符號一樣是路徑
    private static func meterLetter(_ part: CircuitPart, _ s: UIBezierPath) {
        switch part {
        case .ammeter:
            s.move(to: pt(-5, 7)); s.addLine(to: pt(0, -7)); s.addLine(to: pt(5, 7))
            line(s, pt(-3, 2), pt(3, 2))
        case .voltmeter:
            s.move(to: pt(-5, -7)); s.addLine(to: pt(0, 7)); s.addLine(to: pt(5, -7))
        default:
            s.move(to: pt(-7, 7)); s.addLine(to: pt(-3.8, 7)); s.addLine(to: pt(-3.8, 4.26))
            s.addArc(withCenter: pt(0, -1), radius: 6.5, startAngle: 0.7 * .pi, endAngle: 0.3 * .pi, clockwise: true)
            s.addLine(to: pt(3.8, 7)); s.addLine(to: pt(7, 7))
        }
    }

    /// 回傳（要描邊的路徑, 要填滿的路徑）
    static func symbol(_ c: CircuitComponent) -> (UIBezierPath, UIBezierPath) {
        let s = UIBezierPath()
        let f = UIBezierPath()
        switch c.part {
        case .customSymbol:
            for stroke in c.symbol?.strokes ?? [] {
                guard let first = stroke.points.first else { continue }
                s.move(to: first)
                for p in stroke.points.dropFirst() { s.addLine(to: p) }
            }
        case .resistor:
            zigzag(s)
        case .potentiometer:
            zigzag(s)
            arrow(s, f, from: pt(0, -20), to: pt(0, -8))
        case .variableResistor:
            zigzag(s)
            arrow(s, f, from: pt(-16, 15), to: pt(16, -16))
        case .fuse:
            line(s, pt(-30, 0), pt(30, 0))
            s.append(UIBezierPath(rect: CGRect(x: -15, y: -6, width: 30, height: 12)))
        case .polarCapacitor:
            line(s, pt(-30, 0), pt(-4, 0))
            line(s, pt(-4, -12), pt(-4, 12))
            s.move(to: pt(8, -12)); s.addQuadCurve(to: pt(8, 12), controlPoint: pt(0, 0))
            line(s, pt(4, 0), pt(30, 0))
            line(s, pt(-14, -10), pt(-8, -10))
            line(s, pt(-11, -13), pt(-11, -7))
        case .variableCapacitor:
            line(s, pt(-30, 0), pt(-4, 0))
            line(s, pt(4, 0), pt(30, 0))
            line(s, pt(-4, -12), pt(-4, 12))
            line(s, pt(4, -12), pt(4, 12))
            arrow(s, f, from: pt(-16, 15), to: pt(16, -16))
        case .transformer:
            line(s, pt(-30, -20), pt(-10, -20))
            line(s, pt(-30, 20), pt(-10, 20))
            line(s, pt(10, -20), pt(30, -20))
            line(s, pt(10, 20), pt(30, 20))
            s.move(to: pt(-10, -20))
            for cy in [-15, -5, 5, 15] as [CGFloat] {
                s.addArc(withCenter: pt(-10, cy), radius: 5, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
            }
            s.move(to: pt(10, -20))
            for cy in [-15, -5, 5, 15] as [CGFloat] {
                s.addArc(withCenter: pt(10, cy), radius: 5, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
            }
            line(s, pt(-1.5, -22), pt(-1.5, 22))
            line(s, pt(1.5, -22), pt(1.5, 22))
        case .diode:
            diodeBody(s)
        case .schottky:
            diodeBody(s)
            s.move(to: pt(8, -9)); s.addLine(to: pt(12, -9)); s.addLine(to: pt(12, -6))
            s.move(to: pt(8, 9)); s.addLine(to: pt(4, 9)); s.addLine(to: pt(4, 6))
        case .zener:
            diodeBody(s)
            line(s, pt(8, -9), pt(12, -12))
            line(s, pt(8, 9), pt(4, 12))
        case .tunnelDiode:
            diodeBody(s)
            line(s, pt(8, -9), pt(3, -9))
            line(s, pt(8, 9), pt(3, 9))
        case .led:
            diodeBody(s)
            arrow(s, f, from: pt(-3, -11), to: pt(5, -20), size: 5)
            arrow(s, f, from: pt(5, -11), to: pt(13, -20), size: 5)
        case .photodiode:
            diodeBody(s)
            arrow(s, f, from: pt(5, -20), to: pt(-3, -11), size: 5)
            arrow(s, f, from: pt(13, -20), to: pt(5, -11), size: 5)
        case .varicap:
            diodeBody(s)
            line(s, pt(12, -9), pt(12, 9))
        case .battery:
            line(s, pt(-30, 0), pt(-9, 0))
            line(s, pt(-9, -12), pt(-9, 12))
            line(s, pt(-3, -6), pt(-3, 6))
            line(s, pt(3, -12), pt(3, 12))
            line(s, pt(9, -6), pt(9, 6))
            line(s, pt(9, 0), pt(30, 0))
        case .sineSource:
            circleBody(s)
            s.move(to: pt(-9, 0))
            s.addQuadCurve(to: pt(0, 0), controlPoint: pt(-4.5, -12))
            s.addQuadCurve(to: pt(9, 0), controlPoint: pt(4.5, 12))
        case .squareSource:
            circleBody(s)
            s.move(to: pt(-9, 5)); s.addLine(to: pt(-4.5, 5)); s.addLine(to: pt(-4.5, -5)); s.addLine(to: pt(4.5, -5))
            s.addLine(to: pt(4.5, 5)); s.addLine(to: pt(9, 5))
        case .controlledVoltageSource:
            diamondBody(s)
            line(s, pt(-11, 0), pt(-3, 0))
            line(s, pt(-7, -4), pt(-7, 4))
            line(s, pt(3, 0), pt(11, 0))
        case .controlledCurrentSource:
            diamondBody(s)
            arrow(s, f, from: pt(-9, 0), to: pt(10, 0))
        case .ammeter, .voltmeter, .ohmmeter:
            circleBody(s)
            meterLetter(c.part, s)
        case .lamp:
            circleBody(s)
            line(s, pt(-10.6, -10.6), pt(10.6, 10.6))
            line(s, pt(-10.6, 10.6), pt(10.6, -10.6))
        case .mixer:
            circleBody(s)
            line(s, pt(-10.6, -10.6), pt(10.6, 10.6))
            line(s, pt(-10.6, 10.6), pt(10.6, -10.6))
            line(s, pt(0, 15), pt(0, 30))
        case .antenna:
            line(s, pt(0, 20), pt(0, -20))
            s.move(to: pt(-10, -20)); s.addLine(to: pt(10, -20)); s.addLine(to: pt(0, -6)); s.close()
        case .switchOpen:
            switchContacts(s, right: [pt(10, 0)])
            line(s, pt(-12, -1), pt(10, -12))
        case .switchClosed:
            switchContacts(s, right: [pt(10, 0)])
            line(s, pt(-12, -2), pt(12, -2))
        case .pushButton:
            switchContacts(s, right: [pt(10, 0)])
            line(s, pt(-14, -7), pt(14, -7))
            line(s, pt(0, -7), pt(0, -15))
        case .spdt:
            switchContacts(s, right: [pt(10, -20), pt(10, 20)])
            line(s, pt(-12, -1), pt(10, -18))
        case .nmos4, .pmos4:
            line(s, pt(-30, 0), pt(c.part == .pmos4 ? -18 : -12, 0))
            if c.part == .pmos4 { s.append(UIBezierPath(ovalIn: CGRect(x: -18, y: -3, width: 6, height: 6))) }
            line(s, pt(-12, -14), pt(-12, 14))
            line(s, pt(-6, -16), pt(-6, 16))
            s.move(to: pt(-6, -10)); s.addLine(to: pt(10, -10)); s.addLine(to: pt(10, -30))
            s.move(to: pt(-6, 10)); s.addLine(to: pt(10, 10)); s.addLine(to: pt(10, 30))
            line(s, pt(-6, 0), pt(30, 0))
            // 基底的箭頭：N 型指向通道、P 型指向外面
            if c.part == .nmos4 { head(f, tip: pt(-5, 0), from: pt(10, 0)) } else { head(f, tip: pt(6, 0), from: pt(-6, 0)) }
        case .npn, .pnp:
            line(s, pt(-30, 0), pt(-10, 0))
            line(s, pt(-10, -14), pt(-10, 14))
            bipolarLegs(s, f, baseX: -10, outward: c.part == .npn)
        case .njfet, .pjfet:
            line(s, pt(-30, 0), pt(-6, 0))
            line(s, pt(-6, -14), pt(-6, 14))
            s.move(to: pt(-6, -10)); s.addLine(to: pt(10, -10)); s.addLine(to: pt(10, -30))
            s.move(to: pt(-6, 10)); s.addLine(to: pt(10, 10)); s.addLine(to: pt(10, 30))
            if c.part == .njfet { head(f, tip: pt(-7, 0), from: pt(-20, 0)) } else { head(f, tip: pt(-18, 0), from: pt(-6, 0)) }
        case .nigbt, .pigbt:
            line(s, pt(-30, 0), pt(-14, 0))
            line(s, pt(-14, -12), pt(-14, 12))
            line(s, pt(-8, -14), pt(-8, 14))
            bipolarLegs(s, f, baseX: -8, outward: c.part == .nigbt)
        case .opAmp:
            ampInputs(s)
            ampTriangle(s)
            line(s, pt(26, 0), pt(40, 0))
        case .fdOpAmp:
            ampInputs(s)
            ampTriangle(s)
            // 輸出從斜邊拉出來
            line(s, pt(9.33, -10), pt(40, -10))
            line(s, pt(9.33, 10), pt(40, 10))
            line(s, pt(20, -19), pt(26, -19))
            line(s, pt(23, -22), pt(23, -16))
            line(s, pt(20, 19), pt(26, 19))
        case .ota:
            // OTA：切掉尖端的三角形，輸出端多一條線
            ampInputs(s)
            s.move(to: pt(-24, -30)); s.addLine(to: pt(-24, 30)); s.addLine(to: pt(12, 8)); s.addLine(to: pt(12, -8)); s.close()
            line(s, pt(18, -8), pt(18, 8))
            line(s, pt(18, 0), pt(40, 0))
        case .signalGround:
            line(s, pt(0, -20), pt(0, 0))
            s.move(to: pt(-10, 0)); s.addLine(to: pt(10, 0)); s.addLine(to: pt(0, 10)); s.close()
        case .chassisGround:
            line(s, pt(0, -20), pt(0, 0))
            line(s, pt(-12, 0), pt(12, 0))
            line(s, pt(-12, 0), pt(-16, 8))
            line(s, pt(0, 0), pt(-4, 8))
            line(s, pt(12, 0), pt(8, 8))
        case .vss:
            line(s, pt(0, -20), pt(0, 0))
            f.move(to: pt(0, 8)); f.addLine(to: pt(-6, 0)); f.addLine(to: pt(6, 0)); f.close()
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
        case .dFlipFlop, .dLatch, .mux, .decoder, .encoder, .alu, .adc, .dac:
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
            if b.notch {
                // ALU：左邊中間往內凹的 V 形缺口（兩個輸入分在缺口上下）
                s.addLine(to: pt(-w, h / 4))
                s.addLine(to: pt(-w + h / 5, 0))
                s.addLine(to: pt(-w, -h / 4))
            }
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
        var c = CircuitComponent(part: part, position: .zero, inputs: 2)
        c.flipV = part.defaultFlipV
        let b = CircuitGeometry.bounds(c).insetBy(dx: -2, dy: -2)
        let scale = min(size / b.width, size / b.height)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { rc in
            let ctx = rc.cgContext
            ctx.translateBy(x: size / 2, y: size / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -b.midX, y: -b.midY)
            drawComponent(c, color: .label, lineWidth: 1.6 / scale, labels: false)
        }.withRenderingMode(.alwaysTemplate)
    }

    /// 自訂電路的小圖示：整個電路縮小，不畫名稱
    static func icon(_ data: CircuitData, size: CGFloat = 30) -> UIImage {
        var d = data
        for i in d.components.indices { d.components[i].name = nil }
        for i in d.wires.indices { d.wires[i].label = nil }
        let box = d.contentBounds
        let b = box.isNull ? CGRect(x: -10, y: -10, width: 20, height: 20) : box.insetBy(dx: -2, dy: -2)
        let scale = min(size / max(b.width, 1), size / max(b.height, 1))
        d.lineWidth = 1.2 / scale
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { rc in
            let ctx = rc.cgContext
            ctx.translateBy(x: size / 2, y: size / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -b.midX, y: -b.midY)
            for c in d.components { drawComponent(c, color: .label, lineWidth: d.lineWidth, labels: false) }
            drawWires(d, color: .label)
        }.withRenderingMode(.alwaysTemplate)
    }
}

// MARK: - 匯出 SVG（向量圖：可以放進簡報、文件，或用 Inkscape、Illustrator 再編輯）

extension CircuitRenderer {
    /// 整個電路圖存成 SVG：元件、導線、接點、跨線、文字都和畫面上一樣。用電路圖原本的座標（不乘縮放）
    static func svg(_ d: CircuitData) -> String {
        var box = d.contentBounds
        if box.isNull { box = .zero }
        box = box.insetBy(dx: -12, dy: -12)
        let color = String(d.colorHex.prefix(7))
        let font = "Helvetica, Arial, sans-serif"
        var out = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(num(box.width))" height="\#(num(box.height))" viewBox="\#(num(box.minX)) \#(num(box.minY)) \#(num(box.width)) \#(num(box.height))">"#,
        ]
        func stroke(_ p: UIBezierPath) {
            guard !p.isEmpty else { return }
            out.append(#"<path d="\#(pathData(p.cgPath))" fill="none" stroke="\#(color)" stroke-width="\#(num(d.lineWidth))" stroke-linecap="round" stroke-linejoin="round"/>"#)
        }
        func text(_ s: String, at c: CGPoint, size: CGFloat, weight: String, overline: Bool = false) {
            let deco = overline ? #" text-decoration="overline""# : ""
            out.append(#"<text x="\#(num(c.x))" y="\#(num(c.y))" font-family="\#(font)" font-size="\#(num(size))" font-weight="\#(weight)" text-anchor="middle" dominant-baseline="central" fill="\#(color)"\#(deco)>\#(s)</text>"#)
        }
        /// 名稱的字：上下標用 tspan 上下移。dy 是相對上一段的位移
        func nameMarkup(_ s: String, size: CGFloat) -> String {
            let runs = CircuitText.runs(s)
            guard runs.contains(where: { $0.script != .normal }) else { return xmlEscaped(s) }
            var shift: CGFloat = 0
            return runs.map { run in
                let target: CGFloat = run.script == .sub ? size * 0.2 : (run.script == .sup ? -size * 0.35 : 0)
                let dy = target - shift
                shift = target
                let small = run.script == .normal ? "" : #" font-size="\#(num(size * CircuitText.scriptScale))""#
                return #"<tspan dy="\#(num(dy))"\#(small)>\#(xmlEscaped(run.text))</tspan>"#
            }.joined()
        }
        for c in d.components {
            let t = CircuitGeometry.transform(c)
            let (s, f) = symbol(c)
            s.apply(t)
            f.apply(t)
            stroke(s)
            if !f.isEmpty { out.append(#"<path d="\#(pathData(f.cgPath))" fill="\#(color)"/>"#) }
            if let b = CircuitGeometry.blockLayout(c) {
                for item in blockTexts(c, b) { text(xmlEscaped(item.text), at: item.center, size: item.size, weight: item.bold ? "600" : "400", overline: item.inverted) }
            }
        }
        stroke(wirePath(d))
        for p in d.junctions() {
            out.append(#"<circle cx="\#(num(p.x))" cy="\#(num(p.y))" r="\#(num(dotRadius))" fill="\#(color)"/>"#)
        }
        for w in d.wires {
            guard let s = w.label, !s.isEmpty, let c = w.labelPosition else { continue }
            text(nameMarkup(s, size: w.labelFont), at: c, size: w.labelFont, weight: "500")
        }
        for comp in d.components {
            guard let s = comp.name, !s.isEmpty, let c = comp.namePosition else { continue }
            text(nameMarkup(s, size: comp.nameFont), at: c, size: comp.nameFont, weight: "500")
        }
        out.append("</svg>")
        return out.joined(separator: "\n") + "\n"
    }

    /// CGPath → SVG 的 d（圓弧在 CGPath 裡已經是貝茲曲線）
    static func pathData(_ p: CGPath) -> String {
        var parts: [String] = []
        p.applyWithBlock { e in
            let q = e.pointee.points
            func pt(_ i: Int) -> String { "\(CircuitRenderer.num(q[i].x)) \(CircuitRenderer.num(q[i].y))" }
            switch e.pointee.type {
            case .moveToPoint: parts.append("M" + pt(0))
            case .addLineToPoint: parts.append("L" + pt(0))
            case .addQuadCurveToPoint: parts.append("Q" + pt(0) + " " + pt(1))
            case .addCurveToPoint: parts.append("C" + pt(0) + " " + pt(1) + " " + pt(2))
            case .closeSubpath: parts.append("Z")
            @unknown default: break
            }
        }
        return parts.joined(separator: " ")
    }

    /// 小數最多兩位，去掉多餘的 0
    static func num(_ v: CGFloat) -> String {
        var s = String(format: "%.2f", Double(v))
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
