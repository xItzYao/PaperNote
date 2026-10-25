import UIKit

// 自製筆刷（實驗）：照 Pencil 的原始取樣點畫，不像 PencilKit 那樣重新算成圓滑的曲線。
// 設定裡打開「實驗：自製筆刷」後，「筆」工具改用這裡；螢光筆、橡皮擦的 PencilKit 筆跡照舊。

// MARK: - 畫筆跡

enum InkRenderer {
    /// 在 ctx 裡畫筆跡（座標同筆跡的座標）；hidden 的筆跡不畫（套索移動中）
    static func draw(_ strokes: [InkStroke], in ctx: CGContext, hidden: Set<UUID> = [], clip: CGRect? = nil) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for s in strokes where !hidden.contains(s.id) {
            if let clip, !InkGeometry.bounds(of: s).intersects(clip) { continue }
            draw(s, in: ctx)
        }
        ctx.restoreGState()
    }

    static func draw(_ s: InkStroke, in ctx: CGContext) {
        let color = UIColor(hex: s.colorHex).cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        guard let first = s.points.first else { return }
        if s.points.count == 1 {
            let r = first.width / 2
            ctx.fillEllipse(in: CGRect(x: first.point.x - r, y: first.point.y - r, width: r * 2, height: r * 2))
            return
        }
        // 粗細都一樣：一條路徑畫完；粗細會變：一段一段畫
        if s.points.allSatisfy({ $0.w == first.w }) {
            ctx.setLineWidth(first.width)
            ctx.move(to: first.point)
            for p in s.points.dropFirst() { ctx.addLine(to: p.point) }
            ctx.strokePath()
            return
        }
        for (a, b) in zip(s.points, s.points.dropFirst()) {
            ctx.setLineWidth((a.width + b.width) / 2)
            ctx.move(to: a.point)
            ctx.addLine(to: b.point)
            ctx.strokePath()
        }
    }
}

// MARK: - 幾何（不碰畫面，可以單獨測試）

enum InkGeometry {
    static func bounds(of s: InkStroke) -> CGRect {
        guard let first = s.points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y, maxW = first.w
        for p in s.points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
            maxW = max(maxW, p.w)
        }
        let pad = CGFloat(maxW) / 2 + 1
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
            .insetBy(dx: -pad, dy: -pad)
    }

    static func offset(_ s: InkStroke, by d: CGPoint) -> InkStroke {
        var out = s
        out.points = s.points.map { InkPoint(CGPoint(x: $0.point.x + d.x, y: $0.point.y + d.y), width: $0.width) }
        return out
    }

    /// 兩組筆跡之間有變化的範圍；比較不出來（例如順序改變）回傳 nil
    static func changedBounds(_ old: [InkStroke], _ new: [InkStroke]) -> CGRect? {
        var before: [UUID: InkStroke] = [:]
        for s in old { before[s.id] = s }
        var r = CGRect.null
        var seen = Set<UUID>()
        for s in new {
            seen.insert(s.id)
            if let o = before[s.id] {
                if o != s { r = r.union(bounds(of: o)).union(bounds(of: s)) }
            } else {
                r = r.union(bounds(of: s))
            }
        }
        for s in old where !seen.contains(s.id) { r = r.union(bounds(of: s)) }
        return r.isNull ? nil : r
    }

    /// 點到線段的距離
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 橡皮擦碰到這一筆（半徑 radius 加上線寬一半）
    static func hits(_ s: InkStroke, at p: CGPoint, radius: CGFloat) -> Bool {
        guard bounds(of: s).insetBy(dx: -radius, dy: -radius).contains(p) else { return false }
        if s.points.count == 1 { return hypot(p.x - s.points[0].point.x, p.y - s.points[0].point.y) <= radius + s.points[0].width / 2 }
        for (a, b) in zip(s.points, s.points.dropFirst()) where distance(p, a.point, b.point) <= radius + max(a.width, b.width) / 2 {
            return true
        }
        return false
    }

    /// 橡皮擦擦過 p：整筆擦除時拿掉碰到的筆跡；局部擦除時剛好沿著圓圈的邊把線切斷，圓圈外的部分留著。沒有變化回傳 nil
    static func erase(_ strokes: [InkStroke], at p: CGPoint, radius: CGFloat, partial: Bool) -> [InkStroke]? {
        var changed = false
        var out: [InkStroke] = []
        for s in strokes {
            if partial, let pieces = cut(s, at: p, radius: radius) {
                changed = true
                out += pieces
            } else if !partial, hits(s, at: p, radius: radius) {
                changed = true
            } else {
                out.append(s)
            }
        }
        return changed ? out : nil
    }

    /// 把線在圓圈（圓心 p、半徑 r）裡面的部分切掉；圓圈沒碰到線回傳 nil
    static func cut(_ s: InkStroke, at p: CGPoint, radius r: CGFloat) -> [InkStroke]? {
        guard let first = s.points.first,
              bounds(of: s).insetBy(dx: -r, dy: -r).contains(p) else { return nil }
        func inside(_ q: InkPoint) -> Bool { hypot(q.point.x - p.x, q.point.y - p.y) < r }
        if s.points.count == 1 { return inside(first) ? [] : nil }
        guard zip(s.points, s.points.dropFirst()).contains(where: { distance(p, $0.point, $1.point) < r }) else { return nil }

        var pieces: [InkStroke] = []
        var run: [InkPoint] = inside(first) ? [] : [first]
        func flush() {
            if run.count >= 2 { pieces.append(InkStroke(colorHex: s.colorHex, points: run)) }
            run = []
        }
        for (a, b) in zip(s.points, s.points.dropFirst()) {
            // 線段和圓的交點：|a + t(b - a) - p| = r
            let dx = b.point.x - a.point.x, dy = b.point.y - a.point.y
            let fx = a.point.x - p.x, fy = a.point.y - p.y
            let qa = dx * dx + dy * dy, qb = 2 * (fx * dx + fy * dy), qc = fx * fx + fy * fy - r * r
            let disc = qb * qb - 4 * qa * qc
            var ts: [CGFloat] = []
            if qa > 0, disc > 0 {
                let sq = disc.squareRoot()
                ts = [(-qb - sq) / (2 * qa), (-qb + sq) / (2 * qa)].filter { $0 > 0 && $0 < 1 }
            }
            for t in ts {
                let q = InkPoint(CGPoint(x: a.point.x + dx * t, y: a.point.y + dy * t), width: a.width + (b.width - a.width) * t)
                if run.isEmpty {
                    run = [q]        // 從圓圈裡出來
                } else {
                    run.append(q)    // 走進圓圈
                    flush()
                }
            }
            if !inside(b) {
                if run.isEmpty { run = [b] } else { run.append(b) }
            }
        }
        flush()
        return pieces
    }

    /// 套索：筆跡有任何一點在範圍內就算圈到
    static func circled(_ s: InkStroke, offset o: CGPoint, path: UIBezierPath) -> Bool {
        s.points.contains { path.contains(CGPoint(x: $0.point.x + o.x, y: $0.point.y + o.y)) }
    }
}

// MARK: - 接收 Pencil 的取樣點

/// 「筆」工具改用自製筆刷時的手勢：每個真實取樣點（含系統合併的點）都交出來。
/// 不用系統的預測點：預測猜錯時筆尖會先衝出去再縮回來，寫起來像果凍；
/// Pencil 先給估計值、稍後補上準確的位置與筆壓，也一併交出來更新
final class InkCaptureRecognizer: UIGestureRecognizer {
    struct Sample {
        var point: CGPoint
        /// 0...1 的筆壓（手指沒有筆壓，當成 0.5）
        var force: CGFloat
        /// 之後還會補上準確值的話，用這個編號對應（見 onUpdate）
        var updateIndex: NSNumber? = nil
    }

    var allowFinger = false
    weak var coordinateView: UIView?
    var onBegin: ((Sample) -> Void)?
    var onMove: (([Sample]) -> Void)?
    /// 之前估計的取樣點補上了準確的位置／筆壓
    var onUpdate: ((Sample) -> Void)?
    var onEnd: ((_ cancelled: Bool) -> Void)?
    private var tracked: UITouch?
    private var lastForce: CGFloat = 0.5

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    private func sample(_ t: UITouch) -> Sample {
        let f: CGFloat = t.type == .pencil && t.maximumPossibleForce > 0 ? min(t.force / t.maximumPossibleForce, 1) : 0.5
        let pending = !t.estimatedPropertiesExpectingUpdates.intersection([.location, .force]).isEmpty
        return Sample(point: t.preciseLocation(in: coordinateView), force: f,
                      updateIndex: pending ? t.estimationUpdateIndex : nil)
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard tracked != nil else { return }
        for t in touches { onUpdate?(sample(t)) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches where t !== tracked {
            guard tracked == nil, t.type == .pencil || (allowFinger && t.type == .direct) else {
                ignore(t, for: event)
                continue
            }
            tracked = t
            lastForce = 0.5
            state = .began
            onBegin?(sample(t))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        let samples = (event.coalescedTouches(for: t) ?? [t]).map(sample)
        if let f = samples.last?.force { lastForce = f }
        onMove?(samples)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        // 放開那一刻的位置也要算進去；筆壓用放開前的（離開螢幕時筆壓是 0，線尾會突然變細）
        onMove?((event.coalescedTouches(for: t) ?? [t]).map { var s = sample($0); s.force = lastForce; return s })
        tracked = nil
        onEnd?(false)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        tracked = nil
        onEnd?(true)
        state = .cancelled
    }

    override func reset() {
        super.reset()
        if tracked != nil { onEnd?(true) }
        tracked = nil
    }
}

// MARK: - 寫的時候的筆跡（螢幕座標、原生解析度）

/// 寫的時候直接畫在螢幕上。放開後留到頁面那層（CATiledLayer，在背景畫）真的畫好這一筆才拿掉：
/// 太早拿掉會閃一下，太晚拿掉兩層疊在一起，細線看起來會變粗
final class LiveInkView: UIView {
    typealias Run = (points: [(CGPoint, CGFloat)], color: UIColor)
    /// 螢幕座標的點與線寬
    private(set) var points: [(CGPoint, CGFloat)] = []
    private var color: UIColor = .black
    /// 已經存進頁面、等頁面畫好的筆跡
    private var finished: [UUID: Run] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rect<S: Sequence>(_ pts: S) -> CGRect where S.Element == (CGPoint, CGFloat) {
        var r = CGRect.null
        for (p, w) in pts { r = r.union(CGRect(x: p.x - w, y: p.y - w, width: w * 2, height: w * 2)) }
        return r.isNull ? r : r.insetBy(dx: -2, dy: -2)
    }

    func begin(_ p: CGPoint, width: CGFloat, color: UIColor) {
        self.color = color
        points = [(p, width)]
        setNeedsDisplay(rect(points))
    }

    func add(_ new: [(CGPoint, CGFloat)]) {
        guard !new.isEmpty else { return }
        let from = max(0, points.count - 1)
        points += new
        let dirty = rect(points[from...])
        if !dirty.isNull { setNeedsDisplay(dirty) }
    }

    /// 第 i 點補上了準確的位置／線寬
    func replace(_ i: Int, with p: (CGPoint, CGFloat)) {
        guard points.indices.contains(i) else { return }
        let around = points[max(0, i - 1)...min(points.count - 1, i + 1)]
        let old = rect(around)
        points[i] = p
        setNeedsDisplay(old.union(rect(points[max(0, i - 1)...min(points.count - 1, i + 1)])))
    }

    /// 這一筆已經存進頁面：留在畫面上，等頁面畫好後用 remove 拿掉（頁面一直沒畫到，例如畫到頁面外，1 秒後拿掉）
    func finish(id: UUID) {
        if !points.isEmpty { finished[id] = (points, color) }
        points = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.remove([id]) }
    }

    func remove(_ ids: [UUID]) {
        let dirty = ids.compactMap { finished.removeValue(forKey: $0) }.reduce(CGRect.null) { $0.union(rect($1.points)) }
        if !dirty.isNull { setNeedsDisplay(dirty) }
    }

    /// 拿掉已經存進頁面的筆跡（捲動、縮放時馬上拿掉，否則會和頁面錯開）
    func clearFinished() {
        remove(Array(finished.keys))
    }

    func clear() {
        points = []
        finished = [:]
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for run in finished.values { draw(run.points, run.color, in: ctx, rect: rect) }
        if !points.isEmpty { draw(points, color, in: ctx, rect: rect) }
    }

    private func draw(_ all: [(CGPoint, CGFloat)], _ color: UIColor, in ctx: CGContext, rect: CGRect) {
        guard let first = all.first else { return }
        color.setStroke()
        color.setFill()
        if all.count == 1 {
            ctx.fillEllipse(in: CGRect(x: first.0.x - first.1 / 2, y: first.0.y - first.1 / 2, width: first.1, height: first.1))
            return
        }
        // 粗細都一樣：畫成一條路徑（和頁面那層一樣）。一段一段畫的話，細線的反鋸齒邊緣會互相疊加，看起來變粗
        if all.allSatisfy({ $0.1 == first.1 }) {
            ctx.setLineWidth(first.1)
            ctx.move(to: first.0)
            for (p, _) in all.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
            return
        }
        for (a, b) in zip(all, all.dropFirst()) {
            let w = (a.1 + b.1) / 2
            let seg = CGRect(x: min(a.0.x, b.0.x) - w, y: min(a.0.y, b.0.y) - w,
                             width: abs(a.0.x - b.0.x) + w * 2, height: abs(a.0.y - b.0.y) + w * 2)
            guard seg.intersects(rect) else { continue }
            ctx.setLineWidth(w)
            ctx.move(to: a.0)
            ctx.addLine(to: b.0)
            ctx.strokePath()
        }
    }
}

// MARK: - 頁面上的筆跡（CATiledLayer：放大也清晰）

/// 畫好的區塊直接出現，不淡入（淡入的那一下筆跡會變淡）
final class InkTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

final class PageInkView: UIView {
    override class var layerClass: AnyClass { InkTiledLayer.self }

    private let lock = NSLock()
    private var _strokes: [InkStroke] = []
    private var _offset: CGPoint = .zero
    private var _hidden: Set<UUID> = []
    /// 等著被畫出來的筆跡：還沒畫到的點（這個 view 的座標）、全部畫好後要做的事
    private var _awaiting: [UUID: (points: [CGPoint], done: () -> Void)] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        let tiled = layer as! CATiledLayer
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.levelsOfDetail = 6
        tiled.levelsOfDetailBias = 3
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// offset：頁面內容原點在這個 view 裡的位置（擴展頁面的留白）
    func set(strokes: [InkStroke], offset: CGPoint) {
        lock.lock()
        let old = _strokes, oldOffset = _offset
        _strokes = strokes
        _offset = offset
        lock.unlock()
        guard strokes != old || offset != oldOffset else { return }
        // 只重畫有變的筆跡範圍（寫一筆不用整頁重畫）
        guard offset == oldOffset, let dirty = InkGeometry.changedBounds(old, strokes) else {
            setNeedsDisplay()
            return
        }
        setNeedsDisplay(dirty.offsetBy(dx: offset.x, dy: offset.y))
    }

    /// 這一筆（頁面內容座標）所在的區塊都畫好後呼叫 done（在主執行緒）
    func whenDrawn(_ stroke: InkStroke, _ done: @escaping () -> Void) {
        lock.lock()
        let o = _offset
        _awaiting[stroke.id] = (stroke.points.map { CGPoint(x: $0.point.x + o.x, y: $0.point.y + o.y) }, done)
        lock.unlock()
    }

    /// 套索移動中先藏起來的筆跡
    func setHidden(_ ids: Set<UUID>) {
        lock.lock()
        let changed = ids != _hidden
        _hidden = ids
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        lock.lock()
        let strokes = _strokes, o = _offset, hidden = _hidden
        lock.unlock()
        if !strokes.isEmpty {
            ctx.saveGState()
            ctx.translateBy(x: o.x, y: o.y)
            InkRenderer.draw(strokes, in: ctx, hidden: hidden, clip: rect.offsetBy(dx: -o.x, dy: -o.y))
            ctx.restoreGState()
        }
        // 這一塊畫好了：等著的筆跡在這一塊的點都算畫出來了
        lock.lock()
        var done: [() -> Void] = []
        for (id, item) in _awaiting {
            let left = item.points.filter { !rect.contains($0) }
            if left.isEmpty {
                done.append(item.done)
                _awaiting[id] = nil
            } else if left.count != item.points.count {
                _awaiting[id] = (left, item.done)
            }
        }
        lock.unlock()
        if !done.isEmpty { DispatchQueue.main.async { done.forEach { $0() } } }
    }
}

// MARK: - 編輯器：寫、存、擦

/// 寫到一半的一筆（文件座標）
struct InkDraft {
    var points: [InkPoint]
    var colorHex: String
    var baseWidth: CGFloat
    var pressure: Bool
    /// 還會補上準確值的取樣點：編號 → points 的索引
    var pendingUpdates: [NSNumber: Int] = [:]
}

extension NotebookViewController {
    /// 「筆」工具目前用自製筆刷
    var customInkActive: Bool { tool == .pen && settings.customInk }

    func setupInkCapture() {
        inkRecognizer.coordinateView = pagesContainer
        inkRecognizer.delegate = self
        inkRecognizer.onBegin = { [weak self] s in self?.inkBegan(s) }
        inkRecognizer.onMove = { [weak self] new in self?.inkMoved(new) }
        inkRecognizer.onUpdate = { [weak self] s in self?.inkUpdated(s) }
        inkRecognizer.onEnd = { [weak self] cancelled in self?.inkEnded(cancelled: cancelled) }
        canvas.addGestureRecognizer(inkRecognizer)
        liveInkView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(liveInkView, aboveSubview: canvas)
        NSLayoutConstraint.activate([
            liveInkView.topAnchor.constraint(equalTo: canvas.topAnchor),
            liveInkView.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
            liveInkView.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            liveInkView.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
        ])
    }

    /// 筆壓對應的線寬：只有毛筆／沾水筆隨筆壓變化，其他筆型照設定的粗細畫（線尾不會變細）
    private func inkWidth(_ draft: InkDraft, force: CGFloat) -> CGFloat {
        draft.pressure ? draft.baseWidth * (0.7 + 0.6 * force) : draft.baseWidth
    }

    private func screen(_ p: CGPoint) -> CGPoint { pagesContainer.convert(p, to: liveInkView) }

    func inkBegan(_ s: InkCaptureRecognizer.Sample) {
        dismissToolPopover()
        if let p = paletteOverlay, p.mode == .launcher { dismissPalette() }
        let preset = BrushStore.shared.current
        var d = InkDraft(points: [], colorHex: preset.colorHex, baseWidth: max(preset.width, 0.1),
                         pressure: preset.style == .fountainPen)
        let w = inkWidth(d, force: s.force)
        d.points = [InkPoint(s.point, width: w)]
        if let u = s.updateIndex { d.pendingUpdates[u] = 0 }
        inkDraft = d
        liveInkView.begin(screen(s.point), width: w * canvas.zoomScale, color: preset.color)
        DebugLog.add("custom ink begin drawGR=\(canvas.drawingGestureRecognizer.isEnabled)")
    }

    func inkMoved(_ new: [InkCaptureRecognizer.Sample]) {
        guard var d = inkDraft else { return }
        let z = canvas.zoomScale
        var added: [(CGPoint, CGFloat)] = []
        for s in new {
            // 跟上一點完全重疊的不記（不是圓滑，只是去掉重複點）
            if let last = d.points.last, s.updateIndex == nil, hypot(last.point.x - s.point.x, last.point.y - s.point.y) < 0.05 { continue }
            let w = inkWidth(d, force: s.force)
            if let u = s.updateIndex { d.pendingUpdates[u] = d.points.count }
            d.points.append(InkPoint(s.point, width: w))
            added.append((screen(s.point), w * z))
        }
        inkDraft = d
        liveInkView.add(added)
    }

    /// Pencil 補上了準確的位置／筆壓：換掉之前的估計值
    func inkUpdated(_ s: InkCaptureRecognizer.Sample) {
        guard var d = inkDraft, let u = s.updateIndex, let i = d.pendingUpdates[u], d.points.indices.contains(i) else { return }
        let w = inkWidth(d, force: s.force)
        d.points[i] = InkPoint(s.point, width: w)
        inkDraft = d
        liveInkView.replace(i, with: (screen(s.point), w * canvas.zoomScale))
    }

    func inkEnded(cancelled: Bool) {
        guard let d = inkDraft else { return }
        inkDraft = nil
        guard let first = d.points.first else { liveInkView.clear(); return }
        // 整筆放在起點所在的那一頁（頁面內容座標）
        let pi = pageIndex(containing: first.point) ?? nearestPageIndex(to: first.point)
        guard pages.indices.contains(pi) else { liveInkView.clear(); return }
        let o = contentOrigin(pi)
        let stroke = InkGeometry.offset(InkStroke(colorHex: d.colorHex, points: d.points), by: CGPoint(x: -o.x, y: -o.y))
        // 寫的時候的筆跡留到頁面那層畫好這一筆才拿掉
        liveInkView.finish(id: stroke.id)
        pageViews[pages[pi].id]?.inkView.whenDrawn(stroke) { [weak self] in self?.liveInkView.remove([stroke.id]) }
        updatePage(pi) { $0.ink.append(stroke) }
        DebugLog.add("custom ink end points=\(d.points.count) cancelled=\(cancelled) pkStrokes=\(canvas.drawing.strokes.count)")
    }

    /// 橡皮擦擦自製筆刷的筆跡；同一次擦除只登記一次上一步
    func eraseInk(at p: CGPoint) {
        guard tool == .eraser, let i = pageIndex(containing: p), !pages[i].ink.isEmpty else { return }
        let o = contentOrigin(i)
        let local = CGPoint(x: p.x - o.x, y: p.y - o.y)
        guard let result = InkGeometry.erase(pages[i].ink, at: local, radius: eraserRadius, partial: settings.pixelEraser) else { return }
        let undoable = !inkEraseUndoRegistered.contains(pages[i].id)
        inkEraseUndoRegistered.insert(pages[i].id)
        updatePage(i, undoable: undoable) { $0.ink = result }
    }
}
