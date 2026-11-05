import CoreGraphics

/// 自製筆刷停住變圖形：手寫的路徑認成直線、圓弧、圓、橢圓、矩形或三角形，筆不放開繼續移動可以調整大小
struct InkShape: Equatable {
    /// curve：不是基本圖形，照手畫的修成平滑的曲線
    enum Kind: Equatable { case line, arc, circle, ellipse, rectangle, triangle, curve }

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
    /// 封閉的曲線（頭尾接起來）
    var closed = false
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
            // 外框的角和筆尖一起移動（和矩形一樣），但長寬同比例，圓還是圓
            let c = HoldToShape.movingCorner(of: s.base, anchor: s.anchor) ?? s.grab
            let d0 = c.distance(to: s.anchor)
            let target = HoldToShape.cornerTarget(corner: c, grab: s.grab, pen: p)
            let k = d0 > 8 ? min(max(target.distance(to: s.anchor) / d0, 0.1), 10) : 1
            s.points = s.base.map { CGPoint(x: s.anchor.x + ($0.x - s.anchor.x) * k, y: s.anchor.y + ($0.y - s.anchor.y) * k) }
        case .ellipse, .rectangle, .triangle:
            s.points = HoldToShape.scaled(s.base, grab: s.grab, anchor: s.anchor, to: p)
        case .curve where s.closed:
            s.points = HoldToShape.scaled(s.base, grab: s.grab, anchor: s.anchor, to: p)
        case .curve:
            // 起點不動、終點跟著筆尖：整條曲線一起轉、一起縮放，形狀不變
            let a = s.start, b = s.base.last ?? s.end
            let v0 = CGPoint(x: b.x - a.x, y: b.y - a.y), v1 = CGPoint(x: p.x - a.x, y: p.y - a.y)
            let l0 = hypot(v0.x, v0.y)
            guard l0 > 8 else { break }
            let k = min(max(hypot(v1.x, v1.y) / l0, 0.1), 10)
            let ang = atan2(v1.y, v1.x) - atan2(v0.y, v0.x)
            let t = CGAffineTransform(translationX: a.x, y: a.y).rotated(by: ang).scaledBy(x: k, y: k).translatedBy(x: -a.x, y: -a.y)
            s.points = s.base.map { $0.applying(t) }
            s.end = s.points.last ?? p
        }
        return s
    }

    // MARK: 封閉圖形

    /// 封閉圖形和手畫的平均差多少以內算是這個圖形（外框大小的比例）；再差就修成平滑的曲線
    static let closedShapeTolerance: CGFloat = 0.08

    private static func closed(_ pts: [CGPoint], box: CGRect, last: CGPoint) -> InkShape {
        // 每種圖形的外框，取和手寫路徑最貼近的；矩形放寬一點（手畫的角常常是圓的）
        var candidates: [(InkShape.Kind, [CGPoint], CGFloat)] = []
        let aspect = min(box.width, box.height) / max(box.width, box.height, 1)
        // 差不多是正方形就畫成正方形
        let rectBox = aspect > 0.85 ? square(around: box) : box
        let rect = polygon([CGPoint(x: rectBox.minX, y: rectBox.minY), CGPoint(x: rectBox.maxX, y: rectBox.minY),
                            CGPoint(x: rectBox.maxX, y: rectBox.maxY), CGPoint(x: rectBox.minX, y: rectBox.maxY)])
        candidates.append((.rectangle, rect, 0.7))
        if aspect > 0.78 {
            candidates.append((.circle, ellipse(in: square(around: box)), 1))
        } else {
            candidates.append((.ellipse, ellipse(in: box), 1))
        }
        let corners = ShapeRecognizer.closedCorners(pts, box: box)
        if corners.count == 3 { candidates.append((.triangle, polygon(corners), 0.9)) }

        let scored = candidates.map { ($0, fitError(pts, $0.1)) }
        let best = scored.min { $0.1 * $0.0.2 < $1.1 * $1.0.2 }!
        let span = max(box.width, box.height)
        let fits = best.1 * best.0.2 <= max(5, span * closedShapeTolerance)
        let kind = fits ? best.0.0 : .curve
        let outline = fits ? best.0.1 : smoothCurve(pts, closed: true)
        var s = InkShape(kind: kind, base: outline, grab: last, points: outline, closed: kind == .curve)
        s.anchor = HoldToShape.anchorCorner(of: outline, farthestFrom: last) ?? last
        return s
    }

    private static func square(around box: CGRect) -> CGRect {
        let side = (box.width + box.height) / 2
        return CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
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
        // 偏離不大就是直線（手畫的直線常常有點彎）
        if chord <= 20 || farDev <= max(8, chord * 0.12) {
            let e = ShapeRecognizer.snappedLineEnd(from: a, to: b)
            return InkShape(kind: .line, start: a, end: e, points: ShapeRecognizer.segment(a, e))
        }
        let h = signedDistance(far, a, b)
        if let c = circleCenter(a, far, b) {
            let r = c.distance(to: a)
            let err = pts.reduce(0) { $0 + abs($1.distance(to: c) - r) } / CGFloat(pts.count)
            if err < arcTolerance(height: farDev, radius: r) {
                let bulge = h / chord
                return InkShape(kind: .arc, start: a, end: b, bulge: bulge, points: arc(from: a, to: b, bulge: bulge))
            }
        }
        // 其他的（波浪、S 形、勾…）：照手畫的修成平滑的曲線，頭尾不動
        let curve = smoothCurve(pts, closed: false)
        return InkShape(kind: .curve, start: a, end: b, base: curve, grab: b, anchor: a, points: curve)
    }

    /// 圓弧和手畫的平均差多少以內算圓弧：拱高的 8%（最少 4pt），也不超過半徑的 14%。
    /// 要和拱高比，不能只看半徑：越扁的弧半徑越大（約 弦長² ÷ 8 拱高），扁的波浪、雙拱都會被當成圓弧
    static func arcTolerance(height h: CGFloat, radius r: CGFloat) -> CGFloat {
        max(4, min(h * 0.08, r * 0.14))
    }

    // MARK: 平滑的曲線

    /// 用分段的三次多項式（均勻三次 B 樣條，最小平方法）逼近手畫的一筆：晃動拿掉，形狀照手畫的走。
    /// 控制點從少試到多（越少越平滑），和手畫的平均差不到 tolerance 就停。開放的曲線頭尾和手畫的一樣
    static func smoothCurve(_ input: [CGPoint], closed: Bool) -> [CGPoint] {
        let pts = resampled(input, spacing: 3)
        guard pts.count >= 8 else { return input }
        let length = CGFloat(pts.count - 1) * 3
        let tolerance = min(max(1.5, length * 0.006), 4)
        var m = closed ? 5 : 4
        let most = max(m, min(80, pts.count / 3))
        var best = input
        while true {
            if let c = fitSpline(pts, controls: m, closed: closed) {
                best = evaluateSpline(c, closed: closed)
                if fitError(pts, best) <= tolerance { break }
            }
            if m >= most { break }
            m = min(most, m < 10 ? m + 1 : Int((CGFloat(m) * 1.3).rounded(.up)))
        }
        return best
    }

    /// 每隔 spacing 取一點（頭尾一定在）
    static func resampled(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard var prev = pts.first else { return [] }
        var out = [prev]
        var carry: CGFloat = 0
        for p in pts.dropFirst() {
            var d = prev.distance(to: p)
            var from = prev
            while carry + d >= spacing {
                let t = (spacing - carry) / d
                from = CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t)
                out.append(from)
                d = from.distance(to: p)
                carry = 0
            }
            carry += d
            prev = p
        }
        // 最後一點就是手畫的終點（太靠近的那一點換掉）
        if pts.count > 1, let last = pts.last {
            if out.count > 1, out[out.count - 1].distance(to: last) < spacing / 2 { out.removeLast() }
            out.append(last)
        }
        return out
    }

    /// 均勻三次 B 樣條在一段裡（u 從 0 到 1）的四個權重
    private static func basis(_ u: CGFloat) -> [CGFloat] {
        let u2 = u * u, u3 = u2 * u
        return [(1 - u) * (1 - u) * (1 - u) / 6, (3 * u3 - 6 * u2 + 4) / 6, (-3 * u3 + 3 * u2 + 3 * u + 1) / 6, u3 / 6]
    }

    /// 開放：控制點頭尾固定在手畫的頭尾、各重複三次（曲線剛好從那裡開始、結束），共 m + 1 段；
    /// 封閉：m 個控制點繞一圈，m 段
    private static func controlIndex(_ e: Int, controls m: Int, closed: Bool) -> Int {
        closed ? e % m : min(max(e - 2, 0), m - 1)
    }

    private static func segments(controls m: Int, closed: Bool) -> Int { closed ? m : m + 1 }

    /// 最小平方法解控制點（加一點點平滑項，資料少的段也解得出來）
    private static func fitSpline(_ pts: [CGPoint], controls m: Int, closed: Bool) -> [CGPoint]? {
        let n = pts.count
        let segs = segments(controls: m, closed: closed)
        // 每一點在曲線上的位置：照弧長平均分
        var s: [CGFloat] = [0]
        for i in 1..<n { s.append(s[i - 1] + pts[i].distance(to: pts[i - 1])) }
        let total = s[n - 1] + (closed ? pts[n - 1].distance(to: pts[0]) : 0)
        guard total > 0 else { return nil }
        // 未知數：封閉的全部；開放的頭尾固定
        let fixed: [Int: CGPoint] = closed ? [:] : [0: pts[0], m - 1: pts[n - 1]]
        var unknown: [Int: Int] = [:]
        for c in 0..<m where fixed[c] == nil { unknown[c] = unknown.count }
        let k = unknown.count
        guard k > 0 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var bx = [Double](repeating: 0, count: k), by = [Double](repeating: 0, count: k)

        // rows: 一列是 Σ w·c = target
        func addRow(_ terms: [(Int, CGFloat)], _ target: CGPoint, weight: Double) {
            var tx = Double(target.x), ty = Double(target.y)
            var vars: [(Int, Double)] = []
            for (c, w) in terms {
                if let f = fixed[c] { tx -= Double(w) * Double(f.x); ty -= Double(w) * Double(f.y) } else { vars.append((unknown[c]!, Double(w))) }
            }
            for (i, wi) in vars {
                bx[i] += weight * wi * tx
                by[i] += weight * wi * ty
                for (j, wj) in vars { a[i][j] += weight * wi * wj }
            }
        }
        for i in 0..<n {
            let t = s[i] / total * CGFloat(segs)
            let j = min(Int(t), segs - 1)
            let w = basis(t - CGFloat(j))
            addRow((0..<4).map { (controlIndex(j + $0, controls: m, closed: closed), w[$0]) }, pts[i], weight: 1)
        }
        // 平滑項：相鄰三個控制點的二次差分
        let smooth = 0.02 * Double(n) / Double(m)
        for c in 0..<m {
            guard closed || (c > 0 && c < m - 1) else { continue }
            addRow([((c + m - 1) % m, 1), (c, -2), ((c + 1) % m, 1)], .zero, weight: smooth)
        }
        guard let xs = solve(a, bx), let ys = solve(a, by) else { return nil }
        return (0..<m).map { c in fixed[c] ?? CGPoint(x: xs[unknown[c]!], y: ys[unknown[c]!]) }
    }

    /// 控制點畫成曲線（每段 10 點）
    private static func evaluateSpline(_ c: [CGPoint], closed: Bool) -> [CGPoint] {
        let m = c.count
        let segs = segments(controls: m, closed: closed)
        let per = 10
        var out: [CGPoint] = []
        for j in 0..<segs {
            for step in 0..<per {
                let w = basis(CGFloat(step) / CGFloat(per))
                var p = CGPoint.zero
                for k in 0..<4 {
                    let q = c[controlIndex(j + k, controls: m, closed: closed)]
                    p.x += q.x * w[k]
                    p.y += q.y * w[k]
                }
                out.append(p)
            }
        }
        if closed {
            if let first = out.first { out.append(first) }
        } else if let last = c.last {
            out.append(last)
        }
        return out
    }

    /// 高斯消去法（部分選主元）；解不出來回傳 nil
    private static func solve(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = b.count
        for col in 0..<n {
            guard let piv = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[piv][col]) > 1e-12 else { return nil }
            a.swapAt(col, piv)
            b.swapAt(col, piv)
            for r in (col + 1)..<n where a[r][col] != 0 {
                let f = a[r][col] / a[col][col]
                for c in col..<n { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var v = b[r]
            for c in (r + 1)..<n { v -= a[r][c] * x[c] }
            x[r] = v / a[r][r]
        }
        return x
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
