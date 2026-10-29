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

    /// 同顏色、同粗細、連續的筆合成一條路徑一起描（整頁畫成圖時快很多）。shouldStop 回傳 true 就停（頁面已經不要了）
    @discardableResult
    static func drawBatched(_ strokes: [InkStroke], in ctx: CGContext, clip: CGRect? = nil,
                            shouldStop: () -> Bool = { false }) -> Bool {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        var color: String?
        var width: CGFloat = -1
        var pending = false
        func flush() {
            if pending { ctx.strokePath() }
            pending = false
        }
        for (i, s) in strokes.enumerated() {
            if i % 64 == 0, shouldStop() { return false }
            if let clip, !InkGeometry.bounds(of: s).intersects(clip) { continue }
            guard let first = s.points.first else { continue }
            guard s.points.count > 1, s.points.allSatisfy({ $0.w == first.w }) else {
                flush()
                color = nil
                draw(s, in: ctx)
                continue
            }
            if s.colorHex != color || first.width != width {
                flush()
                color = s.colorHex
                width = first.width
                ctx.setStrokeColor(UIColor(hex: s.colorHex).cgColor)
                ctx.setLineWidth(width)
            }
            ctx.move(to: first.point)
            for p in s.points.dropFirst() { ctx.addLine(to: p.point) }
            pending = true
        }
        flush()
        return true
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

    /// 切成虛線：沿著線畫 dash 長、空 gap 長，重複到底。切點落在兩點中間就在那裡補一點（粗細照比例）
    static func dashed(_ s: InkStroke, dash: CGFloat, gap: CGFloat) -> [InkStroke] {
        guard s.points.count > 1, dash > 0, gap > 0 else { return [s] }
        var pieces: [InkStroke] = []
        var run: [InkPoint] = [s.points[0]]
        var drawing = true
        // 目前這一段（實線或空白）還剩多長
        var left = dash
        func emit() {
            if run.count > 1 { pieces.append(InkStroke(colorHex: s.colorHex, points: run)) }
            run = []
        }
        for (a, b) in zip(s.points, s.points.dropFirst()) {
            let len = hypot(b.point.x - a.point.x, b.point.y - a.point.y)
            // 這兩點之間已經走過的長度
            var done: CGFloat = 0
            while len - done >= left {
                done += left
                let f = done / len
                let q = InkPoint(CGPoint(x: a.point.x + (b.point.x - a.point.x) * f, y: a.point.y + (b.point.y - a.point.y) * f),
                                 width: a.width + (b.width - a.width) * f)
                if drawing {
                    run.append(q)
                    emit()
                } else {
                    run = [q]
                }
                drawing.toggle()
                left = drawing ? dash : gap
            }
            left -= len - done
            if drawing { run.append(b) }
        }
        if drawing { emit() }
        return pieces.isEmpty ? [s] : pieces
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

/// 寫的時候直接畫在螢幕上；放開後這一筆交給頁面那層（同一個畫面更新裡換過去，不會閃也不會疊兩層）
final class LiveInkView: UIView {
    /// 螢幕座標的點與線寬
    private(set) var points: [(CGPoint, CGFloat)] = []
    private var color: UIColor = .black

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

    func clear() {
        let dirty = rect(points)
        points = []
        if !dirty.isNull { setNeedsDisplay(dirty) }
    }

    /// 只畫在這個範圍裡（寫的那一頁在螢幕上的位置）
    var clip: CGRect?

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let first = points.first else { return }
        if let clip { ctx.clip(to: clip) }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        color.setStroke()
        color.setFill()
        if points.count == 1 {
            ctx.fillEllipse(in: CGRect(x: first.0.x - first.1 / 2, y: first.0.y - first.1 / 2, width: first.1, height: first.1))
            return
        }
        // 粗細都一樣：畫成一條路徑。一段一段畫的話，細線的反鋸齒邊緣會互相疊加，看起來變粗
        if points.allSatisfy({ $0.1 == first.1 }) {
            ctx.setLineWidth(first.1)
            ctx.move(to: first.0)
            for (p, _) in points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
            return
        }
        for (a, b) in zip(points, points.dropFirst()) {
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

// MARK: - 頁面上的筆跡（CAShapeLayer）

/// 一頁的筆跡。平常整頁畫成一張點陣圖（在背景畫），捲動時只是搬圖，不用每格重畫向量；
/// 寫一筆、擦掉只重畫改到的那一塊。放大到點陣圖會太大時改用向量（CAShapeLayer），放大也清楚
final class PageInkView: UIView {
    private var strokes: [InkStroke] = []
    private var offset: CGPoint = .zero
    private var hiddenIDs: Set<UUID> = []

    /// 點陣圖的解析度（每點幾個像素）＝螢幕倍率 × 縮放
    private(set) var renderScale: CGFloat = UIScreen.main.scale
    /// 一頁點陣圖最多幾個像素（約 64MB）；超過就用向量。13 吋 iPad 頁面寬度填滿螢幕約 600 萬像素，放大到約 1.6 倍都還是點陣圖
    static let maxBitmapPixels: CGFloat = 16_000_000

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// offset：頁面內容原點在這個 view 裡的位置（擴展頁面的留白）；renderScale：順便換解析度（一起換只畫一次）
    func set(strokes: [InkStroke], offset: CGPoint, renderScale scale: CGFloat? = nil) {
        var changed = strokes != self.strokes || offset != self.offset
        if let scale, abs(scale - renderScale) > 0.01 {
            scaleWork?.cancel()
            scaleWork = nil
            renderScale = scale
            changed = true
        }
        guard changed else { return }
        self.strokes = strokes
        self.offset = offset
        update()
    }

    /// 套索移動中先藏起來的筆跡
    func setHidden(_ ids: Set<UUID>) {
        guard ids != hiddenIDs else { return }
        hiddenIDs = ids
        update()
    }

    private var scaleWork: DispatchWorkItem?

    /// 換解析度。縮放中會一直呼叫：停下來 0.2 秒後才重畫，中間先把舊的圖拉大顯示
    func setRenderScale(_ scale: CGFloat, immediately: Bool = false) {
        scaleWork?.cancel()
        scaleWork = nil
        if immediately {
            set(strokes: strokes, offset: offset, renderScale: scale)
            return
        }
        guard abs(scale - renderScale) > 0.01 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.renderScale = scale
            self?.update()
        }
        scaleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
        if bounds.size != bitmapSize && !vectorShown { update() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        layer.sublayers?.forEach { $0.contentsScale = scale }
    }

    private var visibleStrokes: [InkStroke] { hiddenIDs.isEmpty ? strokes : strokes.filter { !hiddenIDs.contains($0.id) } }

    private var wantsBitmap: Bool { bounds.width * bounds.height * renderScale * renderScale <= Self.maxBitmapPixels }

    private func update() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard wantsBitmap else { showVector(); return }
        let visible = visibleStrokes
        // 現有的圖（解析度舊了也一樣）先跟著改，畫面不用等；改動太多就整張在背景重畫
        if let ctx = bitmap, bitmapOffset == offset, bitmapSize == bounds.size,
           Self.applyChanges(from: bitmapContent, to: visible, in: ctx) {
            bitmapContent = visible
            layer.contents = ctx.makeImage()
            if bitmapScale == renderScale {
                removeVector()
                return
            }
        }
        // 空白頁：直接開一張空的圖，寫第一筆時馬上有地方畫
        if visible.isEmpty, bitmap == nil, let ctx = Self.makeBitmap(size: bounds.size, scale: renderScale, offset: offset) {
            _ = nextGeneration()
            isBuilding = false
            building = nil
            adopt(ctx, content: [], scale: renderScale, offset: offset, size: bounds.size)
            return
        }
        if isBuilding, building == Target(scale: renderScale, offset: offset, size: bounds.size) { return }
        renderInBackground(visible)
    }

    // MARK: 點陣圖

    private var bitmap: CGContext?
    /// 點陣圖裡現在畫的筆跡（已去掉藏起來的）
    private var bitmapContent: [InkStroke] = []
    private var bitmapScale: CGFloat = 0
    private var bitmapOffset: CGPoint = .zero
    private var bitmapSize: CGSize = .zero

    private struct Target: Equatable {
        var scale: CGFloat
        var offset: CGPoint
        var size: CGSize
    }

    /// 背景還在畫整頁的圖
    private(set) var isBuilding = false
    /// 整頁重畫的次數（測試用：寫一筆不該整頁重畫）
    private(set) var fullRenders = 0
    /// 畫面上是一張點陣圖（不是一堆向量層）
    var showsBitmap: Bool { layer.contents != nil && !vectorShown }
    private var building: Target?
    /// 每次換一個要畫的目標就加一；背景畫好時目標已經換了就丟掉
    private var generation = 0
    /// 好幾頁可以同時畫（多核心）
    private static let renderQueue = DispatchQueue(label: "PageInkView.render", qos: .userInitiated, attributes: .concurrent)

    /// 背景畫到一半，頁面已經捲走或內容換了：讓它提早停
    private final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var cancelled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return flag }
            set { lock.lock(); flag = newValue; lock.unlock() }
        }
    }
    private var cancel = Cancel()

    /// 換一個新的目標：背景還在畫的舊目標作廢
    private func nextGeneration() -> Int {
        cancel.cancelled = true
        cancel = Cancel()
        generation += 1
        return generation
    }

    deinit { cancel.cancelled = true }

    private func renderInBackground(_ content: [InkStroke]) {
        let gen = nextGeneration()
        let token = cancel
        let target = Target(scale: renderScale, offset: offset, size: bounds.size)
        building = target
        isBuilding = true
        Self.renderQueue.async {
            guard !token.cancelled else { return }
            var ctx = Self.makeBitmap(size: target.size, scale: target.scale, offset: target.offset)
            if let c = ctx, !InkRenderer.drawBatched(content, in: c, shouldStop: { token.cancelled }) { ctx = nil }
            guard !token.cancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen else { return }
                self.isBuilding = false
                self.building = nil
                guard let ctx else { return }
                self.fullRenders += 1
                self.adopt(ctx, content: content, scale: target.scale, offset: target.offset, size: target.size)
            }
        }
    }

    /// 換上畫好的圖；畫的期間有改過的筆跡接著補上
    private func adopt(_ ctx: CGContext, content: [InkStroke], scale: CGFloat, offset: CGPoint, size: CGSize) {
        bitmap = ctx
        bitmapContent = content
        bitmapScale = scale
        bitmapOffset = offset
        bitmapSize = size
        layer.contents = ctx.makeImage()
        update()
    }

    /// 透明的點陣圖，座標同頁面（左上角原點、已平移 offset）
    private static func makeBitmap(size: CGSize, scale: CGFloat, offset: CGPoint) -> CGContext? {
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / size.width, y: -CGFloat(h) / size.height)
        ctx.translateBy(x: offset.x, y: offset.y)
        return ctx
    }

    /// 一次最多直接改幾筆；更多（例如剛打開的頁面、整頁貼上）就整張在背景重畫
    static let maxPatchStrokes = 64

    /// 只重畫改到的地方：只是多寫了幾筆就直接畫上去；其他改動（擦掉、改顏色、移動）清掉那一塊再重畫。
    /// 改動太多回傳 false、不畫
    private static func applyChanges(from old: [InkStroke], to new: [InkStroke], in ctx: CGContext) -> Bool {
        if new.count >= old.count, new.prefix(old.count).elementsEqual(old) {
            guard new.count - old.count <= maxPatchStrokes else { return false }
            InkRenderer.drawBatched(Array(new.dropFirst(old.count)), in: ctx)
            return true
        }
        var oldByID: [UUID: InkStroke] = [:]
        for s in old { oldByID[s.id] = s }
        var newIDs = Set<UUID>()
        var dirty = CGRect.null
        var changed = 0
        for s in new {
            newIDs.insert(s.id)
            if oldByID[s.id] != s {
                dirty = dirty.union(InkGeometry.bounds(of: s))
                changed += 1
            }
        }
        for s in old where !newIDs.contains(s.id) {
            dirty = dirty.union(InkGeometry.bounds(of: s))
            changed += 1
        }
        guard changed <= maxPatchStrokes else { return false }
        guard !dirty.isNull else { return true }
        // 多留 1pt 給反鋸齒的邊
        dirty = dirty.insetBy(dx: -1, dy: -1)
        ctx.saveGState()
        ctx.clip(to: dirty)
        ctx.clear(dirty)
        InkRenderer.drawBatched(new, in: ctx, clip: dirty)
        ctx.restoreGState()
        return true
    }

    // MARK: 向量（放大很多時）

    /// 一層（一個 CAShapeLayer）最多畫幾筆。整頁合成一層的話，每寫一筆整頁都要重畫
    static let strokesPerLayer = 64

    private var vectorShown: Bool { !(layer.sublayers ?? []).isEmpty }

    private func showVector() {
        if bitmap != nil || building != nil {
            // 從點陣圖換成向量：背景還沒畫好的圖不要了
            _ = nextGeneration()
            isBuilding = false
            building = nil
            bitmap = nil
            bitmapContent = []
            bitmapSize = .zero
            // 舊的圖先留著顯示，向量好了才拿掉
        }
        // 向量還在背景算：算好會自己補上最新的筆跡
        if isBuilding { return }
        rebuildVector()
    }

    private func removeVector() {
        guard vectorShown else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        chunks = []
        builtOffset = nil
    }

    /// 一層要畫的筆跡：同顏色、同粗細、連續寫的幾筆
    private struct Chunk: Equatable {
        var color: String
        var width: CGFloat
        /// 粗細會變的筆（毛筆）：這一層只畫線寬是 width 的那幾段
        var variable: Bool
        var strokes: [InkStroke]
    }

    private var chunks: [Chunk] = []
    private var builtOffset: CGPoint?

    /// 毛筆一段的線寬（取到 0.05pt，同樣粗細的段才能畫在同一層）
    private static func segmentWidth(_ a: InkPoint, _ b: InkPoint) -> CGFloat {
        (((a.width + b.width) / 2) * 20).rounded() / 20
    }

    private static func makeChunks(_ strokes: [InkStroke]) -> [Chunk] {
        var out: [Chunk] = []
        func add(_ s: InkStroke, width: CGFloat, variable: Bool) {
            if let last = out.last, last.color == s.colorHex, last.width == width, last.variable == variable,
               last.strokes.count < strokesPerLayer {
                out[out.count - 1].strokes.append(s)
            } else {
                out.append(Chunk(color: s.colorHex, width: width, variable: variable, strokes: [s]))
            }
        }
        for s in strokes {
            guard let first = s.points.first else { continue }
            if s.points.allSatisfy({ $0.w == first.w }) {
                add(s, width: first.width, variable: false)
            } else {
                var widths: [CGFloat] = []
                for (a, b) in zip(s.points, s.points.dropFirst()) {
                    let w = segmentWidth(a, b)
                    if !widths.contains(w) { widths.append(w) }
                }
                for w in widths { add(s, width: w, variable: true) }
            }
        }
        return out
    }

    private static func path(_ c: Chunk, offset o: CGPoint) -> CGPath {
        let p = CGMutablePath()
        func pt(_ q: InkPoint) -> CGPoint { CGPoint(x: q.point.x + o.x, y: q.point.y + o.y) }
        for s in c.strokes {
            guard let first = s.points.first else { continue }
            if c.variable {
                for (a, b) in zip(s.points, s.points.dropFirst()) where segmentWidth(a, b) == c.width {
                    p.move(to: pt(a))
                    p.addLine(to: pt(b))
                }
            } else {
                p.move(to: pt(first))
                // 只有一點：長度 0 的線段加圓頭＝一個點
                if s.points.count == 1 { p.addLine(to: pt(first)) }
                for q in s.points.dropFirst() { p.addLine(to: pt(q)) }
            }
        }
        return p
    }

    /// 前後疊放順序不變；只重畫內容有變的那幾層（寫一筆通常只動到最後一層）。
    /// 第一次建（剛換成向量、或剛進來的頁面）在背景算路徑
    private func rebuildVector() {
        let visible = visibleStrokes
        if chunks.isEmpty && !visible.isEmpty {
            let gen = generation
            let offset = self.offset
            isBuilding = true
            Self.renderQueue.async {
                let new = Self.makeChunks(visible)
                let paths: [CGPath?] = new.map { Self.path($0, offset: offset) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.isBuilding = false
                    self.applyVector(new, paths: paths, offset: offset)
                    // 算的期間改過的筆跡接著補上
                    if self.visibleStrokes != visible { self.rebuildVector() }
                }
            }
            return
        }
        let new = Self.makeChunks(visible)
        let all = builtOffset != offset
        let paths: [CGPath?] = new.indices.map { i in
            all || i >= chunks.count || chunks[i] != new[i] ? Self.path(new[i], offset: offset) : nil
        }
        applyVector(new, paths: paths, offset: offset)
    }

    /// paths[i] 是 nil 的那層內容沒變，不用重畫
    private func applyVector(_ new: [Chunk], paths: [CGPath?], offset: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        var layers = (layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        let scale = window?.screen.scale ?? UIScreen.main.scale
        while layers.count < new.count {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
            l.contentsScale = scale
            l.frame = bounds
            layer.addSublayer(l)
            layers.append(l)
        }
        for (i, c) in new.enumerated() {
            guard let p = paths[i] else { continue }
            let l = layers[i]
            l.path = p
            l.lineWidth = c.width
            l.strokeColor = UIColor(hex: c.color).cgColor
        }
        for l in layers.dropFirst(new.count) { l.removeFromSuperlayer() }
        CATransaction.commit()
        chunks = new
        builtOffset = offset
    }
}

// MARK: - 編輯器：寫、存、擦

/// 寫到一半的一筆（文件座標）
struct InkDraft {
    var points: [InkPoint]
    var colorHex: String
    var baseWidth: CGFloat
    var pressure: Bool
    /// 虛線的筆：放開後依它的虛線設定切成一段一段（nil＝實線）
    var dashPreset: BrushPreset?
    /// 還會補上準確值的取樣點：編號 → points 的索引
    var pendingUpdates: [NSNumber: Int] = [:]
    /// 停住後認出的圖形（之後筆尖移動是在調整它，不是繼續寫）
    var shape: InkShape?
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
                         pressure: preset.style == .fountainPen, dashPreset: preset.isDashed ? preset : nil)
        let w = inkWidth(d, force: s.force)
        d.points = [InkPoint(s.point, width: w)]
        if let u = s.updateIndex { d.pendingUpdates[u] = 0 }
        inkDraft = d
        // 寫的時候也只畫在起點那一頁裡面（放開後整筆存在那一頁，超出頁面的部分不顯示）
        let pi = pageIndex(containing: s.point) ?? nearestPageIndex(to: s.point)
        liveInkView.clip = pageFrames.indices.contains(pi) ? pagesContainer.convert(pageFrames[pi], to: liveInkView) : nil
        liveInkView.begin(screen(s.point), width: w * canvas.zoomScale, color: preset.color)
        restartInkHold(at: screen(s.point))
        DebugLog.add("custom ink begin drawGR=\(canvas.drawingGestureRecognizer.isEnabled)")
    }

    // MARK: 停住變圖形

    /// 停住 0.5 秒（筆尖移動不到 6pt）就把這一筆認成圖形
    static let inkHoldDuration: TimeInterval = 0.5

    private func restartInkHold(at p: CGPoint) {
        inkHoldTimer?.invalidate()
        inkHoldTimer = nil
        inkHoldAnchor = p
        guard settings.shapeSnap else { return }
        let t = Timer(timeInterval: Self.inkHoldDuration, repeats: false) { [weak self] _ in self?.inkHeld() }
        RunLoop.main.add(t, forMode: .common)
        inkHoldTimer = t
    }

    func inkHeld() {
        inkHoldTimer = nil
        guard var d = inkDraft, d.shape == nil, let s = InkShapes.recognize(d.points.map(\.point)) else { return }
        d.shape = s
        inkDraft = d
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showInkShape(s, draft: d)
        DebugLog.add("custom ink hold -> \(s.kind)")
    }

    private func showInkShape(_ s: InkShape, draft d: InkDraft) {
        guard let first = s.points.first else { return }
        let w = shapeWidth(d) * canvas.zoomScale
        liveInkView.clear()
        liveInkView.begin(screen(first), width: w, color: UIColor(hex: d.colorHex))
        liveInkView.add(s.points.dropFirst().map { (screen($0), w) })
    }

    /// 圖形的線寬：手寫那一筆中間的粗細（有筆壓的筆也是一樣粗）
    private func shapeWidth(_ d: InkDraft) -> CGFloat {
        let ws = d.points.map(\.width).sorted()
        return ws.isEmpty ? d.baseWidth : ws[ws.count / 2]
    }

    func inkMoved(_ new: [InkCaptureRecognizer.Sample]) {
        guard var d = inkDraft else { return }
        // 已經變成圖形：筆尖移動是在調整大小
        if let s = d.shape, let last = new.last {
            let m = InkShapes.moved(s, to: last.point)
            d.shape = m
            inkDraft = d
            showInkShape(m, draft: d)
            return
        }
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
        // 還在移動就重新計時
        if let last = new.last, screen(last.point).distance(to: inkHoldAnchor) > 6 { restartInkHold(at: screen(last.point)) }
    }

    /// Pencil 補上了準確的位置／筆壓：換掉之前的估計值
    func inkUpdated(_ s: InkCaptureRecognizer.Sample) {
        guard var d = inkDraft, d.shape == nil, let u = s.updateIndex, let i = d.pendingUpdates[u], d.points.indices.contains(i) else { return }
        let w = inkWidth(d, force: s.force)
        d.points[i] = InkPoint(s.point, width: w)
        inkDraft = d
        liveInkView.replace(i, with: (screen(s.point), w * canvas.zoomScale))
    }

    func inkEnded(cancelled: Bool) {
        inkHoldTimer?.invalidate()
        inkHoldTimer = nil
        guard var d = inkDraft else { return }
        inkDraft = nil
        // 變成圖形的話，存的是圖形（一樣粗）
        if let s = d.shape, !s.points.isEmpty {
            let w = shapeWidth(d)
            d.points = s.points.map { InkPoint($0, width: w) }
        }
        guard let first = d.points.first else { liveInkView.clear(); return }
        // 整筆放在起點所在的那一頁（頁面內容座標）
        let pi = pageIndex(containing: first.point) ?? nearestPageIndex(to: first.point)
        guard pages.indices.contains(pi) else { liveInkView.clear(); return }
        let o = contentOrigin(pi)
        let stroke = InkGeometry.offset(InkStroke(colorHex: d.colorHex, points: d.points), by: CGPoint(x: -o.x, y: -o.y))
        // 虛線：照這一筆中間的粗細切成一段一段（寫的時候還是實線，和 PencilKit 的筆一樣）
        let pieces = d.dashPreset.map { preset -> [InkStroke] in
            let p = preset.dashPattern(lineWidth: shapeWidth(d))
            return InkGeometry.dashed(stroke, dash: p.dash, gap: p.gap)
        } ?? [stroke]
        // 存進頁面，同時拿掉寫的時候的筆跡（同一個畫面更新裡換過去）
        updatePage(pi) { $0.ink.append(contentsOf: pieces) }
        liveInkView.clear()
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
