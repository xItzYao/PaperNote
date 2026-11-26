import UIKit
import PencilKit

/// 橡皮擦擦 PencilKit 的筆跡（App 自己擦，不用 PencilKit 的橡皮擦）：一邊擦一邊消失。
/// 筆跡是沿著中心軌跡的一個一個圓（圓心在軌跡上、半徑是畫出來的線寬一半）。
/// 橡皮擦碰到哪個圓的任何一點，就把那個圓心拿掉，整個圓跟著不見：螢光筆比橡皮擦粗，擦一條線過去，那裡整個寬度都擦掉
enum StrokeEraser {
    /// 畫出來最粗的半個線寬（快速排除用，比任何筆都粗）
    private static let maxReach: CGFloat = 60
    /// 線寬外面再多 1pt：邊緣反鋸齒的那一圈也要挖掉
    private static let edge: CGFloat = 1
    /// 每幾個取樣點一塊（2pt 一個點：一塊 64pt）
    static let chunkSize = 32

    /// 擦的時候做了多少事（測試用來比較橡皮擦每走一段路要算多少次）
    struct Counts {
        /// 看了幾個取樣點離橡皮擦多遠
        var samples = 0
        /// 問了遮罩幾次「這一點在裡面嗎」
        var inside = 0
        /// 畫了幾次帶子的外形（把中心線變成一個形狀）
        var outlines = 0
        /// 遮罩做了幾次布林運算（相減、聯集）
        var booleans = 0
        /// 有幾個點不知道擦掉了沒、要回頭問遮罩（重新打開、復原之後第一次擦到那裡）
        var derived = 0
        /// 花在算擦哪裡的時間（不含 PencilKit 重畫）
        var seconds: Double = 0
        /// 其中：讀筆跡的遮罩、比對紀錄、把每一塊拼起來、建新的 PKStroke、讀回 PencilKit 存的遮罩
        var readMask: Double = 0, compare: Double = 0, assemble: Double = 0, makeStroke: Double = 0, readBack: Double = 0
        /// 新遮罩的元素（線段、曲線）總數
        var elements = 0
        /// 第一次碰到一筆時沿著它取樣的時間
        var sampling: Double = 0
    }

    /// 量一段花多久，加到 counts 的某一欄
    @inline(__always)
    private static func timed<T>(_ field: WritableKeyPath<Counts, Double>, _ body: () -> T) -> T {
        let t = CACurrentMediaTime()
        defer { counts[keyPath: field] += CACurrentMediaTime() - t }
        return body()
    }
    static var counts = Counts()

    private static func inside(_ path: CGPath, _ p: CGPoint) -> Bool {
        counts.inside += 1
        return path.contains(p)
    }

    /// 一筆筆跡每 2pt 取的點（記下在筆跡上的參數位置，切開時才找得到原本的控制點），和每 32 個點一塊的外框。
    /// 擦的時候每移動一下都要用：同一條筆跡只算一次，之後只看橡皮擦附近那幾塊
    final class Samples {
        let params: [CGFloat]
        let points: [PKStrokePoint]
        let locations: [CGPoint]
        /// 每個點畫出來的半個線寬（筆跡座標）
        let half: [CGFloat]
        let widest: CGFloat
        /// 每一塊：點的範圍、外框（筆跡座標，含線寬）
        let chunks: [(range: Range<Int>, box: CGRect)]

        init(_ s: PKStroke) {
            let started = CACurrentMediaTime()
            defer { StrokeEraser.counts.sampling += CACurrentMediaTime() - started }
            let sp = s.path
            let end = CGFloat(max(sp.count - 1, 0))
            var params: [CGFloat] = [0]
            while let t = params.last, t < end {
                let next = min(sp.parametricValue(t, offsetBy: .distance(2)), end)
                guard next > t else { break }
                params.append(next)
            }
            if let t = params.last, t < end { params.append(end) }
            self.params = params
            points = params.map { sp.interpolatedPoint(at: $0) }
            locations = points.map(\.location)
            half = points.map { StrokeEraser.drawnHalfWidth(s.ink, $0.size) }
            widest = half.max() ?? 0
            var chunks: [(range: Range<Int>, box: CGRect)] = []
            var i = 0
            while i < locations.count {
                let r = i..<min(i + StrokeEraser.chunkSize, locations.count)
                var box = CGRect.null
                for j in r { box = box.union(CGRect(origin: locations[j], size: .zero).insetBy(dx: -half[j], dy: -half[j])) }
                chunks.append((r, box))
                i = r.upperBound
            }
            self.chunks = chunks
        }

        var count: Int { locations.count }
    }

    private struct SampleKey: Hashable {
        let created: Double, count: Int, seed: UInt32, ink: String
        let x0: Double, y0: Double, x1: Double, y1: Double, size: Double
    }

    private static var cache: [SampleKey: Samples] = [:]
    private static var aliveCache: [SampleKey: Alive] = [:]

    private static func key(_ s: PKStroke) -> SampleKey {
        let sp = s.path
        let f = sp.first, l = sp.last
        return SampleKey(created: sp.creationDate.timeIntervalSinceReferenceDate, count: sp.count, seed: s.randomSeed,
                         ink: s.ink.inkType.rawValue, x0: Double(f?.location.x ?? 0), y0: Double(f?.location.y ?? 0),
                         x1: Double(l?.location.x ?? 0), y1: Double(l?.location.y ?? 0), size: Double(f?.size.width ?? 0))
    }

    /// 同一條筆跡（控制點一樣）的取樣只算一次。螢光筆擦的時候只換遮罩，控制點不動
    static func samples(_ s: PKStroke) -> Samples { samples(key(s), s) }

    private static func samples(_ key: SampleKey, _ s: PKStroke) -> Samples {
        if let hit = cache[key] { return hit }
        if cache.count > 4000 {
            cache.removeAll()
            aliveCache.removeAll()
        }
        let made = Samples(s)
        cache[key] = made
        return made
    }

    /// 螢光筆每個取樣點擦掉了沒。擦的時候自己記著，下一下直接看，不用每個點都去問遮罩（遮罩越擦越複雜，問一次越久）。
    /// 遮罩和記著的對不上（重新打開、復原）才回頭問遮罩，而且只問橡皮擦附近用得到的點
    final class Alive {
        /// 這份紀錄對應的遮罩
        var mask: CGPath?
        /// -1 還不知道、0 擦掉了、1 還在
        var state: [Int8]
        /// 每個點擦掉了沒都知道（沒有遮罩，或遮罩只是筆跡超出頁面時加的方框）：遮罩直接用留下的點一塊一塊拼出來。
        /// 不知道的（重新打開、復原之後，遮罩是之前擦出來的）就從原本的遮罩挖
        let known: Bool
        /// 筆跡超出頁面時的方框：每一塊只留框裡的
        let clip: CGRect?
        /// 每一塊（Samples.chunks）留下的點畫成的形狀，nil 是還沒畫或要重畫
        var outlines: [CGPath?]
        private let sm: Samples
        /// 遮罩只是一個方框
        private let plainBox: Bool

        init(_ sm: Samples, mask: CGPath?) {
            self.sm = sm
            self.mask = mask
            var curves = false, elements = 0
            mask?.applyWithBlock { e in
                elements += 1
                if e.pointee.type == .addCurveToPoint || e.pointee.type == .addQuadCurveToPoint { curves = true }
            }
            plainBox = mask != nil && !curves && elements <= 6
            outlines = [CGPath?](repeating: nil, count: sm.chunks.count)
            if let mask, plainBox {
                let box = mask.boundingBoxOfPath
                clip = box
                state = sm.locations.map { box.contains($0) ? 1 : 0 }
                known = true
            } else {
                clip = nil
                state = [Int8](repeating: mask == nil ? 1 : -1, count: sm.count)
                known = mask == nil
            }
        }

        func isAlive(_ i: Int) -> Bool {
            if state[i] < 0 { state[i] = derive(i) ? 1 : 0 }
            return state[i] == 1
        }

        /// 問遮罩：圓心在遮罩裡、整個圓也都在（之前擦掉的點的圓心可能落在旁邊留下的點的圓頭裡，
        /// 那裡看得到，但不是它自己的：它的圓周圍有一圈是空的）
        private func derive(_ i: Int) -> Bool {
            guard let m = mask else { return true }
            StrokeEraser.counts.derived += 1
            let p = sm.locations[i]
            guard StrokeEraser.inside(m, p) else { return false }
            if plainBox { return true }
            let q = sm.half[i] + 0.5
            return (0..<8).allSatisfy { k in
                let a = CGFloat(k) * .pi / 4
                return StrokeEraser.inside(m, CGPoint(x: p.x + q * cos(a), y: p.y + q * sin(a)))
            }
        }
    }

    private static func alive(_ key: SampleKey, _ sm: Samples, mask: CGPath?) -> Alive {
        if let a = aliveCache[key], timed(\.compare, { a.mask == mask }) { return a }
        let made = Alive(sm, mask: mask)
        aliveCache[key] = made
        return made
    }

    /// 橡皮擦沿著 path（文件座標）走過、半徑 radius。整筆擦除：碰到就整筆拿掉；局部擦除：拿掉碰到的那些圓，其他留著。
    /// 沒有變化回傳 nil
    static func erase(_ strokes: [PKStroke], along path: [CGPoint], radius: CGFloat, partial: Bool) -> [PKStroke]? {
        guard let first = path.first else { return nil }
        let started = CACurrentMediaTime()
        defer { counts.seconds += CACurrentMediaTime() - started }
        let area = path.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            .insetBy(dx: -radius - 1, dy: -radius - 1)
        var changed = false
        var out: [PKStroke] = []
        out.reserveCapacity(strokes.count)
        for s in strokes {
            // 先用外框快速排除，碰得到的才細算
            guard s.path.count > 0, s.renderBounds.insetBy(dx: -maxReach, dy: -maxReach).intersects(area) else {
                out.append(s)
                continue
            }
            let k = abs(s.transform.a * s.transform.d - s.transform.b * s.transform.c).squareRoot()
            let sk = key(s)
            let sm = samples(sk, s)
            // 遮罩每次讀都是一份新的：讀一次就好
            let mask = timed(\.readMask) { s.mask?.cgPath }
            // 螢光筆局部擦除：哪些點擦掉了看自己的紀錄（見 Alive）；其他的看圓心在不在遮罩裡
            let highlighter = partial && NotebookViewController.isHighlighterStroke(s)
            let st = highlighter ? alive(sk, sm, mask: mask) : nil
            // 只看橡皮擦附近的那幾塊；先看距離（便宜），碰得到的再看那裡是不是已經擦掉了
            var hit = [Bool](repeating: false, count: sm.count)
            var any = false
            for c in sm.chunks where c.box.applying(s.transform).insetBy(dx: -radius, dy: -radius).intersects(area) {
                counts.samples += c.range.count
                for i in c.range {
                    let w = sm.locations[i].applying(s.transform)
                    if distance(w, to: path) <= radius + sm.half[i] * k,
                       st.map({ $0.isAlive(i) }) ?? mask.map({ inside($0, sm.locations[i]) }) ?? true {
                        hit[i] = true
                        any = true
                    }
                }
            }
            guard any else {
                out.append(s)
                continue
            }
            guard partial else {
                changed = true
                continue
            }
            // 半透明的螢光筆：還是同一筆，擦掉的部分用遮罩挖掉。切成好幾筆的話，自己交錯的地方變成兩筆疊在一起，顏色變深
            if let st {
                changed = true
                if let m = maskedOut(s, sm, st, mask: mask, hit: hit) { out.append(m) }
                continue
            }
            changed = true
            let sp = s.path, params = sm.params, pts = sm.points
            let end = CGFloat(sp.count - 1)
            let gone = (0..<sm.count).map { i in hit[i] || !(mask.map { inside($0, sm.locations[i]) } ?? true) }
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

    /// 筆跡上的這一點（筆跡的 path 座標）畫得出來：沒有遮罩，或在遮罩裡面（擦掉的點如果落在旁邊留下的點的圓頭裡，也看得到）。
    /// 擦掉的地方只記在遮罩（畫面、套索、橡皮擦都看它）：點的透明度是 Pencil 的筆壓資料（水彩 0.01 左右），不能拿來記擦掉了
    static func isShown(_ s: PKStroke, _ location: CGPoint) -> Bool {
        s.mask?.contains(location) ?? true
    }

    /// 螢光筆局部擦除：同一筆，控制點、形狀都不動，用遮罩挖掉碰到的點的圓（整個寬度，彎的外側也挖乾淨），
    /// 但不挖到旁邊留下的點的圓：留下的部分完整，擦掉的頭是留下的最後一個點的圓弧。
    /// 這一下碰到的地方（大面積的色塊來回好幾趟也一樣）合成一個形狀，遮罩只做兩次運算，不重算整筆。
    /// 碰到的點記成擦掉了（st）。全部擦掉了回傳 nil
    static func maskedOut(_ s: PKStroke, _ sm: Samples, _ st: Alive, mask old: CGPath?, hit: [Bool]) -> PKStroke? {
        let n = sm.count
        let loc = sm.locations
        let r = sm.widest + edge
        let mask: CGPath
        if let old {
            mask = old
        } else {
            // 原本沒有遮罩：整筆都露出來（取樣點的外框加上線寬）
            let box = sm.chunks.reduce(CGRect.null) { $0.union($1.box) }
            mask = CGPath(rect: box.insetBy(dx: -edge - 2, dy: -edge - 2), transform: nil)
        }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        /// 連續的一段一段（索引連在一起的）
        func runs(_ idx: [Int]) -> [[Int]] {
            var out: [[Int]] = []
            for i in idx {
                if let l = out.last?.last, l == i - 1 { out[out.count - 1].append(i) } else { out.append([i]) }
            }
            return out
        }
        /// 這幾段沿著中心線、半徑 r、兩頭圓的帶子（一次畫成一個形狀；只有一個點的是一個圓）
        func bands(_ rs: [[Int]]) -> CGPath {
            let lines = CGMutablePath()
            for run in rs {
                // 重複的點（停在原地畫的）去掉
                var pts: [CGPoint] = []
                for i in run where pts.last.map({ dist($0, loc[i]) > 0.01 }) ?? true { pts.append(loc[i]) }
                guard pts.count > 1 else {
                    lines.move(to: loc[run[0]])
                    lines.addLine(to: CGPoint(x: loc[run[0]].x + 0.01, y: loc[run[0]].y))
                    continue
                }
                // 轉角處切開（兩邊的圓頭補成圓角）；其他接縫用斜角：點之間只有 2pt，轉一點點的地方斜角和圓角差不到 0.01pt，
                // 外形的元素少很多（圓角每個接縫都是一段曲線）
                var piece = [pts[0]]
                for j in 1..<pts.count {
                    piece.append(pts[j])
                    if j + 1 < pts.count {
                        let a = CGVector(dx: pts[j].x - pts[j - 1].x, dy: pts[j].y - pts[j - 1].y)
                        let b = CGVector(dx: pts[j + 1].x - pts[j].x, dy: pts[j + 1].y - pts[j].y)
                        let cos = (a.dx * b.dx + a.dy * b.dy) / (hypot(a.dx, a.dy) * hypot(b.dx, b.dy))
                        if cos < 0.94 {  // 轉超過 20°
                            lines.addLines(between: simplified(piece))
                            piece = [pts[j]]
                        }
                    }
                }
                if piece.count > 1 { lines.addLines(between: simplified(piece)) }
            }
            counts.outlines += 1
            return lines.copy(strokingWithWidth: 2 * r, lineCap: .round, lineJoin: .bevel, miterLimit: 1)
        }
        let hitIdx = (0..<n).filter { hit[$0] }
        if st.known {
            // 知道每個點擦掉了沒：碰到的記成擦掉，只重畫碰到的那幾塊，遮罩是每一塊拼起來（不做布林運算，遮罩再複雜也一樣快）
            for i in hitIdx { st.state[i] = 0 }
            guard st.state.contains(1) else { return nil }
            for i in hitIdx {
                let c = i / chunkSize
                st.outlines[c] = nil
                // 每一塊的形狀多連到隔壁塊的第一個點（才接得起來）：碰到邊上的點，隔壁那塊也重畫
                if i % chunkSize == 0, c > 0 { st.outlines[c - 1] = nil }
                if i % chunkSize == chunkSize - 1, c + 1 < st.outlines.count { st.outlines[c + 1] = nil }
            }
            let whole = CGMutablePath()
            for (c, chunk) in sm.chunks.enumerated() where st.outlines[c] == nil {
                let kept = (max(0, chunk.range.lowerBound - 1)..<min(n, chunk.range.upperBound + 1)).filter { st.state[$0] == 1 }
                var o: CGPath = kept.isEmpty ? CGMutablePath() : bands(runs(kept))
                if let clip = st.clip, !kept.isEmpty, !clip.contains(chunk.box.insetBy(dx: -r, dy: -r)) {
                    o = o.intersection(CGPath(rect: clip, transform: nil))
                    counts.booleans += 1
                }
                st.outlines[c] = o
            }
            timed(\.assemble) { for o in st.outlines { if let o { whole.addPath(o) } } }
            whole.applyWithBlock { _ in counts.elements += 1 }
            let m = timed(\.makeStroke) {
                PKStroke(ink: s.ink, path: s.path, transform: s.transform, mask: UIBezierPath(cgPath: whole), randomSeed: s.randomSeed)
            }
            // 記下 PencilKit 存起來的遮罩（它會換成自己的寫法）：下一下讀到的是這個，才對得上
            st.mask = timed(\.readBack) { m.mask?.cgPath }
            return m
        }
        // 不知道每個點擦掉了沒（之前擦過、重新打開或復原）：從原本的遮罩挖掉碰到的圓，旁邊還在的圓不挖
        let hitLoc = hitIdx.map { loc[$0] }
        // 旁邊還在的點（圓可能和碰到的圓重疊）：它們的圓不挖
        let around = hitLoc.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -3 * r - 2, dy: -3 * r - 2)
        let reach = 2 * r + 1
        var near: [Int] = []
        for c in sm.chunks where c.box.intersects(around) {
            for i in c.range where !hit[i] && around.contains(loc[i]) && hitLoc.contains(where: { dist($0, loc[i]) <= reach }) && st.isAlive(i) {
                near.append(i)
            }
        }
        var cut = bands(runs(hitIdx))
        if !near.isEmpty {
            cut = cut.subtracting(bands(runs(near)))
            counts.booleans += 1
        }
        let after = mask.subtracting(cut)
        counts.booleans += 1
        for i in hitIdx { st.state[i] = 0 }
        // 還有留下的點嗎：旁邊還在的點一定在；沒有的話看紀錄，不知道的再問遮罩（跳著找，找到就停）
        st.mask = after
        let left = !near.isEmpty || st.state.contains(1)
            || Swift.stride(from: 0, to: n, by: 3).contains(where: { st.state[$0] < 0 && st.isAlive($0) })
        guard left else { return nil }
        let m = PKStroke(ink: s.ink, path: s.path, transform: s.transform, mask: UIBezierPath(cgPath: after), randomSeed: s.randomSeed)
        // 記下 PencilKit 存起來的遮罩（它會換成自己的寫法）：下一下讀到的是這個，才對得上
        st.mask = m.mask?.cgPath
        return m
    }

    /// 中心線簡化成差不到 0.25pt 的折線（遮罩比畫出來的寬 1pt，看不出差別）：直的、緩緩彎的地方不用每 2pt 一個點，
    /// PencilKit 收遮罩的時間跟元素數量成正比
    static func simplified(_ pts: [CGPoint], tolerance: CGFloat = 0.25) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let p = pts[a], q = pts[b]
            let dx = q.x - p.x, dy = q.y - p.y, len = hypot(dx, dy)
            var far = a + 1, farDist: CGFloat = -1
            for i in (a + 1)..<b {
                let d = len < 1e-6 ? hypot(pts[i].x - p.x, pts[i].y - p.y) : abs(dx * (p.y - pts[i].y) - dy * (p.x - pts[i].x)) / len
                if d > farDist { farDist = d; far = i }
            }
            if farDist > tolerance {
                keep[far] = true
                stack.append((a, far))
                stack.append((far, b))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
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

    /// 橡皮擦每走這麼多才真的擦一次（中間經過的點一起算，一個都不漏）：擦一次的時間大多花在交給 PencilKit 新的筆跡，
    /// 和這一下走多遠無關。iPad 每一格畫面送一次位置，慢慢擦的時候一下只走 1～2pt，每一下都擦的話，同樣的長度要多擦好幾倍
    static let eraseEvery: CGFloat = 6
    /// 走得很慢的時候，最久隔這麼久也擦一次（不然擦掉的地方跟不上筆）
    static let eraseAtLeastEvery: CFTimeInterval = 1.0 / 30

    func eraserBegan(at p: CGPoint) {
        inkEraseUndoRegistered = []
        eraseStep = nil
        eraseWorking = nil
        lastEraserPoint = p
        eraserPending = []
        erase(along: [p])
        eraserErasedAt = CACurrentMediaTime()
    }

    /// 擦過這幾個點：從上一次擦到的點連過來，中間經過的都算
    func eraserMoved(_ points: [CGPoint]) {
        guard let last = lastEraserPoint, let end = points.last else { return }
        eraserPending += points
        let route = [last] + eraserPending
        let travelled = zip(route, route.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        guard travelled >= Self.eraseEvery || CACurrentMediaTime() - eraserErasedAt >= Self.eraseAtLeastEvery else {
            if tool == .eraser, settings.pixelEraser { overlay.showEraser(at: end, radius: eraserRadius) }
            return
        }
        flushEraser()
    }

    /// 還沒擦的那一段擦掉
    private func flushEraser() {
        guard let last = lastEraserPoint, let end = eraserPending.last else { return }
        erase(along: [last] + eraserPending)
        lastEraserPoint = end
        eraserPending = []
        eraserErasedAt = CACurrentMediaTime()
    }

    func eraserEnded() {
        flushEraser()
        lastEraserPoint = nil
        eraseStep = nil
        eraseWorking = nil
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
        var t = CACurrentMediaTime()
        func lap(_ field: WritableKeyPath<EraseStepTiming, Double>) {
            let now = CACurrentMediaTime()
            Self.lastEraseStep[keyPath: field] += now - t
            t = now
        }
        history.merging(into: eraseStep) {
            for p in path {
                eraseHighlights(at: p)
                eraseInk(at: p)
            }
            lap(\.highlightsAndInk)
            let current = eraseWorking ?? canvas.drawing.strokes
            if var strokes = StrokeEraser.erase(current, along: path, radius: radius, partial: settings.pixelEraser) {
                lap(\.strokeEraser)
                // 整筆擦除碰到虛線的其中一段：同一條的其他段也拿掉
                if !settings.pixelEraser { strokes = DashedStroke.removingErasedDashes(from: strokes, before: current) }
                lap(\.dashes)
                history.record(.init(drawing: canvas.drawing, pages: [:]))
                lap(\.record)
                setStrokes(strokes)
                lap(\.set)
                eraseWorking = strokes
            } else {
                lap(\.strokeEraser)
            }
        }
        if eraseStep == nil, history.recordCount > before { eraseStep = history.topStepID }
    }

    /// 擦一次各部分花多久（測試用來找擦一次慢在哪）
    struct EraseStepTiming {
        var highlightsAndInk = 0.0, strokeEraser = 0.0, dashes = 0.0, record = 0.0, set = 0.0
        var summary: String {
            String(format: "highlightsAndInk=%.0f strokeEraser=%.0f dashes=%.0f record=%.0f set=%.0f",
                   highlightsAndInk * 1000, strokeEraser * 1000, dashes * 1000, record * 1000, set * 1000)
        }
    }
    static var lastEraseStep = EraseStepTiming()
}
