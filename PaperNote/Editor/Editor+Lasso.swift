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
        for p in stroke.path.interpolatedPoints(by: .distance(3)) where path.contains(p.location.applying(stroke.transform)) {
            return true
        }
        return false
    }
}

/// 自訂套索圈到的內容：筆跡（canvas.drawing 的索引）、物件、螢光標示
struct LassoSelection {
    var strokeIndices: [Int]
    var elements: [ElementRef]
    var highlights: [HighlightRef]
    var bounds: CGRect
    var ink: [InkRef] = []

    var isEmpty: Bool { strokeIndices.isEmpty && elements.isEmpty && highlights.isEmpty && ink.isEmpty }
    /// 圈到可以改顏色的筆跡
    var hasInk: Bool { !strokeIndices.isEmpty || !ink.isEmpty }
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
            if lassoSelectionHit(p) {
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

    /// p 在圈選範圍內（含一點邊界）：按下去是移動，不是重新圈選
    func lassoSelectionHit(_ p: CGPoint) -> Bool {
        guard let sel = lassoSel else { return false }
        let m = 14 / canvas.zoomScale
        return sel.bounds.insetBy(dx: -m, dy: -m).contains(p)
    }

    func clearLassoSelection() {
        // 剪下、刪除之後選單跟著關掉
        if lassoSel != nil { editMenu.dismissMenu() }
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
        for (i, s) in canvas.drawing.strokes.enumerated() where LassoGeometry.circles(s, path: path, area: area) {
            strokes.append(i)
            bounds = bounds.union(s.renderBounds)
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
        var ink: [InkRef] = []
        for (pi, page) in pages.enumerated() where pageFrames[pi].intersects(area) {
            let io = contentOrigin(pi)
            for s in page.ink {
                let b = InkGeometry.bounds(of: s).offsetBy(dx: io.x, dy: io.y)
                guard b.intersects(area), InkGeometry.circled(s, offset: io, path: path) else { continue }
                ink.append(InkRef(pageID: page.id, id: s.id))
                bounds = bounds.union(b)
            }
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
        let sel = LassoSelection(strokeIndices: strokes, elements: elements, highlights: highlights, bounds: bounds, ink: ink)
        guard !sel.isEmpty else { return }
        lassoSel = sel
        overlay.showLassoSelection(sel.bounds)
        // 不馬上跳選單（會蓋住圈到的東西、沒辦法拖）：點一下選取範圍才打開
        let hintKey = "lasso.tapForMenuHintShown"
        if !UserDefaults.standard.bool(forKey: hintKey) {
            UserDefaults.standard.set(true, forKey: hintKey)
            showToast("拖曳可以移動；點一下選取範圍打開選單")
        }
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
        // 自製筆刷的筆跡也先藏起來，一起放進預覽圖
        let movingInk = inkStrokes(sel.ink)
        setInkHidden(sel.ink)
        if !lassoMoveStrokes.isEmpty || !movingInk.isEmpty {
            let scale = min(3, max(1, canvas.zoomScale * traitCollection.displayScale))
            let pk = lassoMoveStrokes.isEmpty ? nil : PageRenderer.inkImage(PKDrawing(strokes: lassoMoveStrokes), rect: sel.bounds, scale: scale)
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = scale
            fmt.opaque = false
            let img = UIGraphicsImageRenderer(size: sel.bounds.size, format: fmt).image { rc in
                let ctx = rc.cgContext
                ctx.translateBy(x: -sel.bounds.minX, y: -sel.bounds.minY)
                InkRenderer.draw(movingInk, in: ctx)
                pk?.draw(in: sel.bounds)
            }
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
        // 一次復原整個移動（筆跡可能移到別頁，那一頁也要能復原）
        let inkTargets = inkStrokes(sel.ink).map { pages[inkPageIndex(for: InkGeometry.offset($0, by: d))].id }
        registerCompositeUndo(drawing: original, pageIDs: Array(Set(affectedPageIDs(sel) + inkTargets)))
        setInkHidden([])

        var drawing = canvas.drawing
        let base = drawing.strokes.count
        let t = CGAffineTransform(translationX: d.x, y: d.y)
        drawing.strokes.append(contentsOf: lassoMoveStrokes.map { s in
            var s = s
            s.transform = s.transform.concatenating(t)
            return s
        })
        setDrawing(drawing)
        let movedInk = offsetModel(sel, by: d)
        lassoMoveStrokes = []
        lassoMoveOriginal = nil
        lassoMoveElementFrames = [:]
        lassoSel = LassoSelection(strokeIndices: Array(base..<(base + sel.strokeIndices.count)), elements: sel.elements,
                                  highlights: sel.highlights, bounds: sel.bounds.offsetBy(dx: d.x, dy: d.y), ink: movedInk)
        overlay.showLassoSelection(lassoSel?.bounds)
    }

    private func cancelLassoMove() {
        if let original = lassoMoveOriginal { setDrawing(original) }
        setInkHidden([])
        for (ref, _) in lassoMoveElementFrames {
            if case let (pi, _)? = locate(ref) { refreshPage(pi) }
        }
        lassoMoveStart = nil
        lassoMoveOriginal = nil
        lassoMoveStrokes = []
        lassoMoveElementFrames = [:]
        clearLassoSelection()
    }

    /// 物件、螢光標示、自製筆刷的筆跡一起平移（不另外登記復原，由呼叫端登記）；回傳筆跡移動後的位置
    private func offsetModel(_ sel: LassoSelection, by d: CGPoint) -> [InkRef] {
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
            let o = contentOrigin(pi)
            let doc = InkGeometry.offset(s, by: CGPoint(x: o.x + d.x, y: o.y + d.y))
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

    /// 套索移動中先把圈到的筆跡藏起來（空陣列＝全部顯示）
    private func setInkHidden(_ refs: [InkRef]) {
        for (id, v) in pageViews {
            v.inkView.setHidden(Set(refs.filter { $0.pageID == id }.map(\.id)))
        }
    }

    // MARK: 復原（筆跡＋物件一起）

    func registerCompositeUndo(drawing: PKDrawing, pageIDs: [UUID]) {
        var snaps: [UUID: PageContentSnapshot] = [:]
        for id in pageIDs {
            if let i = pageIndex(of: id) { snaps[id] = PageContentSnapshot(pages[i]) }
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
                vc.session.document.pages[i].ink = s.ink
                vc.refreshPage(i)
            }
            vc.clearLassoSelection()
            vc.scheduleSave()
        }
    }

    // MARK: 選單：拷貝、剪下、刪除、複製一份

    func presentLassoMenu() {
        guard let sel = lassoSel else { return }
        var children: [UIMenuElement] = [
            UIAction(title: "拷貝", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyLasso() },
            UIAction(title: "剪下", image: UIImage(systemName: "scissors")) { [weak self] _ in
                self?.copyLasso()
                self?.deleteLasso()
            },
            UIAction(title: "複製一份", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateLasso() },
            UIAction(title: "刪除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteLasso() },
        ]
        // 圈到筆跡：可以直接改顏色
        if sel.hasInk { children.insert(lassoColorMenu(), at: 0) }
        // 圈到電路圖：可以直接回到電路工具編輯
        if let circuit = sel.elements.first(where: { ref in locate(ref).map { pages[$0.0].elements[$0.1].isCircuit } ?? false }) {
            children.insert(UIAction(title: "編輯電路圖", image: UIImage(systemName: "bolt")) { [weak self] _ in
                self?.clearLassoSelection()
                self?.editCircuit(circuit)
            }, at: 0)
        }
        presentMenu(UIMenu(children: children), atDocPoint: CGPoint(x: sel.bounds.midX, y: sel.bounds.minY), avoiding: sel.bounds)
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
        items.append(UIAction(title: "其他顏色…", image: UIImage(systemName: "eyedropper")) { [weak self] _ in self?.presentLassoColorPicker() })
        let grid = UIMenu(title: "", options: .displayInline, children: items)
        grid.preferredElementSize = .small
        return UIMenu(title: "顏色", image: UIImage(systemName: "paintpalette"), children: [grid])
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
        registerCompositeUndo(drawing: canvas.drawing, pageIDs: Array(Set(sel.ink.map(\.pageID))))
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
        let handler = LassoColorPicker { [weak self] color in self?.recolorLasso(color) }
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
        var newInk: [InkRef] = []
        updatePage(target, undoable: false) { page in
            for s in clip.ink {
                var s = InkGeometry.offset(s, by: CGPoint(x: d.x - o.x, y: d.y - o.y))
                s.id = UUID()
                page.ink.append(s)
                newInk.append(InkRef(pageID: page.id, id: s.id))
            }
            for item in clip.elements {
                var e = item.element
                e.id = UUID()
                e.locked = false
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
        if tool != .lasso { setTool(.lasso) }
        lassoSel = LassoSelection(strokeIndices: Array(base..<(base + clip.strokes.count)), elements: newElements,
                                  highlights: newHighlights, bounds: clip.bounds.offsetBy(dx: d.x, dy: d.y), ink: newInk)
        overlay.showLassoSelection(lassoSel?.bounds)
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

/// 自訂顏色選好後套用到套索圈到的筆跡
final class LassoColorPicker: NSObject, UIColorPickerViewControllerDelegate {
    private let apply: (UIColor) -> Void

    init(apply: @escaping (UIColor) -> Void) {
        self.apply = apply
    }

    func colorPickerViewController(_ viewController: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
        if !continuously { apply(color) }
    }
}
