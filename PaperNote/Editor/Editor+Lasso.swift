import UIKit
import PencilKit

struct HighlightRef: Equatable {
    var pageID: UUID
    var id: UUID
}

/// 自訂套索圈到的內容：筆跡（canvas.drawing 的索引）、物件、螢光標示
struct LassoSelection {
    var strokeIndices: [Int]
    var elements: [ElementRef]
    var highlights: [HighlightRef]
    var bounds: CGRect

    var isEmpty: Bool { strokeIndices.isEmpty && elements.isEmpty && highlights.isEmpty }
}

/// 套索拷貝的內容（文件座標）
struct LassoClipboard {
    var strokes: [PKStroke]
    var elements: [(element: PageElement, docFrame: CGRect)]
    var highlights: [(colorHex: String, docRects: [CGRect])]
    var bounds: CGRect
    var changeCount: Int
}

// MARK: - 自訂套索：可以圈筆跡、表格、圖片、文字框、螢光標示（鎖定的物件不會被圈到）

extension NotebookViewController {
    func handleLassoPan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began:
            if let sel = lassoSel, sel.bounds.insetBy(dx: -14 / canvas.zoomScale, dy: -14 / canvas.zoomScale).contains(p) {
                beginLassoMove(at: p)
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

    func clearLassoSelection() {
        lassoSel = nil
        overlay.showLassoSelection(nil)
        overlay.showLassoPreview(nil, frame: .zero)
    }

    private func finishLassoPath() {
        let pts = lassoPoints
        lassoPoints = []
        overlay.showLassoPath(nil)
        guard pts.count > 4 else { return }
        let path = UIBezierPath()
        path.move(to: pts[0])
        for q in pts.dropFirst() { path.addLine(to: q) }
        path.close()
        let area = path.bounds

        var bounds = CGRect.null
        var strokes: [Int] = []
        for (i, s) in canvas.drawing.strokes.enumerated() {
            let b = s.renderBounds
            guard area.intersects(b), path.contains(b.center) else { continue }
            strokes.append(i)
            bounds = bounds.union(b)
        }
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
        for (pi, page) in pages.enumerated() where pageFrames[pi].intersects(area) {
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
        let sel = LassoSelection(strokeIndices: strokes, elements: elements, highlights: highlights, bounds: bounds)
        guard !sel.isEmpty else { return }
        lassoSel = sel
        overlay.showLassoSelection(sel.bounds)
        presentLassoMenu()
    }

    // MARK: 移動

    private func beginLassoMove(at p: CGPoint) {
        guard let sel = lassoSel else { return }
        editMenu.dismissMenu()
        lassoMoveStart = p
        let drawing = canvas.drawing
        lassoMoveOriginal = drawing
        let set = Set(sel.strokeIndices)
        lassoMoveStrokes = sel.strokeIndices.compactMap { drawing.strokes[safe: $0] }
        // 移動中先把筆跡拿出來，用圖片預覽
        var rest = drawing
        rest.strokes = drawing.strokes.enumerated().filter { !set.contains($0.offset) }.map(\.element)
        isApplyingDrawing = true
        canvas.drawing = rest
        isApplyingDrawing = false
        if !lassoMoveStrokes.isEmpty {
            let scale = min(3, max(1, canvas.zoomScale * traitCollection.displayScale))
            let img = PageRenderer.inkImage(PKDrawing(strokes: lassoMoveStrokes), rect: sel.bounds, scale: scale)
            overlay.showLassoPreview(img, frame: sel.bounds)
        }
        lassoMoveElementFrames = [:]
        for ref in sel.elements {
            if case let (pi, ei)? = locate(ref) { lassoMoveElementFrames[ref] = pages[pi].elements[ei].frame }
        }
    }

    private func updateLassoMove(to p: CGPoint) {
        guard let start = lassoMoveStart, let sel = lassoSel else { return }
        let d = CGPoint(x: p.x - start.x, y: p.y - start.y)
        let moved = sel.bounds.offsetBy(dx: d.x, dy: d.y)
        overlay.showLassoSelection(moved)
        overlay.moveLassoPreview(to: moved)
        for (ref, frame) in lassoMoveElementFrames {
            guard case let (pi, ei)? = locate(ref) else { continue }
            var e = pages[pi].elements[ei]
            e.frame = frame.offsetBy(dx: d.x, dy: d.y)
            pageViews[pages[pi].id]?.liveUpdate(e)
        }
    }

    private func endLassoMove(at p: CGPoint) {
        guard let start = lassoMoveStart, let sel = lassoSel, let original = lassoMoveOriginal else { return }
        lassoMoveStart = nil
        let d = CGPoint(x: p.x - start.x, y: p.y - start.y)
        overlay.showLassoPreview(nil, frame: .zero)
        // 一次復原整個移動
        registerCompositeUndo(drawing: original, pageIDs: affectedPageIDs(sel))

        var drawing = canvas.drawing
        let base = drawing.strokes.count
        let t = CGAffineTransform(translationX: d.x, y: d.y)
        drawing.strokes.append(contentsOf: lassoMoveStrokes.map { s in
            var s = s
            s.transform = s.transform.concatenating(t)
            return s
        })
        setDrawing(drawing)
        offsetModel(sel, by: d)
        lassoMoveStrokes = []
        lassoMoveOriginal = nil
        lassoMoveElementFrames = [:]
        lassoSel = LassoSelection(strokeIndices: Array(base..<(base + sel.strokeIndices.count)), elements: sel.elements,
                                  highlights: sel.highlights, bounds: sel.bounds.offsetBy(dx: d.x, dy: d.y))
        overlay.showLassoSelection(lassoSel?.bounds)
        presentLassoMenu()
    }

    private func cancelLassoMove() {
        if let original = lassoMoveOriginal { setDrawing(original) }
        for (ref, _) in lassoMoveElementFrames {
            if case let (pi, _)? = locate(ref) { refreshPage(pi) }
        }
        lassoMoveStart = nil
        lassoMoveOriginal = nil
        lassoMoveStrokes = []
        lassoMoveElementFrames = [:]
        clearLassoSelection()
    }

    /// 物件與螢光標示一起平移（不另外登記復原，由呼叫端登記）
    private func offsetModel(_ sel: LassoSelection, by d: CGPoint) {
        for ref in sel.elements {
            guard case let (pi, ei)? = locate(ref) else { continue }
            updatePage(pi, undoable: false) { $0.elements[ei].frame = $0.elements[ei].frame.offsetBy(dx: d.x, dy: d.y) }
        }
        for h in sel.highlights {
            guard let pi = pageIndex(of: h.pageID), let hi = pages[pi].highlights.firstIndex(where: { $0.id == h.id }) else { continue }
            updatePage(pi, undoable: false) { $0.highlights[hi].rects = $0.highlights[hi].rects.map { $0.offsetBy(dx: d.x, dy: d.y) } }
        }
    }

    private func affectedPageIDs(_ sel: LassoSelection) -> [UUID] {
        Array(Set(sel.elements.map(\.pageID) + sel.highlights.map(\.pageID)))
    }

    // MARK: 復原（筆跡＋物件一起）

    func registerCompositeUndo(drawing: PKDrawing, pageIDs: [UUID]) {
        var snaps: [UUID: PageContentSnapshot] = [:]
        for id in pageIDs {
            if let i = pageIndex(of: id) { snaps[id] = PageContentSnapshot(elements: pages[i].elements, highlights: pages[i].highlights) }
        }
        registerCompositeUndo(drawing: drawing, snapshots: snaps)
    }

    private func registerCompositeUndo(drawing: PKDrawing, snapshots: [UUID: PageContentSnapshot]) {
        canvas.undoManager?.registerUndo(withTarget: self) { vc in
            vc.registerCompositeUndo(drawing: vc.canvas.drawing, pageIDs: Array(snapshots.keys))
            vc.setDrawing(drawing)
            for (id, s) in snapshots {
                guard let i = vc.pageIndex(of: id) else { continue }
                vc.session.document.pages[i].elements = s.elements
                vc.session.document.pages[i].highlights = s.highlights
                vc.refreshPage(i)
            }
            vc.clearLassoSelection()
            vc.scheduleSave()
        }
    }

    // MARK: 選單：拷貝、剪下、刪除、複製一份

    func presentLassoMenu() {
        guard let sel = lassoSel else { return }
        let menu = UIMenu(children: [
            UIAction(title: "拷貝", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyLasso() },
            UIAction(title: "剪下", image: UIImage(systemName: "scissors")) { [weak self] _ in
                self?.copyLasso()
                self?.deleteLasso()
            },
            UIAction(title: "複製一份", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateLasso() },
            UIAction(title: "刪除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteLasso() },
        ])
        presentMenu(menu, atDocPoint: CGPoint(x: sel.bounds.midX, y: sel.bounds.minY))
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
                                        bounds: sel.bounds, changeCount: pb.changeCount)
    }

    private func deleteLasso() {
        guard let sel = lassoSel else { return }
        registerCompositeUndo(drawing: canvas.drawing, pageIDs: affectedPageIDs(sel))
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
        clearLassoSelection()
    }

    private func duplicateLasso() {
        copyLasso()
        guard let clip = lassoClipboard else { return }
        pasteLasso(clip, center: CGPoint(x: clip.bounds.midX + 24, y: clip.bounds.midY + 24))
    }

    /// 把套索拷貝的內容貼到 center（文件座標）
    func pasteLasso(_ clip: LassoClipboard, center: CGPoint) {
        let d = CGPoint(x: center.x - clip.bounds.midX, y: center.y - clip.bounds.midY)
        let target = pageIndex(containing: center) ?? nearestPageIndex(to: center)
        guard pages.indices.contains(target) else { return }
        registerCompositeUndo(drawing: canvas.drawing, pageIDs: [pages[target].id])

        var drawing = canvas.drawing
        let base = drawing.strokes.count
        let t = CGAffineTransform(translationX: d.x, y: d.y)
        drawing.strokes.append(contentsOf: clip.strokes.map { s in
            var s = s
            s.transform = s.transform.concatenating(t)
            return s
        })
        setDrawing(drawing)

        let o = contentOrigin(target)
        var newElements: [ElementRef] = []
        var newHighlights: [HighlightRef] = []
        updatePage(target, undoable: false) { page in
            for item in clip.elements {
                var e = item.element
                e.id = UUID()
                e.locked = false
                e.frame.origin = CGPoint(x: item.docFrame.minX + d.x - o.x, y: item.docFrame.minY + d.y - o.y)
                page.elements.append(e)
                newElements.append(ElementRef(pageID: page.id, elementID: e.id))
            }
            for h in clip.highlights {
                let hl = TextHighlight(rects: h.docRects.map { $0.offsetBy(dx: d.x - o.x, dy: d.y - o.y) }, colorHex: h.colorHex)
                page.highlights.append(hl)
                newHighlights.append(HighlightRef(pageID: page.id, id: hl.id))
            }
        }
        if tool != .lasso { setTool(.lasso) }
        lassoSel = LassoSelection(strokeIndices: Array(base..<(base + clip.strokes.count)), elements: newElements,
                                  highlights: newHighlights, bounds: clip.bounds.offsetBy(dx: d.x, dy: d.y))
        overlay.showLassoSelection(lassoSel?.bounds)
        presentLassoMenu()
    }

    // MARK: - 鎖頭

    /// 選取工具：選到的表格旁顯示；套索工具：所有表格旁都顯示
    func lockIconTargets() -> [(ref: ElementRef, point: CGPoint, locked: Bool)] {
        let off = 36 / canvas.zoomScale
        // 表格：右上角外側；圖片：左上角
        func target(_ e: PageElement, _ pi: Int) -> (ref: ElementRef, point: CGPoint, locked: Bool) {
            let r = docFrame(of: e, pageIndex: pi)
            let p = e.isTable ? CGPoint(x: r.maxX + off, y: r.minY - off) : CGPoint(x: r.minX + off * 0.5, y: r.minY + off * 0.5)
            return (ElementRef(pageID: pages[pi].id, elementID: e.id), p, e.locked)
        }
        func lockable(_ e: PageElement) -> Bool { e.isTable || e.isImage }
        if tool == .select, editingTextView == nil, let ref = selected, case let (pi, ei)? = locate(ref),
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
        return []
    }

    func updateLockChrome() {
        overlay.showLockIcons(lockIconTargets().map { ($0.point, $0.locked) })
    }

    func lockIconHit(at p: CGPoint) -> ElementRef? {
        let tol = 20 / canvas.zoomScale
        return lockIconTargets().first { $0.point.distance(to: p) < tol }?.ref
    }

    func toggleLock(_ ref: ElementRef) {
        modifyElement(ref) { $0.locked.toggle() }
        if case let (pi, ei)? = locate(ref) {
            showToast(pages[pi].elements[ei].locked ? "已鎖定：不能移動，也不會被套索圈到" : "已解除鎖定：可以移動，也能被套索圈到")
        }
        clearLassoSelection()
        updateLockChrome()
        if tool == .select { rebuildSubBar() }
    }
}
