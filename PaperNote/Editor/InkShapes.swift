import CoreGraphics

/// 自製筆刷停住變圖形：手寫的路徑認成直線、圓弧、圓、橢圓、矩形或三角形，筆不放開繼續移動可以調整大小
struct InkShape: Equatable {
    enum Kind: Equatable { case line, arc, circle, ellipse, rectangle, triangle }

    var kind: Kind
    /// 直線、圓弧的起點與終點（終點跟著筆尖）
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    /// 圓弧的拱高 ÷ 弦長（有正負，決定往哪邊拱）
    var bulge: CGFloat = 0
    /// 封閉圖形剛認出來的外框點、停住時筆尖的位置、調整大小時固定不動的角
    var base: [CGPoint] = []
    var grab: CGPoint = .zero
    var anchor: CGPoint = .zero
    /// 現在的外框點
    var points: [CGPoint] = []
}

enum InkShapes {
    /// 認不出來（太短）回傳 nil
    static func recognize(_ pts: [CGPoint]) -> InkShape? {
        guard pts.count >= 4, let first = pts.first, let last = pts.last else { return nil }
        let length = zip(pts, pts.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        guard length > 15 else { return nil }
        let box = bounds(pts)
        let span = max(box.width, box.height)
        if length > 60, span > 20, first.distance(to: last) < span * 0.35 {
            return closed(pts, box: box, last: last)
        }
        return open(pts)
    }

    /// 筆尖移到 p：直線、圓弧的終點跟著走；封閉圖形依固定角縮放（圓保持是圓）
    static func moved(_ s: InkShape, to p: CGPoint) -> InkShape {
        var s = s
        switch s.kind {
        case .line:
            s.end = ShapeRecognizer.snappedLineEnd(from: s.start, to: p)
            s.points = ShapeRecognizer.segment(s.start, s.end)
        case .arc:
            s.end = p
            s.points = arc(from: s.start, to: s.end, bulge: s.bulge)
        case .circle:
            let d0 = s.grab.distance(to: s.anchor)
            let k = d0 > 8 ? min(max(p.distance(to: s.anchor) / d0, 0.1), 10) : 1
            s.points = s.base.map { CGPoint(x: s.anchor.x + ($0.x - s.anchor.x) * k, y: s.anchor.y + ($0.y - s.anchor.y) * k) }
        case .ellipse, .rectangle, .triangle:
            s.points = HoldToShape.scaled(s.base, grab: s.grab, anchor: s.anchor, to: p)
        }
        return s
    }

    // MARK: 封閉圖形

    private static func closed(_ pts: [CGPoint], box: CGRect, last: CGPoint) -> InkShape {
        // 每種圖形的外框，取和手寫路徑最貼近的；矩形放寬一點（手畫的角常常是圓的）
        var candidates: [(InkShape.Kind, [CGPoint], CGFloat)] = []
        let rect = polygon([CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)])
        candidates.append((.rectangle, rect, 0.7))
        let aspect = min(box.width, box.height) / max(box.width, box.height, 1)
        if aspect > 0.82 {
            let side = (box.width + box.height) / 2
            let sq = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
            candidates.append((.circle, ellipse(in: sq), 1))
        } else {
            candidates.append((.ellipse, ellipse(in: box), 1))
        }
        let corners = ShapeRecognizer.closedCorners(pts, box: box)
        if corners.count == 3 { candidates.append((.triangle, polygon(corners), 0.9)) }

        let best = candidates.min { fitError(pts, $0.1) * $0.2 < fitError(pts, $1.1) * $1.2 }!
        var s = InkShape(kind: best.0, base: best.1, grab: last, points: best.1)
        s.anchor = HoldToShape.anchorCorner(of: best.1, farthestFrom: last) ?? last
        return s
    }

    // MARK: 直線、圓弧

    private static func open(_ pts: [CGPoint]) -> InkShape {
        let a = pts[0], b = pts[pts.count - 1]
        let chord = a.distance(to: b)
        // 離弦最遠的點（圓弧的話就是弧的中點）
        var far = a
        var farDev: CGFloat = 0
        for p in pts {
            let d = abs(signedDistance(p, a, b))
            if d > farDev { farDev = d; far = p }
        }
        if chord > 20, farDev > max(8, chord * 0.12) {
            let h = signedDistance(far, a, b)
            if let c = circleCenter(a, far, b) {
                let r = c.distance(to: a)
                let err = pts.reduce(0) { $0 + abs($1.distance(to: c) - r) } / CGFloat(pts.count)
                if err < max(4, r * 0.12) {
                    let bulge = h / chord
                    return InkShape(kind: .arc, start: a, end: b, bulge: bulge, points: arc(from: a, to: b, bulge: bulge))
                }
            }
        }
        let e = ShapeRecognizer.snappedLineEnd(from: a, to: b)
        return InkShape(kind: .line, start: a, end: e, points: ShapeRecognizer.segment(a, e))
    }

    /// 從 a 到 b、拱高是 bulge × 弦長的圓弧
    static func arc(from a: CGPoint, to b: CGPoint, bulge: CGFloat) -> [CGPoint] {
        let chord = a.distance(to: b)
        let h = bulge * chord
        guard chord > 1, abs(h) > 0.5 else { return ShapeRecognizer.segment(a, b) }
        let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // 弦的法向量（和 signedDistance 的正負同一邊）
        let n = CGPoint(x: -(b.y - a.y) / chord, y: (b.x - a.x) / chord)
        let top = CGPoint(x: m.x + n.x * h, y: m.y + n.y * h)
        guard let c = circleCenter(a, top, b) else { return ShapeRecognizer.segment(a, b) }
        let r = c.distance(to: a)
        let a0 = atan2(a.y - c.y, a.x - c.x), aTop = atan2(top.y - c.y, top.x - c.x), a1 = atan2(b.y - c.y, b.x - c.x)
        // 從 a0 轉到 a1，要經過 aTop
        func norm(_ x: CGFloat) -> CGFloat { var x = x; while x < 0 { x += 2 * .pi }; while x >= 2 * .pi { x -= 2 * .pi }; return x }
        var sweep = norm(a1 - a0)
        if norm(aTop - a0) > sweep { sweep -= 2 * .pi }
        let n0 = max(8, Int(abs(sweep) * r / 3))
        return (0...n0).map { i in
            let t = a0 + sweep * CGFloat(i) / CGFloat(n0)
            return CGPoint(x: c.x + cos(t) * r, y: c.y + sin(t) * r)
        }
    }

    // MARK: 幾何

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// 手寫的每一點到外框的平均距離
    static func fitError(_ pts: [CGPoint], _ outline: [CGPoint]) -> CGFloat {
        guard outline.count >= 2 else { return .greatestFiniteMagnitude }
        var total: CGFloat = 0
        for p in pts {
            var best = CGFloat.greatestFiniteMagnitude
            for (a, b) in zip(outline, outline.dropFirst()) { best = min(best, segmentDistance(p, a, b)) }
            total += best
        }
        return total / CGFloat(pts.count)
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return p.distance(to: a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return p.distance(to: CGPoint(x: a.x + dx * t, y: a.y + dy * t))
    }

    /// p 在 a→b 的哪一邊、離多遠（法向量是 a→b 轉 90°）
    private static func signedDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let len = a.distance(to: b)
        guard len > 0 else { return p.distance(to: a) }
        return ((p.x - a.x) * -(b.y - a.y) + (p.y - a.y) * (b.x - a.x)) / len
    }

    /// 通過三點的圓心（三點幾乎在一直線上回傳 nil）
    private static func circleCenter(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPoint? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-6 else { return nil }
        let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y
        return CGPoint(x: (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
                       y: (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
    }

    static func polygon(_ corners: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 0..<corners.count {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            out.append(contentsOf: ShapeRecognizer.segment(a, b).dropLast())
        }
        out.append(corners[0])
        return out
    }

    static func ellipse(in r: CGRect) -> [CGPoint] {
        let n = 96
        return (0...n).map { i in
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
            return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
        }
    }
}
