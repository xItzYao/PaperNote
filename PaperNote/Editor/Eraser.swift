import UIKit
import PencilKit

/// 橡皮擦擦 PencilKit 的筆跡（App 自己擦，不用 PencilKit 的橡皮擦）：一邊擦一邊消失。
/// 筆跡是沿著中心軌跡的一個一個圓（圓心在軌跡上、半徑是畫出來的線寬一半）。
/// 橡皮擦碰到哪個圓的任何一點，就把那個圓心拿掉，整個圓跟著不見：螢光筆比橡皮擦粗，擦一條線過去，那裡整個寬度都擦掉
enum StrokeEraser {
    /// 畫出來最粗的半個線寬（快速排除用，比任何筆都粗）
    private static let maxReach: CGFloat = 60

    /// 橡皮擦沿著 path（文件座標）走過、半徑 radius。整筆擦除：碰到就整筆拿掉；局部擦除：拿掉碰到的那些圓，其他留著。
    /// 沒有變化回傳 nil
    static func erase(_ strokes: [PKStroke], along path: [CGPoint], radius: CGFloat, partial: Bool) -> [PKStroke]? {
        guard let first = path.first else { return nil }
        let area = path.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            .insetBy(dx: -radius - 1, dy: -radius - 1)
        var changed = false
        var out: [PKStroke] = []
        out.reserveCapacity(strokes.count)
        for s in strokes {
            // 先用外框快速排除，碰得到的才細算
            guard s.renderBounds.insetBy(dx: -maxReach, dy: -maxReach).intersects(area) else {
                out.append(s)
                continue
            }
            let k = abs(s.transform.a * s.transform.d - s.transform.b * s.transform.c).squareRoot()
            // 斜的筆頭橫著畫時外框比較扁：外框加上長的那邊算
            let widest = s.path.map(\.size.width).max() ?? 0
            let reach = drawnHalfWidth(s.ink, CGSize(width: widest, height: widest)) * k
            guard s.renderBounds.insetBy(dx: -reach, dy: -reach).intersects(area) else {
                out.append(s)
                continue
            }
            // 每 2pt 取一個點檢查（記下在筆跡上的參數位置，切開時才找得到原本的控制點）
            let sp = s.path
            guard sp.count > 0 else {
                out.append(s)
                continue
            }
            let end = CGFloat(max(sp.count - 1, 0))
            var params: [CGFloat] = [0]
            while let t = params.last, t < end {
                let next = min(sp.parametricValue(t, offsetBy: .distance(2)), end)
                guard next > t else { break }
                params.append(next)
            }
            if let t = params.last, t < end { params.append(end) }
            let pts = params.map { sp.interpolatedPoint(at: $0) }
            // 先看距離（便宜），碰得到的再看那裡是不是已經擦掉了（螢光筆遮罩外面，見 maskedOut）
            let hit = pts.map { q -> Bool in
                let w = q.location.applying(s.transform)
                return distance(w, to: path) <= radius + drawnHalfWidth(s.ink, q.size) * k && isShown(s, q.location)
            }
            guard hit.contains(true) else {
                out.append(s)
                continue
            }
            changed = true
            guard partial else { continue }
            // 半透明的螢光筆：還是同一筆，擦掉的部分用遮罩挖掉。切成好幾筆的話，自己交錯的地方變成兩筆疊在一起，顏色變深
            if NotebookViewController.isHighlighterStroke(s) {
                if let m = maskedOut(s, samples: pts, hit: hit) { out.append(m) }
                continue
            }
            let gone = zip(hit, pts).map { h, q in h || !isShown(s, q.location) }
            guard gone.contains(false) else { continue }
            // 局部擦除：連續沒碰到的一段各自變成一筆（同一條筆跡的亂數種子，鉛筆、蠟筆的紋路不會變）。
            // 一段用的是原本的控制點，只有切開的兩端補上切點：不能拿曲線上取的點當控制點，
            // PencilKit 的線是控制點拉出來的平滑曲線，取樣的點再當控制點會再平滑一次，
            // 擦一下（擦的時候一直在擦）整條就平滑一次，彎的地方越擦越直
            var start: Int?
            func flush(_ last: Int) {
                defer { start = nil }
                guard let a = start, last > a else { return }
                let t0 = params[a], t1 = params[last]
                // 原本的頭尾沒被擦到：用原本的點
                var cps = [t0 == 0 ? sp[0] : pts[a]]
                var i = Int(t0.rounded(.down)) + 1
                while CGFloat(i) < t1 {
                    cps.append(sp[i])
                    i += 1
                }
                cps.append(t1 == end ? sp[sp.count - 1] : pts[last])
                let p = PKStrokePath(controlPoints: cps, creationDate: sp.creationDate)
                out.append(PKStroke(ink: s.ink, path: p, transform: s.transform, mask: s.mask, randomSeed: s.randomSeed))
            }
            for (j, h) in gone.enumerated() {
                if h {
                    if start != nil { flush(j - 1) }
                } else if start == nil {
                    start = j
                }
            }
            if start != nil { flush(gone.count - 1) }
        }
        return changed ? out : nil
    }

    /// 筆跡上的這一點（筆跡的 path 座標）畫得出來：沒有遮罩，或在遮罩裡面。
    /// 擦掉的地方只記在遮罩（畫面、套索、橡皮擦都看它）：點的透明度是 Pencil 的筆壓資料（水彩 0.01 左右），不能拿來記擦掉了
    static func isShown(_ s: PKStroke, _ location: CGPoint) -> Bool {
        s.mask?.contains(location) ?? true
    }

    /// 螢光筆局部擦除：同一筆，控制點、形狀都不動，用遮罩挖掉碰到的點的圓（整個寬度，彎的外側也挖乾淨），
    /// 但不挖到旁邊留下的點的圓（留下的部分完整，和擦掉的那段在兩點中間切齊）。
    /// 遮罩每次只減掉這次碰到的地方，不重算整筆。全部擦掉了回傳 nil
    static func maskedOut(_ s: PKStroke, samples: [PKStrokePoint], hit: [Bool]) -> PKStroke? {
        guard let first = s.path.first else { return nil }
        // 線寬外面再多 1pt：邊緣反鋸齒的那一圈也要挖掉
        let edge: CGFloat = 1
        let widest = s.path.reduce(CGFloat(0)) { max($0, drawnHalfWidth(s.ink, $1.size)) } + edge
        var mask: CGPath
        if let m = s.mask {
            mask = m.cgPath
        } else {
            // 原本沒有遮罩：整筆都露出來（控制點的外框加上線寬，曲線不會超出控制點的範圍）
            let box = s.path.reduce(CGRect(origin: first.location, size: .zero)) { $0.union(CGRect(origin: $1.location, size: .zero)) }
            mask = CGPath(rect: box.insetBy(dx: -widest - 2, dy: -widest - 2), transform: nil)
        }
        let n = samples.count
        let loc = samples.map(\.location)
        // 這次擦完還留著的點
        let kept = (0..<n).map { !hit[$0] && mask.contains(loc[$0]) }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        /// 從 b 沿著 a → b 的方向再往前 d
        func beyond(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
            let l = dist(a, b)
            guard l > 0 else { return b }
            return CGPoint(x: b.x + (b.x - a.x) / l * d, y: b.y + (b.y - a.y) / l * d)
        }
        /// 沿著這些點、半徑 r 的帶子（只有一個點就是一個圓）
        func band(_ pts: [CGPoint], _ r: CGFloat, cap: CGLineCap) -> CGPath {
            guard pts.count > 1, zip(pts, pts.dropFirst()).contains(where: { dist($0, $1) > 0.01 }) else {
                return CGPath(ellipseIn: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r), transform: nil)
            }
            let p = CGMutablePath()
            p.addLines(between: pts)
            return p.copy(strokingWithWidth: 2 * r, lineCap: cap, lineJoin: .round, miterLimit: 1)
        }
        func radius(_ idx: [Int]) -> CGFloat { idx.reduce(CGFloat(0)) { max($0, drawnHalfWidth(s.ink, samples[$1].size)) } + edge }
        var j = 0
        while j < n {
            guard hit[j] else { j += 1; continue }
            var e = j
            while e + 1 < n, hit[e + 1] { e += 1 }
            let run = Array(j...e)
            var cut = band(run.map { loc[$0] }, radius(run), cap: .round)
            // 旁邊留下的點（圓可能和碰到的圓重疊）：一段一段連續的
            let reach = 2 * widest + 1
            let area = cut.boundingBoxOfPath.insetBy(dx: -widest - 1, dy: -widest - 1)
            let near = (0..<n).filter { i in
                kept[i] && area.contains(loc[i]) && run.contains { dist(loc[$0], loc[i]) <= reach }
            }
            var groups: [[Int]] = []
            for i in near {
                if let l = groups.last?.last, l == i - 1 { groups[groups.count - 1].append(i) } else { groups.append([i]) }
            }
            var keep: CGPath?
            for g in groups {
                let r = radius(g)
                var pts = g.map { loc[$0] }
                let part: CGPath
                if g.first == e + 1 {
                    // 接在擦掉的那段後面：從兩點中間切齊，另一頭延伸蓋住最後一個點的圓
                    pts.insert(mid(loc[e], loc[e + 1]), at: 0)
                    pts.append(beyond(pts[pts.count - 2], pts[pts.count - 1], r))
                    part = band(pts, r, cap: .butt)
                } else if g.last == j - 1 {
                    pts.append(mid(loc[j - 1], loc[j]))
                    pts.insert(beyond(pts[1], pts[0], r), at: 0)
                    part = band(pts, r, cap: .butt)
                } else {
                    // 同一筆繞回來經過這裡的另一段
                    part = band(pts, r, cap: .round)
                }
                keep = keep.map { $0.union(part) } ?? part
            }
            if let keep { cut = cut.subtracting(keep) }
            mask = mask.subtracting(cut)
            j = e + 1
        }
        guard kept.contains(true) else { return nil }
        return PKStroke(ink: s.ink, path: s.path, transform: s.transform, mask: UIBezierPath(cgPath: mask), randomSeed: s.randomSeed)
    }

    /// 除錯紀錄用：一筆 PencilKit 筆跡的外框、遮罩、點的透明度
    static func summary(_ s: PKStroke) -> String {
        let ops = s.path.map(\.opacity)
        let r = s.renderBounds, mb = s.mask?.bounds
        return String(format: "%@ n=%ld render=(%.0f,%.0f %.0fx%.0f) t=(%.0f,%.0f) op=%.3f…%.3f", s.ink.inkType.rawValue, s.path.count,
                      r.minX, r.minY, r.width, r.height, s.transform.tx, s.transform.ty, ops.min() ?? 0, ops.max() ?? 0)
            + (mb.map { String(format: " mask=(%.0f,%.0f %.0fx%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? " mask=nil")
    }

    /// PencilKit 實際畫出來的半個線寬（和點的 size 不一樣，見 PencilKitInkWidth）。斜的筆頭都用長的那邊（比較好擦）
    static func drawnHalfWidth(_ ink: PKInk, _ size: CGSize) -> CGFloat {
        PencilKitInkWidth.drawn(ink.inkType, size: size.width) / 2
    }

    /// 點到橡皮擦走過的折線的距離
    static func distance(_ p: CGPoint, to path: [CGPoint]) -> CGFloat {
        guard let first = path.first else { return .infinity }
        if path.count == 1 { return p.distance(to: first) }
        return zip(path, path.dropFirst()).map { InkGeometry.distance(p, $0, $1) }.min() ?? .infinity
    }
}

extension NotebookViewController {
    /// 橡皮擦的手勢：和自製筆刷一樣接住 Pencil（開了「用手指書寫」也接手指），PencilKit 的書寫和頁面捲動就不會開始
    func setupEraser() {
        eraserCapture.coordinateView = pagesContainer
        eraserCapture.delegate = self
        eraserCapture.onBegin = { [weak self] s in self?.eraserBegan(at: s.point) }
        eraserCapture.onMove = { [weak self] samples in self?.eraserMoved(samples.map(\.point)) }
        eraserCapture.onEnd = { [weak self] _ in self?.eraserEnded() }
        canvas.addGestureRecognizer(eraserCapture)
    }

    func eraserBegan(at p: CGPoint) {
        inkEraseUndoRegistered = []
        eraseStep = nil
        lastEraserPoint = p
        erase(along: [p])
    }

    /// 擦過這幾個點：從上一個點連過來，中間經過的都算
    func eraserMoved(_ points: [CGPoint]) {
        guard let last = lastEraserPoint, let end = points.last else { return }
        erase(along: [last] + points)
        lastEraserPoint = end
    }

    func eraserEnded() {
        lastEraserPoint = nil
        eraseStep = nil
        overlay.showEraser(at: nil, radius: 0)
        updateUITestDump()
        if tool == .eraser && settings.eraserAutoReturn {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tool == .eraser else { return }
                self.setTool(self.toolBeforeEraser)
            }
        }
    }

    /// 擦掉 path 碰到的螢光標示、自製筆刷的筆跡、PencilKit 的筆跡。同一次擦除（筆碰到螢幕到離開）是同一步
    func erase(along path: [CGPoint]) {
        guard tool == .eraser, let last = path.last else { return }
        let radius = eraserRadius
        if settings.pixelEraser { overlay.showEraser(at: last, radius: radius) }
        let before = history.recordCount
        history.merging(into: eraseStep) {
            for p in path {
                eraseHighlights(at: p)
                eraseInk(at: p)
            }
            if var strokes = StrokeEraser.erase(canvas.drawing.strokes, along: path, radius: radius, partial: settings.pixelEraser) {
                // 整筆擦除碰到虛線的其中一段：同一條的其他段也拿掉
                if !settings.pixelEraser { strokes = DashedStroke.removingErasedDashes(from: strokes, before: canvas.drawing.strokes) }
                history.record(.init(drawing: canvas.drawing, pages: [:]))
                var d = canvas.drawing
                d.strokes = strokes
                setDrawing(d)
            }
        }
        if eraseStep == nil, history.recordCount > before { eraseStep = history.topStepID }
    }
}
