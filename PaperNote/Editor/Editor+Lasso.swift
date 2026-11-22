import UIKit
import PencilKit

struct HighlightRef: Equatable {
    var pageID: UUID
    var id: UUID
}

/// 自製筆刷的一筆（Page.ink）
struct InkRef: Equatable {
    var pageID: UUID
    var id: UUID
}

/// 套索判斷（不碰畫面，可以單獨測試）
enum LassoGeometry {
    /// 筆跡有任何一點落在套索範圍內就算圈到（只圈到長線的一段也可以；
    /// 只圈到大圓圈、方框中間的空白則不算，才能在框裡圈字）
    static func circles(_ stroke: PKStroke, path: UIBezierPath, area: CGRect) -> Bool {
        guard area.intersects(stroke.renderBounds) else { return false }
        // 擦掉的部分（螢光筆遮罩外面）不算。遮罩每次讀都是一份新的：讀一次就好
        let mask = stroke.mask?.cgPath
        for p in stroke.path.interpolatedPoints(by: .distance(3))
        where path.contains(p.location.applying(stroke.transform)) && (mask?.contains(p.location) ?? true) {
            return true
        }
        return false
    }

    /// 點 p 落在筆跡上（離線 radius 以內，加上線寬一半）
    static func touches(_ stroke: PKStroke, at p: CGPoint, radius: CGFloat) -> Bool {
        guard stroke.renderBounds.insetBy(dx: -radius, dy: -radius).contains(p) else { return false }
        let k = abs(stroke.transform.a * stroke.transform.d - stroke.transform.b * stroke.transform.c).squareRoot()
        let mask = stroke.mask?.cgPath
        let pts = stroke.path.interpolatedPoints(by: .distance(2))
            .map { ($0.location.applying(stroke.transform), $0.size.width * k / 2, mask?.contains($0.location) ?? true) }
        if pts.count == 1 { return pts[0].2 && pts[0].0.distance(to: p) <= radius + pts[0].1 }
        // 擦掉的部分（螢光筆遮罩外面）不算
        return zip(pts, pts.dropFirst()).contains { a, b in a.2 && b.2 && InkGeometry.distance(p, a.0, b.0) <= radius + max(a.1, b.1) }
    }

    /// 矩形整個在套索裡面。邊緣留一點寬容：手畫的圈稍微切到角落也算
    static func encloses(_ r: CGRect, path: UIBezierPath) -> Bool {
        let inset = min(12, r.width * 0.05, r.height * 0.05)
        let b = r.insetBy(dx: inset, dy: inset)
        let n = 6
        return (0...n).allSatisfy { i in
            let f = CGFloat(i) / CGFloat(n)
            let x = b.minX + b.width * f, y = b.minY + b.height * f
            return [CGPoint(x: x, y: b.minY), CGPoint(x: x, y: b.maxY), CGPoint(x: b.minX, y: y), CGPoint(x: b.maxX, y: y)]
                .allSatisfy { path.contains($0) }
        }
    }
}

/// 自訂套索圈到的內容：筆跡（canvas.drawing 的索引）、物件、螢光標示
struct LassoSelection {
    var strokeIndices: [Int]
    var elements: [ElementRef]
    var highlights: [HighlightRef]
    var bounds: CGRect
    var ink: [InkRef] = []
    /// 使用者圈的形狀（文件座標）：選取框照這個形狀畫，不縮成外框。點選、貼上的沒有，用內容的外框
    var outline: [CGPoint]? = nil
    /// 點選整張筆跡貼紙選起來的
    var stickerSeed: UInt32? = nil

    /// 選取框的範圍（圈的形狀和內容加起來）：縮放把手放在它的右下角
    var frame: CGRect {
        guard let o = outline, o.count > 2 else { return bounds }
        return bounds.union(InkShapes.bounds(o))
    }

    /// p 在選取範圍內：圈的形狀裡面，或內容外框（含 margin）裡面
    func contains(_ p: CGPoint, margin: CGFloat) -> Bool {
        if bounds.insetBy(dx: -margin, dy: -margin).contains(p) { return true }
        guard let o = outline, o.count > 2 else { return false }
        return Self.path(o).contains(p)
    }

    /// 移動、縮放後：內容外框和圈的形狀一起變
    func applying(_ t: CGAffineTransform) -> (bounds: CGRect, outline: [CGPoint]?) {
        (bounds.applying(t), outline?.map { $0.applying(t) })
    }

    static func path(_ pts: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for q in pts.dropFirst() { path.addLine(to: q) }
        path.close()
        return path
    }

    var isEmpty: Bool { strokeIndices.isEmpty && elements.isEmpty && highlights.isEmpty && ink.isEmpty }
    /// 圈到可以改顏色的筆跡
    var hasInk: Bool { !strokeIndices.isEmpty || !ink.isEmpty }
    /// 只有筆跡：可以拖右下角等比例縮放（物件、螢光標示有自己的大小，不跟著縮放）
    var canScale: Bool { hasInk && elements.isEmpty && highlights.isEmpty }
}

/// 套索拷貝的內容（文件座標）
struct LassoClipboard {
    var strokes: [PKStroke]
    var elements: [(element: PageElement, docFrame: CGRect)]
    var highlights: [(colorHex: String, docRects: [CGRect])]
    var bounds: CGRect
    var changeCount: Int
    /// 自製筆刷的筆跡（文件座標）
    var ink: [InkStroke] = []
}

// MARK: - 自訂套索：可以圈筆跡、表格、圖片、文字框、螢光標示（鎖定的物件不會被圈到）

extension NotebookViewController {
    func handleLassoPan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began:
            if let grab = lassoGrab(at: p) {
                beginLassoMove(at: p, scaling: grab == .scale)
            } else {
                clearLassoSelection()
                lassoPoints = [p]
            }
        case .changed:
            if lassoMoveStart != nil {
                updateLassoMove(to: p)
            } else {
                lassoPoints.append(p)
                overlay.showLassoPath(lassoPoints)
            }
        case .ended:
            if lassoMoveStart != nil {
                endLassoMove(at: p)
            } else {
                lassoPoints.append(p)
                finishLassoPath()
            }
        default:
            if lassoMoveStart != nil { cancelLassoMove() }
            lassoPoints = []
            overlay.showLassoPath(nil)
        }
    }

    /// p 在圈選範圍內（含一點邊界）：按下去是移動，不是重新圈選
    func lassoSelectionHit(_ p: CGPoint) -> Bool {
        guard let sel = lassoSel else { return false }
        return sel.contains(p, margin: 14 / canvas.zoomScale)
    }

    enum LassoGrab { case move, scale }

    /// 按在選取範圍上是移動，按在右下角的把手上是縮放
    func lassoGrab(at p: CGPoint) -> LassoGrab? {
        guard let sel = lassoSel else { return nil }
        if let h = lassoScaleHandle(sel.frame), h.distance(to: p) < 22 / canvas.zoomScale { return .scale }
        return lassoSelectionHit(p) ? .move : nil
    }

    /// 縮放把手的位置（選取框右下角）；不能縮放時 nil
    func lassoScaleHandle(_ bounds: CGRect) -> CGPoint? {
        guard lassoSel?.canScale == true else { return nil }
        let m = 6 / canvas.zoomScale
        return CGPoint(x: bounds.maxX + m, y: bounds.maxY + m)
    }

    /// 選取框和縮放把手（拖曳中由拖曳自己更新）
    func updateLassoChrome() {
        guard lassoMoveStart == nil else { return }
        overlay.showLassoSelection(lassoSel?.frame, handle: lassoSel.flatMap { lassoScaleHandle($0.frame) }, outline: lassoSel?.outline)
    }

    func clearLassoSelection() {
        // 剪下、刪除之後選單跟著關掉
        if lassoSel != nil { editMenu.dismissMenu() }
        lassoSel = nil
        overlay.showLassoSelection(nil)
        overlay.showLassoPreview(nil, frame: .zero)
    }

    /// 選取工具點到的筆跡：最上面那一筆（虛線是整條）；沒點到筆跡回傳 nil
    func inkSelection(at p: CGPoint) -> LassoSelection? {
        let r = 8 / canvas.zoomScale
        // 自製筆刷的筆跡畫在 PencilKit 上面，先看它
        if let pi = pageIndex(containing: p) {
            let page = pages[pi]
            let o = contentOrigin(pi)
            if let hit = page.ink.last(where: { InkGeometry.hits($0, at: p - o, radius: r) }) {
                if let g = hit.stickerSeed, isStickerSeed(g) { return stickerSelection(g) }
                let picked = page.ink.filter { $0.id == hit.id || (hit.dashGroup != nil && $0.dashGroup == hit.dashGroup) }
                let bounds = picked.reduce(CGRect.null) { $0.union(InkGeometry.bounds(of: $1).offsetBy(dx: o.x, dy: o.y)) }
                return LassoSelection(strokeIndices: [], elements: [], highlights: [], bounds: bounds,
                                      ink: picked.map { InkRef(pageID: page.id, id: $0.id) })
            }
        }
        let strokes = canvas.drawing.strokes
        guard let hit = strokes.indices.last(where: { LassoGeometry.touches(strokes[$0], at: p, radius: r) }) else { return nil }
        if isStickerSeed(strokes[hit].randomSeed) { return stickerSelection(strokes[hit].randomSeed) }
        let picked = DashedStroke.wholeDashes(in: strokes, picked: [hit])
        let bounds = picked.reduce(CGRect.null) { $0.union(strokes[$1].renderBounds) }
        return LassoSelection(strokeIndices: picked, elements: [], highlights: [], bounds: bounds)
    }

    // MARK: 筆跡貼紙

    func isStickerSeed(_ seed: UInt32) -> Bool { session.document.stickerSeeds?.contains(seed) ?? false }

    /// 新的一張筆跡貼紙用的亂數種子（記在筆記本裡）
    func newStickerSeed() -> UInt32 {
        var seed = UInt32.random(in: 1 ... .max)
        while isStickerSeed(seed) || canvas.drawing.strokes.contains(where: { $0.randomSeed == seed }) {
            seed = UInt32.random(in: 1 ... .max)
        }
        session.document.stickerSeeds = (session.document.stickerSeeds ?? []) + [seed]
        return seed
    }

    /// 整張筆跡貼紙：PencilKit 那幾筆（同一個亂數種子）和自製筆刷那幾筆
    func stickerSelection(_ seed: UInt32) -> LassoSelection? {
        let strokes = canvas.drawing.strokes
        let picked = strokes.indices.filter { strokes[$0].randomSeed == seed }
        var bounds = picked.reduce(CGRect.null) { $0.union(strokes[$1].renderBounds) }
        var ink: [InkRef] = []
        for (pi, page) in pages.enumerated() {
            let o = contentOrigin(pi)
            for s in page.ink where s.stickerSeed == seed {
                ink.append(InkRef(pageID: page.id, id: s.id))
                bounds = bounds.union(InkGeometry.bounds(of: s).offsetBy(dx: o.x, dy: o.y))
            }
        }
        guard !picked.isEmpty || !ink.isEmpty else { return nil }
        return LassoSelection(strokeIndices: picked, elements: [], highlights: [], bounds: bounds, ink: ink, stickerSeed: seed)
    }

    /// 點到貼上的筆跡貼紙：整張選起來；點到一般的筆跡回傳 nil
    func stickerInkSelection(at p: CGPoint) -> LassoSelection? {
        guard let sel = inkSelection(at: p), sel.stickerSeed != nil else { return nil }
        return sel
    }

    /// 選取工具：選起這些筆跡（和套索圈到的一樣可以移動、縮放、打開選單）
    func selectInk(_ sel: LassoSelection) {
        select(nil)
        clearLassoSelection()
        lassoSel = sel
        updateLassoChrome()
    }

    private func finishLassoPath() {
        let pts = lassoPoints
        lassoPoints = []
        overlay.showLassoPath(nil)
        guard pts.count > 4 else {
            DebugLog.add("lasso end: too few points \(pts.count)")
            updateUITestDump()
            return
        }
        let path = UIBezierPath()
        path.move(to: pts[0])
        for q in pts.dropFirst() { path.addLine(to: q) }
        path.close()
        let area = path.bounds

        var bounds = CGRect.null
        // 虛線圈到一段就是整條
        let allStrokes = canvas.drawing.strokes
        let strokes = DashedStroke.wholeDashes(in: allStrokes, picked: allStrokes.indices.filter { LassoGeometry.circles(allStrokes[$0], path: path, area: area) })
        for i in strokes { bounds = bounds.union(allStrokes[i].renderBounds) }
        /// 套索和矩形有重疊（圈到一部分）就算
        func touches(_ r: CGRect) -> Bool {
            guard area.intersects(r) else { return false }
            let samples = [r.center, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                           CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
                           CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
            if samples.contains(where: { path.contains($0) }) { return true }
            return pts.contains { r.contains($0) }
        }

        var elements: [ElementRef] = []
        var highlights: [HighlightRef] = []
        var ink: [InkRef] = []
        for (pi, page) in pages.enumerated() where pageFrames[pi].intersects(area) {
            let io = contentOrigin(pi)
            let circled = page.ink.filter { s in
                InkGeometry.bounds(of: s).offsetBy(dx: io.x, dy: io.y).intersects(area) && InkGeometry.circled(s, offset: io, path: path)
            }
            let circledIDs = Set(circled.map(\.id)), dashGroups = Set(circled.compactMap(\.dashGroup))
            for s in page.ink where circledIDs.contains(s.id) || s.dashGroup.map({ dashGroups.contains($0) }) == true {
                ink.append(InkRef(pageID: page.id, id: s.id))
                bounds = bounds.union(InkGeometry.bounds(of: s).offsetBy(dx: io.x, dy: io.y))
            }
            // 圈到一部分就算（表格、圖片、電路圖都一樣）；不想被圈到就鎖起來
            for e in page.elements where !e.locked {
                let f = docFrame(of: e, pageIndex: pi)
                if touches(f) {
                    elements.append(ElementRef(pageID: page.id, elementID: e.id))
                    bounds = bounds.union(f)
                }
            }
            let o = contentOrigin(pi)
            for h in page.highlights {
                let rects = h.rects.map { $0.offsetBy(dx: o.x, dy: o.y) }
                if rects.contains(where: touches) {
                    highlights.append(HighlightRef(pageID: page.id, id: h.id))
                    for r in rects { bounds = bounds.union(r) }
                }
            }
        }
        let sel = LassoSelection(strokeIndices: strokes, elements: elements, highlights: highlights, bounds: bounds, ink: ink, outline: pts)
        DebugLog.add("lasso end points=\(pts.count) strokes=\(strokes.count) ink=\(ink.count) elements=\(elements.count) highlights=\(highlights.count)")
        if strokes.isEmpty {
            // 套索裡有 PencilKit 筆跡的控制點卻沒圈到：記下那幾筆，查為什麼
            let missed = allStrokes.filter { s in s.path.contains { path.contains($0.location.applying(s.transform)) } }
            if !missed.isEmpty {
                DebugLog.add("lasso missed \(missed.count): " + missed.prefix(3).map(StrokeEraser.summary).joined(separator: " | "))
            }
        }
        updateUITestDump()
        guard !sel.isEmpty else { return }
        lassoSel = sel
        updateLassoChrome()
        // 不馬上跳選單（會蓋住圈到的東西、沒辦法拖）：點一下選取範圍才打開
        let hintKey = "lasso.tapForMenuHintShown"
        if !UserDefaults.standard.bool(forKey: hintKey) {
            UserDefaults.standard.set(true, forKey: hintKey)
            showToast(L("拖曳可以移動，只圈到筆跡時拉右下角可以縮放；點一下選取範圍打開選單"))
        }
    }

    // MARK: 移動、縮放

    private func beginLassoMove(at p: CGPoint, scaling: Bool) {
        guard let sel = lassoSel else { return }
        editMenu.dismissMenu()
        lassoMoveStart = p
        lassoScaling = scaling
        let drawing = canvas.drawing
        lassoMoveOriginal = drawing
        let set = Set(sel.strokeIndices)
        lassoMoveStrokes = sel.strokeIndices.compactMap { drawing.strokes[safe: $0] }
        // 拖曳中先把筆跡拿出來，用圖片預覽
        var rest = drawing
        rest.strokes = drawing.strokes.enumerated().filter { !set.contains($0.offset) }.map(\.element)
        isApplyingDrawing = true
        canvas.drawing = rest
        isApplyingDrawing = false
        // 自製筆刷的筆跡也先藏起來，一起放進預覽圖
        let movingInk = inkStrokes(sel.ink)
        lassoMoveInk = movingInk
        lassoPreviewScale = 1
        let preview = inkPreviewImage(lassoMoveStrokes, movingInk, rect: sel.bounds)
        showInkChangesAtOnce {
            setInkHidden(sel.ink)
            if let preview { overlay.showLassoPreview(preview, frame: sel.bounds) }
        }
        lassoMoveElementFrames = [:]
        for ref in sel.elements {
            if case let (pi, ei)? = locate(ref) { lassoMoveElementFrames[ref] = pages[pi].elements[ei].frame }
        }
    }

    /// 拖到 p 時圈到的東西要套用的變換（文件座標）：移動不超出頁面；縮放以左上角為基準、等比例，不超出頁面
    private func lassoDragTransform(to p: CGPoint) -> CGAffineTransform {
        guard let start = lassoMoveStart, let sel = lassoSel else { return .identity }
        let b = sel.bounds
        let v = CGPoint(x: p.x - start.x, y: p.y - start.y)
        guard lassoScaling else {
            let d = clampedDelta(moving: b, by: v)
            return CGAffineTransform(translationX: d.x, y: d.y)
        }
        // 把手在選取框（圈的形狀）的右下角，沿著對角線走：拖曳的距離投影到對角線上；左上角不動
        let fr = sel.frame
        let w = max(fr.width, 1), h = max(fr.height, 1)
        var k = 1 + (v.x * w + v.y * h) / (w * w + h * h)
        let c = CGPoint(x: b.midX, y: b.midY)
        if let f = pageFrames[safe: pageIndex(containing: c) ?? nearestPageIndex(to: c)] {
            k = min(k, max(1, min((f.maxX - fr.minX) / max(b.maxX - fr.minX, 1), (f.maxY - fr.minY) / max(b.maxY - fr.minY, 1))))
        }
        // 不縮到看不見
        k = max(k, min(1, 12 / max(b.width, b.height, 1)))
        return CGAffineTransform(translationX: fr.minX, y: fr.minY).scaledBy(x: k, y: k).translatedBy(x: -fr.minX, y: -fr.minY)
    }

    private func updateLassoMove(to p: CGPoint) {
        guard let sel = lassoSel else { return }
        let t = lassoDragTransform(to: p)
        let r = sel.bounds.applying(t)
        let frame = sel.frame.applying(t)
        overlay.showLassoSelection(frame, handle: lassoScaleHandle(frame), outline: sel.applying(t).outline)
        overlay.moveLassoPreview(to: r)
        // 縮放：照現在的大小重畫預覽（把原本的圖拉大會糊）；變化不到 2% 先用拉伸的
        if lassoScaling, abs(t.a / lassoPreviewScale - 1) > 0.02 {
            lassoPreviewScale = t.a
            let pk = lassoMoveStrokes.map { s -> PKStroke in
                var s = s
                s.transform = s.transform.concatenating(t)
                return s
            }
            if let img = inkPreviewImage(pk, lassoMoveInk.map { InkGeometry.applying($0, t) }, rect: r) {
                overlay.showLassoPreview(img, frame: r)
            }
        }
        // 圈到物件時只能移動
        for (ref, frame) in lassoMoveElementFrames {
            guard case let (pi, ei)? = locate(ref) else { continue }
            var e = pages[pi].elements[ei]
            e.frame = frame.offsetBy(dx: t.tx, dy: t.ty)
            pageViews[pages[pi].id]?.liveUpdate(e)
        }
    }

    private func endLassoMove(at p: CGPoint) {
        guard lassoMoveStart != nil, let sel = lassoSel, let original = lassoMoveOriginal else { return }
        let t = lassoDragTransform(to: p)
        lassoMoveStart = nil
        lassoScaling = false
        // 一次復原整個移動（筆跡可能移到別頁，那一頁也要能復原）
        let inkTargets = inkStrokes(sel.ink).map { pages[inkPageIndex(for: InkGeometry.applying($0, t))].id }
        recordEdit(drawing: original, pageIDs: Array(Set(affectedPageIDs(sel) + inkTargets)))

        var drawing = canvas.drawing
        let base = drawing.strokes.count
        drawing.strokes.append(contentsOf: lassoMoveStrokes.map { s in
            var s = s
            s.transform = s.transform.concatenating(t)
            return s
        })
        var movedInk: [InkRef] = []
        showInkChangesAtOnce {
            overlay.showLassoPreview(nil, frame: .zero)
            setInkHidden([])
            setDrawing(drawing)
            movedInk = transformModel(sel, t)
        }
        lassoMoveStrokes = []
        lassoMoveInk = []
        lassoMoveOriginal = nil
        lassoMoveElementFrames = [:]
        let moved = sel.applying(t)
        lassoSel = LassoSelection(strokeIndices: Array(base..<(base + sel.strokeIndices.count)), elements: sel.elements,
                                  highlights: sel.highlights, bounds: moved.bounds, ink: movedInk, outline: moved.outline)
        updateLassoChrome()
    }

    private func cancelLassoMove() {
        if let original = lassoMoveOriginal { setDrawing(original) }
        setInkHidden([])
        for (ref, _) in lassoMoveElementFrames {
            if case let (pi, _)? = locate(ref) { refreshPage(pi) }
        }
        lassoMoveStart = nil
        lassoScaling = false
        lassoMoveInk = []
        lassoMoveOriginal = nil
        lassoMoveStrokes = []
        lassoMoveElementFrames = [:]
        clearLassoSelection()
    }

    /// 物件、螢光標示、自製筆刷的筆跡套用 t（文件座標；不另外登記復原，由呼叫端登記）；回傳筆跡移動後的位置。
    /// 物件、螢光標示只會移動（圈到它們時不能縮放）
    private func transformModel(_ sel: LassoSelection, _ t: CGAffineTransform) -> [InkRef] {
        let d = CGPoint(x: t.tx, y: t.ty)
        for ref in sel.elements {
            guard case let (pi, ei)? = locate(ref) else { continue }
            updatePage(pi, undoable: false) {
                $0.elements[ei].frame = $0.elements[ei].frame.offsetBy(dx: d.x, dy: d.y)
                $0.elements[ei].snapCircuitToGrid()
            }
        }
        for h in sel.highlights {
            guard let pi = pageIndex(of: h.pageID), let hi = pages[pi].highlights.firstIndex(where: { $0.id == h.id }) else { continue }
            updatePage(pi, undoable: false) { $0.highlights[hi].rects = $0.highlights[hi].rects.map { $0.offsetBy(dx: d.x, dy: d.y) } }
        }
        // 筆跡移到哪一頁就放進哪一頁（中心點所在的頁面）
        var moved: [InkRef] = []
        for r in sel.ink {
            guard let pi = pageIndex(of: r.pageID), let s = pages[pi].ink.first(where: { $0.id == r.id }) else { continue }
            let doc = InkGeometry.applying(InkGeometry.offset(s, by: contentOrigin(pi)), t)
            let ti = inkPageIndex(for: doc)
            let to = contentOrigin(ti)
            let local = InkGeometry.offset(doc, by: CGPoint(x: -to.x, y: -to.y))
            if ti == pi {
                updatePage(pi, undoable: false) { page in
                    if let k = page.ink.firstIndex(where: { $0.id == r.id }) { page.ink[k] = local }
                }
            } else {
                updatePage(pi, undoable: false) { $0.ink.removeAll { $0.id == r.id } }
                updatePage(ti, undoable: false) { $0.ink.append(local) }
            }
            moved.append(InkRef(pageID: pages[ti].id, id: r.id))
        }
        return moved
    }

    private func affectedPageIDs(_ sel: LassoSelection) -> [UUID] {
        Array(Set(sel.elements.map(\.pageID) + sel.highlights.map(\.pageID) + sel.ink.map(\.pageID)))
    }

    // MARK: 自製筆刷的筆跡

    /// 圈到的自製筆刷筆跡（文件座標）
    func inkStrokes(_ refs: [InkRef]) -> [InkStroke] {
        refs.compactMap { r in
            guard let pi = pageIndex(of: r.pageID), let s = pages[pi].ink.first(where: { $0.id == r.id }) else { return nil }
            return InkGeometry.offset(s, by: contentOrigin(pi))
        }
    }

    /// 文件座標的一筆該放在哪一頁
    func inkPageIndex(for docStroke: InkStroke) -> Int {
        let c = InkGeometry.bounds(of: docStroke).center
        return pageIndex(containing: c) ?? nearestPageIndex(to: c)
    }

    /// 套索（或表格）移動中先把要移動的筆跡藏起來（空陣列＝全部顯示）
    func setInkHidden(_ refs: [InkRef]) {
        for (id, v) in pageViews {
            v.inkView.setHidden(Set(refs.filter { $0.pageID == id }.map(\.id)))
        }
    }

    /// body 裡對筆跡的所有改動和預覽圖一起換：畫面不會看到中間的樣子（字回到原位、字和預覽都不見、兩份重疊）。
    /// 外面包一層 CATransaction：body 裡自己 commit 的那幾次才不會各自先送上畫面
    func showInkChangesAtOnce(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let views = pageViews.values.map(\.inkView)
        for v in views { v.holdUpdates() }
        body()
        for v in views { v.showChanges() }
        CATransaction.commit()
    }

    /// 移動中的預覽圖：PencilKit 筆跡和自製筆刷的筆跡畫在一起（rect 是文件座標）；沒有筆跡回傳 nil
    func inkPreviewImage(_ pk: [PKStroke], _ ink: [InkStroke], rect: CGRect) -> UIImage? {
        guard !pk.isEmpty || !ink.isEmpty, !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        let scale = min(3, max(1, canvas.zoomScale * traitCollection.displayScale))
        let pkImage = pk.isEmpty ? nil : PageRenderer.inkImage(PKDrawing(strokes: pk), rect: rect, scale: scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: fmt).image { rc in
            let ctx = rc.cgContext
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            InkRenderer.draw(ink, in: ctx)
            pkImage?.draw(in: rect)
        }
    }

    // MARK: 選單：拷貝、剪下、刪除、複製一份

    func presentLassoMenu() {
        guard let sel = lassoSel else { return }
        var children: [UIMenuElement] = [
            UIAction(title: L("拷貝"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyLasso() },
            UIAction(title: L("剪下"), image: UIImage(systemName: "scissors")) { [weak self] _ in
                self?.copyLasso()
                self?.deleteLasso()
            },
            UIAction(title: L("複製一份"), image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateLasso() },
            // 添加至貼紙：跳出大的視窗選分類（第一格「創建新分類」）
            UIAction(title: L("添加至貼紙"), image: UIImage(systemName: "seal")) { [weak self] _ in self?.addLassoToStickers() },
            UIAction(title: L("刪除"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteLasso() },
        ]
        // 圈到筆跡：可以直接改顏色
        if sel.hasInk { children.insert(lassoColorMenu(), at: 0) }
        // 圈到一個物件（可以連上面的字一起）：換到選取工具編輯它
        if lassoEditTarget != nil {
            children.insert(UIAction(title: L("編輯"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.editLassoTarget() }, at: 0)
        }
        // 圈到電路圖：可以直接回到電路工具編輯
        if let circuit = sel.elements.first(where: { ref in locate(ref).map { pages[$0.0].elements[$0.1].isCircuit } ?? false }) {
            children.insert(UIAction(title: L("編輯電路圖"), image: UIImage(systemName: "bolt")) { [weak self] _ in
                self?.clearLassoSelection()
                self?.editCircuit(circuit)
            }, at: 0)
        }
        presentMenu(UIMenu(children: children), atDocPoint: CGPoint(x: sel.bounds.midX, y: sel.bounds.minY), avoiding: sel.bounds)
    }

    /// 套索圈到的唯一一個物件（表格、文字框、圖片）；電路圖用「編輯電路圖」
    var lassoEditTarget: ElementRef? {
        guard let sel = lassoSel, sel.elements.count == 1, let ref = sel.elements.first,
              case let (pi, ei)? = locate(ref), !pages[pi].elements[ei].isCircuit else { return nil }
        return ref
    }

    /// 換到選取工具、選好套索圈到的那個物件（表格就進入表格編輯）
    func editLassoTarget() {
        guard let ref = lassoEditTarget else { return }
        clearLassoSelection()
        setTool(.select)
        select(ref)
    }

    // MARK: 改顏色

    /// 常用的筆與螢光筆顏色，加上「其他顏色…」
    private func lassoColorMenu() -> UIMenu {
        var seen = Set<String>()
        var colors: [String] = []
        for p in BrushStore.shared.presets(.pen) + BrushStore.shared.presets(.highlighter) where seen.insert(p.colorHex.uppercased()).inserted {
            colors.append(p.colorHex)
        }
        var items: [UIMenuElement] = colors.map { hex in
            UIAction(title: hex, image: Self.colorSwatch(UIColor(hex: hex))) { [weak self] _ in self?.recolorLasso(UIColor(hex: hex)) }
        }
        items.append(UIAction(title: L("其他顏色…"), image: UIImage(systemName: "eyedropper")) { [weak self] _ in self?.presentLassoColorPicker() })
        let grid = UIMenu(title: "", options: .displayInline, children: items)
        grid.preferredElementSize = .small
        return UIMenu(title: L("顏色"), image: UIImage(systemName: "paintpalette"), children: [grid])
    }

    static func colorSwatch(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            color.withAlphaComponent(1).setFill()
            UIBezierPath(ovalIn: r).fill()
            UIColor.separator.setStroke()
            UIBezierPath(ovalIn: r).stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    /// 圈到的筆跡換成這個顏色（螢光筆保留原本的透明度）
    func recolorLasso(_ color: UIColor) {
        guard let sel = lassoSel, sel.hasInk else { return }
        recordEdit(drawing: canvas.drawing, pageIDs: Array(Set(sel.ink.map(\.pageID))))
        let hex = color.withAlphaComponent(1).hexString
        for r in sel.ink {
            guard let pi = pageIndex(of: r.pageID) else { continue }
            updatePage(pi, undoable: false) { page in
                if let k = page.ink.firstIndex(where: { $0.id == r.id }) { page.ink[k].colorHex = hex }
            }
        }
        guard !sel.strokeIndices.isEmpty else { return }
        var d = canvas.drawing
        for i in sel.strokeIndices where d.strokes.indices.contains(i) {
            let old = d.strokes[i]
            var alpha: CGFloat = 1
            old.ink.color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
            // 只改墨水 PencilKit 不會重畫；建一筆新的（路徑、位置、筆觸紋理不變）畫面才會馬上更新
            d.strokes[i] = PKStroke(ink: PKInk(old.ink.inkType, color: color.withAlphaComponent(alpha)), path: old.path,
                                    transform: old.transform, mask: old.mask, randomSeed: old.randomSeed)
        }
        // 先拿掉這幾筆、下一刻再放回來，確保 PencilKit 重畫
        var without = d
        for i in sel.strokeIndices.sorted(by: >) where without.strokes.indices.contains(i) { without.strokes.remove(at: i) }
        setDrawing(without)
        DispatchQueue.main.async { [weak self] in self?.setDrawing(d) }
    }

    private func presentLassoColorPicker() {
        guard let sel = lassoSel else { return }
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        if let i = sel.strokeIndices.first, let s = canvas.drawing.strokes[safe: i] {
            picker.selectedColor = s.ink.color.withAlphaComponent(1)
        } else if let s = inkStrokes(sel.ink).first {
            picker.selectedColor = UIColor(hex: s.colorHex).withAlphaComponent(1)
        }
        let handler = ColorPickerRelay { [weak self] color in self?.recolorLasso(color) }
        picker.delegate = handler
        lassoColorPicker = handler
        picker.modalPresentationStyle = .popover
        if let pop = picker.popoverPresentationController {
            pop.sourceView = pagesContainer
            pop.sourceRect = sel.bounds
        }
        present(picker, animated: true)
    }

    private func copyLasso() {
        guard let sel = lassoSel else { return }
        let strokes = sel.strokeIndices.compactMap { canvas.drawing.strokes[safe: $0] }
        var elements: [(element: PageElement, docFrame: CGRect)] = []
        for ref in sel.elements {
            if case let (pi, ei)? = locate(ref) {
                let e = pages[pi].elements[ei]
                elements.append((e, docFrame(of: e, pageIndex: pi)))
            }
        }
        var highlights: [(colorHex: String, docRects: [CGRect])] = []
        for h in sel.highlights {
            guard let pi = pageIndex(of: h.pageID), let hl = pages[pi].highlights.first(where: { $0.id == h.id }) else { continue }
            let o = contentOrigin(pi)
            highlights.append((hl.colorHex, hl.rects.map { $0.offsetBy(dx: o.x, dy: o.y) }))
        }
        // 也放一張圖到系統剪貼簿，可以貼到其他 App
        let pb = UIPasteboard.general
        if let img = renderRegion(UIBezierPath(rect: sel.bounds.insetBy(dx: -4, dy: -4))) { pb.image = img }
        lassoClipboard = LassoClipboard(strokes: strokes, elements: elements, highlights: highlights,
                                        bounds: sel.bounds, changeCount: pb.changeCount, ink: inkStrokes(sel.ink))
    }

    private func deleteLasso() {
        guard let sel = lassoSel else { return }
        DebugLog.add("lasso delete strokes=\(sel.strokeIndices.count) elements=\(sel.elements.count) highlights=\(sel.highlights.count)")
        recordEdit(drawing: canvas.drawing, pageIDs: affectedPageIDs(sel))
        var drawing = canvas.drawing
        for i in sel.strokeIndices.sorted(by: >) where drawing.strokes.indices.contains(i) {
            drawing.strokes.remove(at: i)
        }
        setDrawing(drawing)
        for ref in sel.elements {
            guard let pi = pageIndex(of: ref.pageID) else { continue }
            updatePage(pi, undoable: false) { $0.elements.removeAll { $0.id == ref.elementID } }
        }
        for h in sel.highlights {
            guard let pi = pageIndex(of: h.pageID) else { continue }
            updatePage(pi, undoable: false) { $0.highlights.removeAll { $0.id == h.id } }
        }
        for r in sel.ink {
            guard let pi = pageIndex(of: r.pageID) else { continue }
            updatePage(pi, undoable: false) { $0.ink.removeAll { $0.id == r.id } }
        }
        clearLassoSelection()
    }

    private func duplicateLasso() {
        copyLasso()
        guard let clip = lassoClipboard else { return }
        pasteLasso(clip, center: CGPoint(x: clip.bounds.midX + 24, y: clip.bounds.midY + 24))
    }

    /// 把套索拷貝的內容貼到 center（文件座標）。select：貼上後換到套索選起來（貼紙工具貼筆跡貼紙時留在貼紙工具）
    /// stickerSeed：貼上的是筆跡貼紙，筆跡都標上這張貼紙
    func pasteLasso(_ clip: LassoClipboard, center: CGPoint, select: Bool = true, stickerSeed: UInt32? = nil) {
        let d = CGPoint(x: center.x - clip.bounds.midX, y: center.y - clip.bounds.midY)
        let target = pageIndex(containing: center) ?? nearestPageIndex(to: center)
        guard pages.indices.contains(target) else { return }
        recordEdit(drawing: canvas.drawing, pageIDs: [pages[target].id])

        var drawing = canvas.drawing
        let base = drawing.strokes.count
        let t = CGAffineTransform(translationX: d.x, y: d.y)
        drawing.strokes.append(contentsOf: DashedStroke.copies(of: clip.strokes).map { s in
            var s = s
            s.transform = s.transform.concatenating(t)
            // 同一張貼紙的筆跡共用一個亂數種子（虛線還是靠建立時間分開）
            if let stickerSeed { s = PKStroke(ink: s.ink, path: s.path, transform: s.transform, mask: s.mask, randomSeed: stickerSeed) }
            return s
        })
        setDrawing(drawing)

        let o = contentOrigin(target)
        var newElements: [ElementRef] = []
        var newHighlights: [HighlightRef] = []
        var newInk: [InkRef] = []
        // 貼上的虛線是另一條：之後整筆擦除不會連原本的一起擦
        var dashes: [UUID: UUID] = [:]
        updatePage(target, undoable: false) { page in
            for s in clip.ink {
                var s = InkGeometry.offset(s, by: CGPoint(x: d.x - o.x, y: d.y - o.y))
                s.id = UUID()
                s.stickerSeed = stickerSeed
                if let g = s.dashGroup {
                    let n = dashes[g] ?? UUID()
                    dashes[g] = n
                    s.dashGroup = n
                }
                page.ink.append(s)
                newInk.append(InkRef(pageID: page.id, id: s.id))
            }
            for item in clip.elements {
                var e = item.element
                e.id = UUID()
                e.locked = false
                e.refreshCircuitIDs()
                e.frame.origin = CGPoint(x: item.docFrame.minX + d.x - o.x, y: item.docFrame.minY + d.y - o.y)
                e.snapCircuitToGrid()
                page.elements.append(e)
                newElements.append(ElementRef(pageID: page.id, elementID: e.id))
            }
            for h in clip.highlights {
                let hl = TextHighlight(rects: h.docRects.map { $0.offsetBy(dx: d.x - o.x, dy: d.y - o.y) }, colorHex: h.colorHex)
                page.highlights.append(hl)
                newHighlights.append(HighlightRef(pageID: page.id, id: hl.id))
            }
        }
        guard select else { return }
        // 選取工具選起的筆跡複製一份：留在選取工具
        if tool != .lasso && tool != .select { setTool(.lasso) }
        lassoSel = LassoSelection(strokeIndices: Array(base..<(base + clip.strokes.count)), elements: newElements,
                                  highlights: newHighlights, bounds: clip.bounds.offsetBy(dx: d.x, dy: d.y), ink: newInk)
        updateLassoChrome()
    }

    // MARK: - 鎖頭

    /// 選取工具：選到的物件旁顯示；套索工具：所有表格、圖片、電路圖旁都顯示；電路工具：正在編輯的和鎖住的電路圖旁顯示
    func lockIconTargets() -> [(ref: ElementRef, point: CGPoint, locked: Bool)] {
        let off = 36 / canvas.zoomScale
        // 表格：左上角外側、移動按鈕的上方；圖片：左上角；電路圖：左上角外側（裡面可能有元件）
        func target(_ e: PageElement, _ pi: Int) -> (ref: ElementRef, point: CGPoint, locked: Bool) {
            let r = docFrame(of: e, pageIndex: pi)
            let p: CGPoint
            if e.isTable {
                p = CGPoint(x: r.minX - off, y: r.minY - off - 42 / canvas.zoomScale)
            } else if e.isCircuit {
                p = CGPoint(x: r.minX - off * 0.5, y: r.minY - off * 0.5)
            } else {
                p = CGPoint(x: r.minX + off * 0.5, y: r.minY + off * 0.5)
            }
            return (ElementRef(pageID: pages[pi].id, elementID: e.id), p, e.locked)
        }
        func lockable(_ e: PageElement) -> Bool { e.isTable || e.isImage || e.isCircuit }
        if tool == .select || tool == .image || tool == .sticker, editingTextView == nil, let ref = selected, case let (pi, ei)? = locate(ref),
           lockable(pages[pi].elements[ei]) {
            return [target(pages[pi].elements[ei], pi)]
        }
        if tool == .lasso {
            var out: [(ref: ElementRef, point: CGPoint, locked: Bool)] = []
            for (pi, page) in pages.enumerated() {
                for e in page.elements where lockable(e) { out.append(target(e, pi)) }
            }
            return out
        }
        if tool == .circuit {
            var out: [(ref: ElementRef, point: CGPoint, locked: Bool)] = []
            for (pi, page) in pages.enumerated() {
                for e in page.elements where e.isCircuit {
                    let ref = ElementRef(pageID: page.id, elementID: e.id)
                    if e.locked || ref == circuitTarget { out.append(target(e, pi)) }
                }
            }
            return out
        }
        return []
    }

    func updateLockChrome() {
        overlay.showLockIcons(lockIconTargets().map { ($0.point, $0.locked) })
        overlay.showImageDelete(imageDeleteTarget()?.point)
    }

    /// 選到的圖片（沒鎖定）：左上角鎖頭右邊的紅色叉叉
    func imageDeleteTarget() -> (ref: ElementRef, point: CGPoint)? {
        guard tool == .select || tool == .image || tool == .sticker, editingTextView == nil, let ref = selected,
              case let (pi, ei)? = locate(ref), pages[pi].elements[ei].isImage, !pages[pi].elements[ei].locked,
              let lock = lockIconTargets().first(where: { $0.ref == ref }) else { return nil }
        return (ref, CGPoint(x: lock.point.x + 36 / canvas.zoomScale, y: lock.point.y))
    }

    /// p 按在圖片的紅色叉叉上就刪掉，回傳有沒有刪
    func handleImageDeleteTap(at p: CGPoint) -> Bool {
        guard let t = imageDeleteTarget(), t.point.distance(to: p) < 20 / canvas.zoomScale else { return false }
        deleteElement(t.ref)
        showToast(L("已刪除圖片（可以按復原）"))
        return true
    }

    func lockIconHit(at p: CGPoint) -> ElementRef? {
        let tol = 20 / canvas.zoomScale
        return lockIconTargets().first { $0.point.distance(to: p) < tol }?.ref
    }

    func toggleLock(_ ref: ElementRef) {
        modifyElement(ref) { $0.locked.toggle() }
        if case let (pi, ei)? = locate(ref) {
            let e = pages[pi].elements[ei]
            if e.isCircuit {
                showToast(e.locked ? L("已鎖定：不能編輯、移動，也不會被套索圈到") : L("已解除鎖定：可以編輯、移動，也能被套索圈到"))
                // 鎖住正在編輯的電路圖：不能再編輯了
                if e.locked, circuitTarget == ref {
                    circuitTarget = nil
                    circuitSel = nil
                    if tool == .circuit { rebuildSubBar() }
                }
                updateCircuitChrome()
            } else {
                showToast(e.locked ? L("已鎖定：不能移動，也不會被套索圈到") : L("已解除鎖定：可以移動，也能被套索圈到"))
            }
        }
        clearLassoSelection()
        updateLockChrome()
        if tool == .select { rebuildSubBar() }
    }
}

/// 顏色選擇器選好顏色後套用（套索圈到的筆跡、表格底色、格線顏色）
final class ColorPickerRelay: NSObject, UIColorPickerViewControllerDelegate {
    private let apply: (UIColor) -> Void

    init(apply: @escaping (UIColor) -> Void) {
        self.apply = apply
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        if !continuously { apply(color) }
    }
}
