import Foundation
import CoreGraphics

/// 電路元件種類
enum CircuitPart: String, Codable, CaseIterable, Identifiable {
    case resistor, capacitor, inductor, voltageSource, currentSource, ground, vdd
    case nmos, pmos
    case andGate, orGate, nandGate, norGate, xorGate, xnorGate, notGate, bufferGate
    case dFlipFlop, dLatch, mux, decoder, encoder

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
        case .dFlipFlop: return "D 正反器"
        case .dLatch: return "D 閂鎖"
        case .mux: return "多工器"
        case .decoder: return "解碼器"
        case .encoder: return "編碼器"
        }
    }

    /// 方塊元件（正反器、閂鎖、多工器、解碼器、編碼器）
    var isBlock: Bool {
        switch self {
        case .dFlipFlop, .dLatch, .mux, .decoder, .encoder: return true
        default: return false
        }
    }

    /// 大小（輸入數或位元數）可以調的範圍；1...1 代表不能調
    var sizeRange: ClosedRange<Int> {
        if hasVariableInputs && isGate { return 2...8 }
        switch self {
        case .mux: return 2...16
        case .decoder, .encoder: return 1...4
        default: return 1...1
        }
    }

    var defaultSize: Int {
        switch self {
        case .mux: return 4
        default: return 2
        }
    }

    /// 工具列上顯示的大小
    func sizeLabel(_ n: Int) -> String {
        switch self {
        case .decoder: return "\(n) → \(1 << n)"
        case .encoder: return "\(1 << n) → \(n)"
        default: return "\(n) 輸入"
        }
    }

    var isGate: Bool {
        switch self {
        case .andGate, .orGate, .nandGate, .norGate, .xorGate, .xnorGate, .notGate, .bufferGate: return true
        default: return false
        }
    }

    /// 可以調整輸入數量（或位元數）的元件
    var hasVariableInputs: Bool {
        (isGate && self != .notGate && self != .bufferGate) || self == .mux || self == .decoder || self == .encoder
    }

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
    /// 邏輯閘、多工器的輸入數量；解碼器、編碼器的位元數
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
    /// 整個電路圖在頁面上的縮放：頁面上的大小 = 內容座標 × scale（符號、線寬一起縮）。
    /// 舊的電路圖沒有這個值，照原本的大小
    var symbolScale: CGFloat?

    var scale: CGFloat { symbolScale ?? 1 }

    static let grid: CGFloat = 10
    static let margin: CGFloat = 24
    /// 新建的電路圖：符號和線都是原本的一半
    static let newScale: CGFloat = 0.5
    static var newCircuit: CircuitData { CircuitData(symbolScale: newScale) }

    static func snap(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x / grid).rounded() * grid, y: (p.y / grid).rounded() * grid)
    }

    /// 頁面座標對齊這個電路圖在頁面上的格點（grid × scale）
    func snapOnPage(_ p: CGPoint) -> CGPoint {
        let g = Self.grid * scale
        return CGPoint(x: (p.x / g).rounded() * g, y: (p.y / g).rounded() * g)
    }
}

// MARK: - 元件幾何（元件自己的座標系：中心為原點、預設朝右）

/// 方塊元件的接腳：左邊輸入、下方（多工器的選擇線）、右邊輸出。名字前面加 ~ 代表反相（畫上橫線）
struct CircuitBlockLayout: Equatable {
    var title: String
    var left: [String]
    var bottom: [String]
    var right: [String]
    /// 左邊第幾支腳是時脈（畫三角形）
    var clock: Int?

    /// 本體寬度的一半、接腳的 x、左右接腳的間距（正反器、閂鎖用窄高的小方塊）
    var halfWidth: CGFloat = 40
    var pinX: CGFloat = 60
    var spacing: CGFloat = 20
    /// 多工器：畫成梯形（左邊寬、右邊窄）
    var trapezoid = false

    /// 梯形右邊比左邊每側縮進多少
    var trapezoidInset: CGFloat { trapezoid ? min(height / 2 * 0.4, 40) : 0 }

    /// 下緣在 x 處的 y（梯形的下緣是斜的）
    func bottomEdge(at x: CGFloat) -> CGFloat { height / 2 - trapezoidInset * (x + halfWidth) / (2 * halfWidth) }

    /// 本體高度（依左右兩邊較多的那邊）
    var height: CGFloat { CGFloat(max(left.count, right.count, 2)) * spacing + (spacing >= 40 ? 0 : 20) }

    /// 左右接腳的 y
    func sideOffsets(_ n: Int) -> [CGFloat] { CircuitGeometry.spread(n, spacing: spacing) }
}

enum CircuitGeometry {
    static func blockLayout(_ c: CircuitComponent) -> CircuitBlockLayout? {
        switch c.part {
        case .dFlipFlop:
            return CircuitBlockLayout(title: "D FF", left: ["D", "CLK"], bottom: [], right: ["Q", "~Q"], clock: 1,
                                      halfWidth: 20, pinX: 30, spacing: 40)
        case .dLatch:
            return CircuitBlockLayout(title: "D Latch", left: ["D", "EN"], bottom: [], right: ["Q", "~Q"], clock: nil,
                                      halfWidth: 20, pinX: 30, spacing: 40)
        case .mux:
            let n = min(max(c.inputs, 2), 16)
            var k = 0
            while (1 << k) < n { k += 1 }
            return CircuitBlockLayout(title: "MUX", left: (0..<n).map { "I\($0)" }, bottom: (0..<k).map { "S\($0)" },
                                      right: ["Y"], clock: nil, trapezoid: true)
        case .decoder:
            let n = min(max(c.inputs, 1), 4)
            return CircuitBlockLayout(title: "DEC", left: (0..<n).map { "A\($0)" }, bottom: [],
                                      right: (0..<(1 << n)).map { "Y\($0)" }, clock: nil)
        case .encoder:
            let n = min(max(c.inputs, 1), 4)
            return CircuitBlockLayout(title: "ENC", left: (0..<(1 << n)).map { "I\($0)" }, bottom: [],
                                      right: (0..<n).map { "Y\($0)" }, clock: nil)
        default:
            return nil
        }
    }

    /// 一排接腳的位置：以 0 為中心、間隔 spacing（20 的倍數，都落在格點上）
    static func spread(_ n: Int, spacing: CGFloat = 20) -> [CGFloat] {
        (0..<n).map { (CGFloat($0) - CGFloat(n - 1) / 2) * spacing }
    }

    /// 方塊元件的接腳（順序：左、下、右）
    static func blockPins(_ b: CircuitBlockLayout) -> [CGPoint] {
        let x = b.pinX
        return b.sideOffsets(b.left.count).map { CGPoint(x: -x, y: $0) }
            + spread(b.bottom.count).map { CGPoint(x: $0, y: b.height / 2 + 20) }
            + b.sideOffsets(b.right.count).map { CGPoint(x: x, y: $0) }
    }

    /// 每支接腳的名字（改大小時，接在同名接腳上的導線跟著走）
    static func pinNames(_ c: CircuitComponent) -> [String] {
        if let b = blockLayout(c) { return b.left + b.bottom + b.right }
        let pins = localPins(c)
        if c.part.isGate { return (0..<(pins.count - 1)).map { "I\($0)" } + ["Y"] }
        return (0..<pins.count).map { "P\($0)" }
    }

    /// 邏輯閘本體高度
    static func gateHeight(_ c: CircuitComponent) -> CGFloat {
        let n = c.part.hasVariableInputs && c.part.isGate ? max(2, c.inputs) : 1
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
        if let b = blockLayout(c) { return blockPins(b) }
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
        if let b = blockLayout(c) {
            // 上方留給標題，下方留給選擇線
            let top = -b.height / 2 - 14
            let bottom = b.height / 2 + (b.bottom.isEmpty ? 0 : 20)
            return CGRect(x: -b.pinX, y: top, width: b.pinX * 2, height: bottom - top)
        }
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

    /// 每支接腳的引腳方向（從接腳往元件裡、水平或垂直的單位向量，電路圖座標）
    static func pinLeads(_ c: CircuitComponent) -> [CGPoint] {
        let b = localBounds(c)
        let t = transform(c)
        return localPins(c).map { p in
            var d: CGPoint
            if abs(p.x - b.minX) < 0.5 { d = CGPoint(x: 1, y: 0) }
            else if abs(p.x - b.maxX) < 0.5 { d = CGPoint(x: -1, y: 0) }
            else if abs(p.y - b.minY) < 0.5 { d = CGPoint(x: 0, y: 1) }
            else if abs(p.y - b.maxY) < 0.5 { d = CGPoint(x: 0, y: -1) }
            else { d = abs(p.x) >= abs(p.y) ? CGPoint(x: p.x > 0 ? -1 : 1, y: 0) : CGPoint(x: 0, y: p.y > 0 ? -1 : 1) }
            let q = CGPoint(x: t.a * d.x + t.c * d.y, y: t.b * d.x + t.d * d.y)
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

    /// 兩條線的線頭接在同一點、剛好接成一直線，那點又沒有接腳或別的線頭、轉角：其實是同一條線，接成一條。
    /// 不然從中間橫越的線會被當成「直直經過」，跨線半圓反而畫到那條橫越的線上。
    /// 接起來的線沿用 keep 的 id（是其中一條的話），否則沿用前面那條的
    mutating func joinStraightRuns(keeping keep: UUID? = nil) {
        let pins = Set(allPins.map(PointKey.init))
        var joined = true
        while joined {
            joined = false
            search: for i in wires.indices {
                for j in wires.indices where j > i {
                    for a in [wires[i].points, Array(wires[i].points.reversed())] {
                        for b in [wires[j].points, Array(wires[j].points.reversed())] {
                            guard a.count >= 2, b.count >= 2, let p = a.last, p == b[0],
                                  Self.direction(a[a.count - 2], p) == Self.direction(p, b[1]),
                                  !pins.contains(PointKey(p)),
                                  !wires.indices.contains(where: { $0 != i && $0 != j && wires[$0].points.contains(p) }) else { continue }
                            var w = wires[wires[j].id == keep ? j : i]
                            w.points = Self.orthogonalize(a + b.dropFirst())
                            wires[i] = w
                            wires.remove(at: j)
                            joined = true
                            break search
                        }
                    }
                }
            }
        }
    }

    /// 元件移動／旋轉後，接在舊接腳上的導線跟著走：
    /// 1. 端點在舊接腳上的導線移到新接腳，相鄰的轉角跟著調整（從接腳中間經過的線沒有接上，留在原地）
    /// 2. 原本接在這些導線上（T 字接點）、現在脫開的分支，接回那條導線上最近的位置
    mutating func reattach(from oldPins: [CGPoint], to newPins: [CGPoint]) {
        guard oldPins.count == newPins.count else { return }
        var before = wires
        for i in wires.indices {
            var pts = wires[i].points
            guard pts.count >= 2 else { continue }
            if let k = oldPins.firstIndex(of: pts[0]) { pts[0] = newPins[k]; pts = Self.reroute(pts, movedFirst: true) }
            if let k = oldPins.firstIndex(of: pts[pts.count - 1]) { pts[pts.count - 1] = newPins[k]; pts = Self.reroute(pts, movedFirst: false) }
            wires[i].points = Self.orthogonalize(pts)
        }
        // 分支跟著接回去；分支的分支下一輪再處理
        for _ in 0..<4 {
            let moved = wires
            if !reconnectBranches(before: before) { break }
            before = moved
        }
        wires.removeAll { $0.points.count < 2 }
    }

    /// 端點原本在別條導線上、那條線改了走線後脫開的，移到那條線上最近的位置。有移動就回傳 true
    private mutating func reconnectBranches(before: [CircuitWire]) -> Bool {
        let pins = allPins
        var changed = false
        for wi in wires.indices {
            for first in [true, false] {
                let pts = wires[wi].points
                guard pts.count >= 2 else { continue }
                let end = first ? pts[0] : pts[pts.count - 1]
                if pins.contains(end) { continue }
                for vj in before.indices where vj != wi && vj < wires.count {
                    guard Self.polyline(before[vj].points, contains: end),
                          !Self.polyline(wires[vj].points, contains: end),
                          let q = Self.nearestPoint(on: wires[vj].points, to: end) else { continue }
                    wires[wi].points = Self.movingEnd(pts, first: first, to: q)
                    changed = true
                    break
                }
            }
        }
        return changed
    }

    /// 點在折線上（含端點與轉角）
    static func polyline(_ pts: [CGPoint], contains p: CGPoint) -> Bool {
        if pts.contains(p) { return true }
        for k in 0..<max(0, pts.count - 1) where segment(pts[k], pts[k + 1], contains: p) { return true }
        return false
    }

    /// 折線上離 p 最近的點（沿線方向對齊格點）
    static func nearestPoint(on pts: [CGPoint], to p: CGPoint) -> CGPoint? {
        var best: CGPoint?
        var bestD = CGFloat.greatestFiniteMagnitude
        for k in 0..<max(0, pts.count - 1) {
            let a = pts[k], b = pts[k + 1]
            var q: CGPoint
            if a.y == b.y {
                q = CGPoint(x: min(max(snap(p).x, min(a.x, b.x)), max(a.x, b.x)), y: a.y)
            } else {
                q = CGPoint(x: a.x, y: min(max(snap(p).y, min(a.y, b.y)), max(a.y, b.y)))
            }
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestD { bestD = d; best = q }
        }
        return best
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

    /// 某一點上接在一起的情形：碰到這點的導線與接腳分成幾組，同一組的才算接上
    private struct Node {
        /// 導線編號 → 在這點往外走的方向
        var wireDirs: [Int: Set<PointKey>] = [:]
        /// 從這點中間直直經過的導線 → 段編號
        var through: [Int: Int] = [:]
        /// 在這點的接腳（wires.count + 第幾支）與引腳方向
        var pinIDs: [Int] = []
        var pinDirs: [PointKey] = []
        /// 組別：導線用編號、接腳用 wires.count + 第幾支
        var group: [Int: Int] = [:]
    }

    /// 接上的規則（只看導線的頭尾）：
    /// - 兩條線重疊走同一個方向：接上
    /// - 線頭停在這點：和這點的線都接上；但這點是接腳時，從中間經過的線不算，
    ///   兩筆線頭剛好接成一直線時，從中間橫越的線也不算（都是跨線）
    private func node(at p: CGPoint, pins: [(point: CGPoint, lead: CGPoint)]) -> Node {
        var n = Node()
        var ends: [Int] = []
        for (wi, w) in wires.enumerated() where w.points.count >= 2 {
            let pts = w.points
            var dirs = Set<PointKey>()
            for k in 0..<(pts.count - 1) {
                let a = pts[k], b = pts[k + 1]
                if a == p && b != p { dirs.insert(PointKey(Self.direction(a, b))) }
                if b == p && a != p { dirs.insert(PointKey(Self.direction(b, a))) }
                if Self.segment(a, b, contains: p) {
                    dirs.insert(PointKey(Self.direction(p, a)))
                    dirs.insert(PointKey(Self.direction(p, b)))
                    n.through[wi] = k
                }
            }
            guard !dirs.isEmpty else { continue }
            n.wireDirs[wi] = dirs
            if pts[0] == p || pts[pts.count - 1] == p { ends.append(wi) }
        }
        let pinIDs = pins.indices.filter { pins[$0].point == p }.map { wires.count + $0 }
        n.pinIDs = pinIDs
        n.pinDirs = pinIDs.map { PointKey(pins[$0 - wires.count].lead) }

        var parent: [Int: Int] = [:]
        func find(_ x: Int) -> Int { var x = x; while let q = parent[x], q != x { x = q }; return x }
        func union(_ x: Int, _ y: Int) { parent[find(x)] = find(y) }
        let ids = Array(n.wireDirs.keys) + pinIDs
        for x in ids { parent[x] = x }
        let wireIDs = Array(n.wireDirs.keys)
        for (i, x) in wireIDs.enumerated() {
            for y in wireIDs[(i + 1)...] where !n.wireDirs[x]!.isDisjoint(with: n.wireDirs[y]!) { union(x, y) }
        }
        if !pinIDs.isEmpty {
            for x in ends + pinIDs.dropFirst() { union(x, pinIDs[0]) }
        } else if ends.count == 2, let d0 = n.wireDirs[ends[0]], let d1 = n.wireDirs[ends[1]],
                  d0.count == 1, d1.count == 1, let a = d0.first, let b = d1.first, a.x == -b.x, a.y == -b.y {
            union(ends[0], ends[1])
        } else if let e = ends.first {
            for x in ids { union(x, e) }
        }
        for x in ids { n.group[x] = find(x) }
        return n
    }

    private var pinsWithLeads: [(point: CGPoint, lead: CGPoint)] {
        components.flatMap { c in Array(zip(CircuitGeometry.pins(c), CircuitGeometry.pinLeads(c))).map { (point: $0.0, lead: $0.1) } }
    }

    /// 導線的頭尾、轉角與接腳的位置（分岔只會出現在這些點）
    private func vertexPoints(_ pins: [(point: CGPoint, lead: CGPoint)]) -> Set<PointKey> {
        Set(wires.flatMap { $0.points }.map(PointKey.init) + pins.map { PointKey($0.point) })
    }

    /// 需要畫實心圓點的接點：接在一起的線在這裡分成 3 個以上的方向（分岔的地方）。
    /// 線從中間經過的地方不算接上，所以不會有圓點
    func junctions() -> [CGPoint] {
        let pins = pinsWithLeads
        var result: [CGPoint] = []
        for key in vertexPoints(pins) {
            let p = key.point
            let n = node(at: p, pins: pins)
            var arms: [Int: Set<PointKey>] = [:]
            for (wi, dirs) in n.wireDirs { arms[n.group[wi]!, default: []].formUnion(dirs) }
            for (pid, d) in zip(n.pinIDs, n.pinDirs) { arms[n.group[pid]!, default: []].insert(d) }
            if arms.values.contains(where: { $0.count >= 3 }) { result.append(p) }
        }
        return result
    }

    /// a 往 b 的方向（水平或垂直的單位向量）
    private static func direction(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: b.x > a.x ? 1 : (b.x < a.x ? -1 : 0), y: b.y > a.y ? 1 : (b.y < a.y ? -1 : 0))
    }

    static func segment(_ a: CGPoint, _ b: CGPoint, contains p: CGPoint) -> Bool {
        if a.x == b.x && p.x == a.x { return p.y > min(a.y, b.y) && p.y < max(a.y, b.y) }
        if a.y == b.y && p.y == a.y { return p.x > min(a.x, b.x) && p.x < max(a.x, b.x) }
        return false
    }

    /// 線從中間經過、沒有接上的地方，在經過的那條線上畫跨線半圓。
    /// 回傳 (導線編號, 段編號, 位置：水平段是 x、垂直段是 y)；兩條線都直直經過時畫在水平那條
    func crossings() -> [(wire: Int, segment: Int, at: CGFloat)] {
        let pins = pinsWithLeads
        var points = vertexPoints(pins)
        // 兩條線中間互相穿過的位置
        for w in wires where w.points.count >= 2 {
            for (a, b) in zip(w.points, w.points.dropFirst()) where a.y == b.y {
                for v in wires where v.points.count >= 2 {
                    for (c, d) in zip(v.points, v.points.dropFirst()) where c.x == d.x {
                        let q = CGPoint(x: c.x, y: a.y)
                        if Self.segment(a, b, contains: q) && Self.segment(c, d, contains: q) { points.insert(PointKey(q)) }
                    }
                }
            }
        }
        var out: [(wire: Int, segment: Int, at: CGFloat)] = []
        for key in points {
            let p = key.point
            let n = node(at: p, pins: pins)
            guard !n.through.isEmpty else { continue }
            for (wi, si) in n.through {
                let a = wires[wi].points[si], b = wires[wi].points[si + 1]
                let horizontal = a.y == b.y
                func perpendicular(_ d: PointKey) -> Bool { horizontal ? d.x == 0 : d.y == 0 }
                var hop = false
                for (vj, dirs) in n.wireDirs where vj != wi && n.group[vj] != n.group[wi] {
                    let cross = dirs.filter(perpendicular)
                    guard !cross.isEmpty else { continue }
                    // 兩條都直直經過：只在水平那條畫
                    if cross.count == 2 && n.through[vj] != nil && !horizontal { continue }
                    hop = true
                }
                for (pid, d) in zip(n.pinIDs, n.pinDirs) where n.group[pid] != n.group[wi] && perpendicular(d) { hop = true }
                if hop { out.append((wi, si, horizontal ? p.x : p.y)) }
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

    /// 手繪 VDD／GND：一條直線往下（或往上）畫，線尾左右來回畫一小橫。
    /// 往下 → 接地，往上 → VDD。回傳線尾那一小橫的位置（轉角）與元件種類；不像就回傳 nil。
    /// 線尾那一橫要「左右兩邊都畫到」，一般往下再往右的 L 形導線不會被當成符號。
    static func terminalGesture(_ ink: [CGPoint], tolerance: CGFloat = 6) -> (corner: CGPoint, part: CircuitPart)? {
        let simple = simplify(ink, tolerance: tolerance)
        guard simple.count >= 3 else { return nil }
        // 最後一段夠長的垂直段
        var k: Int?
        for i in stride(from: simple.count - 2, through: 0, by: -1) {
            let a = simple[i], b = simple[i + 1]
            if abs(b.y - a.y) > abs(b.x - a.x), abs(b.y - a.y) >= 20 {
                k = i
                break
            }
        }
        guard let k, k + 2 < simple.count else { return nil }
        let corner = simple[k + 1]
        // 線尾用原始筆跡量：化簡會把在同一條線上來回的部分吃掉
        guard let ci = ink.firstIndex(of: corner) else { return nil }
        let tail = ink[ci...]
        let xs = tail.map(\.x), ys = tail.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        // 線尾：左右兩邊都超過 6、幾乎沒有上下移動、不會太長
        guard corner.x - minX > 6, maxX - corner.x > 6, maxY - minY < 14, maxX - minX < 80 else { return nil }
        return (corner, simple[k + 1].y > simple[k].y ? .ground : .vdd)
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
