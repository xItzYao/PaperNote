import Foundation
import CoreGraphics

/// 電路元件種類
enum CircuitPart: String, Codable, CaseIterable, Identifiable {
    case resistor, capacitor, inductor, voltageSource, currentSource, ground, vdd
    case nmos, pmos
    case andGate, orGate, nandGate, norGate, xorGate, xnorGate, notGate, bufferGate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resistor: return "電阻"
        case .capacitor: return "電容"
        case .inductor: return "電感"
        case .voltageSource: return "電壓源"
        case .currentSource: return "電流源"
        case .ground: return "接地"
        case .vdd: return "VDD"
        case .nmos: return "NMOS"
        case .pmos: return "PMOS"
        case .andGate: return "AND"
        case .orGate: return "OR"
        case .nandGate: return "NAND"
        case .norGate: return "NOR"
        case .xorGate: return "XOR"
        case .xnorGate: return "XNOR"
        case .notGate: return "NOT"
        case .bufferGate: return "Buffer"
        }
    }

    var isGate: Bool {
        switch self {
        case .andGate, .orGate, .nandGate, .norGate, .xorGate, .xnorGate, .notGate, .bufferGate: return true
        default: return false
        }
    }

    /// 可以調整輸入數量的邏輯閘
    var hasVariableInputs: Bool { isGate && self != .notGate && self != .bufferGate }

    /// 輸出端有反相圓圈
    var hasOutputBubble: Bool { self == .nandGate || self == .norGate || self == .xnorGate || self == .notGate }
}

struct CircuitComponent: Codable, Equatable, Identifiable {
    var id = UUID()
    var part: CircuitPart
    /// 中心點（電路圖內的座標，對齊格點）
    var position: CGPoint
    /// 0、90、180、270
    var rotation: Int = 0
    var flipH = false
    var flipV = false
    /// 邏輯閘輸入數量
    var inputs = 2
}

struct CircuitWire: Codable, Equatable, Identifiable {
    var id = UUID()
    /// 折線，每一段都是水平或垂直
    var points: [CGPoint]
}

/// 電路圖：放在頁面上的一個物件，內容座標以物件左上角為原點
struct CircuitData: Codable, Equatable {
    var components: [CircuitComponent] = []
    var wires: [CircuitWire] = []
    var colorHex: String = "#1A1A1AFF"
    var lineWidth: CGFloat = 2

    static let grid: CGFloat = 10
    static let margin: CGFloat = 24

    static func snap(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x / grid).rounded() * grid, y: (p.y / grid).rounded() * grid)
    }
}

// MARK: - 元件幾何（元件自己的座標系：中心為原點、預設朝右）

enum CircuitGeometry {
    /// 邏輯閘本體高度
    static func gateHeight(_ c: CircuitComponent) -> CGFloat {
        let n = c.part.hasVariableInputs ? max(2, c.inputs) : 1
        return max(40, CGFloat(n) * 20)
    }

    /// 邏輯閘輸出接腳的 x
    static func gateOutputX(_ c: CircuitComponent) -> CGFloat {
        if c.part == .notGate || c.part == .bufferGate { return 30 }
        let h = gateHeight(c)
        let tip = h / 2 + (c.part.hasOutputBubble ? 8 : 0)
        return max(30, (ceil((tip + 10) / CircuitData.grid)) * CircuitData.grid)
    }

    /// 接腳位置（元件座標）
    static func localPins(_ c: CircuitComponent) -> [CGPoint] {
        switch c.part {
        case .resistor, .capacitor, .inductor, .voltageSource, .currentSource:
            return [CGPoint(x: -30, y: 0), CGPoint(x: 30, y: 0)]
        case .ground:
            return [CGPoint(x: 0, y: -20)]
        case .vdd:
            return [CGPoint(x: 0, y: 20)]
        case .nmos, .pmos:
            return [CGPoint(x: -30, y: 0), CGPoint(x: 10, y: -30), CGPoint(x: 10, y: 30)]
        case .notGate, .bufferGate:
            return [CGPoint(x: -30, y: 0), CGPoint(x: 30, y: 0)]
        default:
            let n = max(2, c.inputs)
            var pins = (0..<n).map { i in CGPoint(x: -30, y: (CGFloat(i) - CGFloat(n - 1) / 2) * 20) }
            pins.append(CGPoint(x: gateOutputX(c), y: 0))
            return pins
        }
    }

    /// 元件本體的外框（元件座標，含引腳）
    static func localBounds(_ c: CircuitComponent) -> CGRect {
        switch c.part {
        case .resistor, .capacitor, .inductor: return CGRect(x: -30, y: -14, width: 60, height: 28)
        case .voltageSource, .currentSource: return CGRect(x: -30, y: -18, width: 60, height: 36)
        case .ground: return CGRect(x: -14, y: -20, width: 28, height: 34)
        case .vdd: return CGRect(x: -14, y: -14, width: 28, height: 34)
        case .nmos, .pmos: return CGRect(x: -30, y: -30, width: 44, height: 60)
        case .notGate, .bufferGate: return CGRect(x: -30, y: -18, width: 60, height: 36)
        default:
            let h = gateHeight(c)
            return CGRect(x: -30, y: -h / 2 - 2, width: 30 + gateOutputX(c), height: h + 4)
        }
    }

    /// 元件座標 → 電路圖座標（先翻轉、再旋轉、最後平移）
    static func transform(_ c: CircuitComponent) -> CGAffineTransform {
        var t = CGAffineTransform(translationX: c.position.x, y: c.position.y)
        t = t.rotated(by: CGFloat(c.rotation) * .pi / 180)
        t = t.scaledBy(x: c.flipH ? -1 : 1, y: c.flipV ? -1 : 1)
        return t
    }

    static func pins(_ c: CircuitComponent) -> [CGPoint] {
        let t = transform(c)
        // 旋轉後四捨五入，避免浮點誤差讓接點對不上
        return localPins(c).map { p in
            let q = p.applying(t)
            return CGPoint(x: q.x.rounded(), y: q.y.rounded())
        }
    }

    static func bounds(_ c: CircuitComponent) -> CGRect {
        localBounds(c).applying(transform(c))
    }
}

// MARK: - 電路圖運算

extension CircuitData {
    var contentBounds: CGRect {
        var r = CGRect.null
        for c in components { r = r.union(CircuitGeometry.bounds(c)) }
        for w in wires { for p in w.points { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) } }
        return r
    }

    /// 所有平移
    mutating func offset(by d: CGPoint) {
        for i in components.indices {
            components[i].position.x += d.x
            components[i].position.y += d.y
        }
        for i in wires.indices {
            wires[i].points = wires[i].points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        }
    }

    /// 元件與導線全部吸到最近的格點（接腳距離元件中心都是格點的倍數，接線不會斷開）
    mutating func snapToGrid() {
        for i in components.indices { components[i].position = Self.snap(components[i].position) }
        for i in wires.indices { wires[i].points = Self.orthogonalize(wires[i].points.map(Self.snap)) }
        wires.removeAll { $0.points.count < 2 }
    }

    /// 每一段都改成水平或垂直（必要時插入轉角），並移除重複點
    static func orthogonalize(_ pts: [CGPoint]) -> [CGPoint] {
        guard var prev = pts.first else { return [] }
        var out = [prev]
        for p in pts.dropFirst() {
            if p.x != prev.x && p.y != prev.y {
                out.append(CGPoint(x: p.x, y: prev.y))
            }
            if p != out.last! { out.append(p) }
            prev = p
        }
        // 去掉同一直線上的中間點
        var simplified: [CGPoint] = []
        for p in out {
            if simplified.count >= 2 {
                let a = simplified[simplified.count - 2], b = simplified[simplified.count - 1]
                if (a.x == b.x && b.x == p.x) || (a.y == b.y && b.y == p.y) { simplified.removeLast() }
            }
            simplified.append(p)
        }
        return simplified
    }

    /// 元件移動／旋轉後，接在舊接腳上的導線端點跟著移到新接腳
    mutating func reattach(from oldPins: [CGPoint], to newPins: [CGPoint]) {
        guard oldPins.count == newPins.count else { return }
        for i in wires.indices {
            var pts = wires[i].points
            guard pts.count >= 2 else { continue }
            if let k = oldPins.firstIndex(of: pts[0]) { pts[0] = newPins[k]; pts = Self.reroute(pts, movedFirst: true) }
            if let k = oldPins.firstIndex(of: pts[pts.count - 1]) { pts[pts.count - 1] = newPins[k]; pts = Self.reroute(pts, movedFirst: false) }
            wires[i].points = Self.orthogonalize(pts)
        }
        wires.removeAll { $0.points.count < 2 }
    }

    /// 端點移動後，讓相鄰的轉角跟著移，盡量保持原本的走線
    private static func reroute(_ pts: [CGPoint], movedFirst: Bool) -> [CGPoint] {
        var p = movedFirst ? pts : pts.reversed()
        if p.count >= 3 {
            // 下一段是水平 → 第一段必須是垂直：轉角的 x 跟著端點；反之調整 y
            if p[1].y == p[2].y { p[1].x = p[0].x } else { p[1].y = p[0].y }
        }
        return movedFirst ? p : p.reversed()
    }

    /// 所有接腳位置
    var allPins: [CGPoint] { components.flatMap { CircuitGeometry.pins($0) } }

    /// 需要畫實心圓點的接點：同一點有 3 個以上的連接（導線端點、接腳、或端點落在另一條線中間）
    func junctions() -> [CGPoint] {
        var endpoints: [PointKey: Int] = [:]
        for w in wires {
            guard let a = w.points.first, let b = w.points.last else { continue }
            endpoints[PointKey(a), default: 0] += 1
            endpoints[PointKey(b), default: 0] += 1
        }
        let pins = allPins
        var result: [CGPoint] = []
        for (key, n) in endpoints {
            let p = key.point
            var count = n + pins.filter { $0 == p }.count
            // 端點落在別條線的中間（T 字接點）
            for w in wires where w.points.count >= 2 {
                for i in 0..<(w.points.count - 1) {
                    let a = w.points[i], b = w.points[i + 1]
                    if p != a && p != b && Self.segment(a, b, contains: p) { count += 2 }
                }
                // 折線中間的轉角
                if w.points.count > 2, w.points.dropFirst().dropLast().contains(p) { count += 2 }
            }
            if count >= 3 { result.append(p) }
        }
        return result
    }

    static func segment(_ a: CGPoint, _ b: CGPoint, contains p: CGPoint) -> Bool {
        if a.x == b.x && p.x == a.x { return p.y > min(a.y, b.y) && p.y < max(a.y, b.y) }
        if a.y == b.y && p.y == a.y { return p.x > min(a.x, b.x) && p.x < max(a.x, b.x) }
        return false
    }

    /// 沒有接在一起的交叉點（水平段在這裡畫跨線半圓）。回傳 (水平導線編號, 段編號, 交叉 x)
    func crossings() -> [(wire: Int, segment: Int, x: CGFloat)] {
        let jset = Set(junctions().map(PointKey.init))
        var out: [(wire: Int, segment: Int, x: CGFloat)] = []
        for (wi, w) in wires.enumerated() where w.points.count >= 2 {
            for si in 0..<(w.points.count - 1) {
                let a = w.points[si], b = w.points[si + 1]
                guard a.y == b.y, a.x != b.x else { continue }
                for (vj, v) in wires.enumerated() where vj != wi && v.points.count >= 2 {
                    for sj in 0..<(v.points.count - 1) {
                        let c = v.points[sj], d = v.points[sj + 1]
                        guard c.x == d.x, c.y != d.y else { continue }
                        let x = c.x, y = a.y
                        let p = CGPoint(x: x, y: y)
                        // 兩條線的內部互相穿過，且不是接點
                        if x > min(a.x, b.x) && x < max(a.x, b.x) && y > min(c.y, d.y) && y < max(c.y, d.y) && !jset.contains(PointKey(p)) {
                            out.append((wi, si, x))
                        }
                    }
                }
            }
        }
        return out
    }

    /// 點 p 附近的接腳（吸附用）
    func nearestPin(to p: CGPoint, within r: CGFloat) -> CGPoint? {
        var best: CGPoint?
        var bestD = r
        for q in allPins {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d <= bestD { bestD = d; best = q }
        }
        return best
    }

    /// 吸附順序：接腳 → 導線的端點／轉角 → 導線中間（T 字接點） → 格點
    func snapTarget(for p: CGPoint, within r: CGFloat) -> CGPoint {
        if let pin = nearestPin(to: p, within: r) { return pin }
        var best: CGPoint?
        var bestD = r
        for w in wires {
            for q in w.points {
                let d = hypot(q.x - p.x, q.y - p.y)
                if d <= bestD { bestD = d; best = q }
            }
        }
        if let best { return best }
        // 投影到最近的一段線上，沿線方向對齊格點
        bestD = r
        for w in wires where w.points.count >= 2 {
            for i in 0..<(w.points.count - 1) {
                let a = w.points[i], b = w.points[i + 1]
                var q: CGPoint
                if a.y == b.y {
                    q = CGPoint(x: min(max(Self.snap(p).x, min(a.x, b.x)), max(a.x, b.x)), y: a.y)
                } else if a.x == b.x {
                    q = CGPoint(x: a.x, y: min(max(Self.snap(p).y, min(a.y, b.y)), max(a.y, b.y)))
                } else {
                    continue
                }
                let d = hypot(q.x - p.x, q.y - p.y)
                if d <= bestD { bestD = d; best = q }
            }
        }
        return best ?? Self.snap(p)
    }

    // MARK: 依筆跡走線

    /// Douglas–Peucker 化簡筆跡
    static func simplify(_ pts: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard pts.count > 2, let a = pts.first, let b = pts.last else { return pts }
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        var maxD: CGFloat = -1
        var idx = 0
        for i in 1..<(pts.count - 1) {
            let p = pts[i]
            let d = len < 0.001 ? hypot(p.x - a.x, p.y - a.y) : abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
            if d > maxD { maxD = d; idx = i }
        }
        if maxD <= tolerance { return [a, b] }
        let left = simplify(Array(pts[...idx]), tolerance: tolerance)
        let right = simplify(Array(pts[idx...]), tolerance: tolerance)
        return left.dropLast() + right
    }

    /// 依手寫筆跡排出直角導線：筆跡拆成水平／垂直的幾段，轉角對齊格點，頭尾分別接到 s 和 e
    static func penRoute(_ ink: [CGPoint], from s: CGPoint, to e: CGPoint,
                         tolerance: CGFloat = 6, minRun: CGFloat = 15) -> [CGPoint] {
        if s == e { return [s] }
        let simple = simplify(ink, tolerance: tolerance)
        // 每一段依主要方向分類，相鄰同方向的合併
        var runs: [(horizontal: Bool, end: CGPoint, length: CGFloat)] = []
        for i in 0..<max(0, simple.count - 1) {
            let a = simple[i], b = simple[i + 1]
            let h = abs(b.x - a.x) >= abs(b.y - a.y)
            let len = h ? abs(b.x - a.x) : abs(b.y - a.y)
            if let last = runs.last, last.horizontal == h {
                runs[runs.count - 1].end = b
                runs[runs.count - 1].length += len
            } else {
                runs.append((h, b, len))
            }
        }
        // 太短的段是手抖：由最短的開始去掉，兩旁同方向的段接起來
        while runs.count > 1, let k = runs.indices.min(by: { runs[$0].length < runs[$1].length }), runs[k].length < minRun {
            let removed = runs.remove(at: k)
            if k > 0 && k < runs.count && runs[k - 1].horizontal == runs[k].horizontal {
                runs[k - 1].end = runs[k].end
                runs[k - 1].length += runs[k].length
                runs.remove(at: k)
            } else if k == runs.count && k > 0 {
                runs[k - 1].end = removed.end
            }
        }
        if runs.isEmpty {
            let h = abs(e.x - s.x) >= abs(e.y - s.y)
            return orthogonalize([s, h ? CGPoint(x: e.x, y: s.y) : CGPoint(x: s.x, y: e.y), e])
        }
        // 每段結束的位置對齊格點；最後兩段改由終點決定，才能剛好接到 e
        var pts = [s]
        var cur = s
        for (k, r) in runs.enumerated() {
            let target = k >= runs.count - 2 ? e : snap(r.end)
            if r.horizontal { cur.x = target.x } else { cur.y = target.y }
            pts.append(cur)
        }
        if cur != e { pts.append(e) }
        return orthogonalize(pts)
    }

    // MARK: 編輯導線

    /// 第 i 段沿垂直方向平移 d；頭尾段會補一小段，讓端點留在原地。回傳新點列與該段的新編號
    private static func shiftSegment(_ pts: [CGPoint], index i: Int, by d: CGFloat) -> (points: [CGPoint], index: Int) {
        guard i >= 0, i + 1 < pts.count, d != 0 else { return (pts, i) }
        var p = pts
        var s = i
        let horizontal = p[s].y == p[s + 1].y
        if s == 0 { p.insert(p[0], at: 0); s += 1 }
        if s + 1 == p.count - 1 { p.append(p[p.count - 1]) }
        if horizontal {
            p[s].y += d; p[s + 1].y += d
        } else {
            p[s].x += d; p[s + 1].x += d
        }
        return (p, s)
    }

    /// 拖曳一段導線：水平段上下移、垂直段左右移，相鄰的段跟著伸縮
    static func moveSegment(_ pts: [CGPoint], index i: Int, by d: CGFloat) -> [CGPoint] {
        orthogonalize(shiftSegment(pts, index: i, by: d).points)
    }

    /// 拖曳中間的轉角：前後兩段各自平移
    static func moveCorner(_ pts: [CGPoint], index k: Int, by d: CGPoint) -> [CGPoint] {
        guard k > 0, k < pts.count - 1 else { return pts }
        let h1 = pts[k - 1].y == pts[k].y
        let (p1, s1) = shiftSegment(pts, index: k - 1, by: h1 ? d.y : d.x)
        // 轉角現在是 p1[s1 + 1]，下一段的編號是 s1 + 1
        let h2 = p1[s1 + 1].y == p1[s1 + 2].y
        return orthogonalize(shiftSegment(p1, index: s1 + 1, by: h2 ? d.y : d.x).points)
    }

    /// 拖曳導線的頭或尾到 p，相鄰的轉角跟著調整
    static func movingEnd(_ pts: [CGPoint], first: Bool, to p: CGPoint) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        var q = pts
        if first { q[0] = p } else { q[q.count - 1] = p }
        return orthogonalize(reroute(q, movedFirst: first))
    }
}

/// 以格點座標當作字典鍵（避免讓系統型別 CGPoint 直接遵循 Hashable）
struct PointKey: Hashable {
    let x: Int
    let y: Int

    init(_ p: CGPoint) {
        x = Int(p.x.rounded())
        y = Int(p.y.rounded())
    }

    var point: CGPoint { CGPoint(x: x, y: y) }
}
