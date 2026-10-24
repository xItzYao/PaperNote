import UIKit

struct IndexedPoint {
    let index: Int
    let point: CGPoint
}

struct TableHandles {
    var plusCols: [IndexedPoint] = []   // 點了在第 index 欄的位置插入一欄
    var plusRows: [IndexedPoint] = []
    var colGrips: [IndexedPoint] = []   // 拖曳調整第 index 條直線
    var rowGrips: [IndexedPoint] = []
}

// MARK: - 表格：＋插入列欄、格線拖拉點

extension NotebookViewController {
    func tableHandles(_ e: PageElement, docRect r: CGRect) -> TableHandles? {
        guard case let .table(t) = e.content, t.size.width > 0, t.size.height > 0 else { return nil }
        let off = 24 / canvas.zoomScale
        let sx = r.width / t.size.width, sy = r.height / t.size.height
        var h = TableHandles()
        // 被合併格整條蓋住的格線不顯示 ＋ 和拖拉點
        h.plusCols = (0...t.cols).filter { t.colLineVisibleAnywhere($0) }
            .map { IndexedPoint(index: $0, point: CGPoint(x: r.minX + t.colX($0) * sx, y: r.minY - off)) }
        h.plusRows = (0...t.rows).filter { t.rowLineVisibleAnywhere($0) }
            .map { IndexedPoint(index: $0, point: CGPoint(x: r.minX - off, y: r.minY + t.rowY($0) * sy)) }
        if !e.locked {
            h.colGrips = (1...t.cols).filter { t.colLineVisibleAnywhere($0) }
                .map { IndexedPoint(index: $0, point: CGPoint(x: r.minX + t.colX($0) * sx, y: r.maxY + off)) }
            h.rowGrips = (1...t.rows).filter { t.rowLineVisibleAnywhere($0) }
                .map { IndexedPoint(index: $0, point: CGPoint(x: r.maxX + off, y: r.minY + t.rowY($0) * sy)) }
            // 右下角是縮放控制點，最後一條直線／橫線的拖拉點仍保留在外側
        }
        return h
    }

    func selectedTableHandles() -> (ref: ElementRef, handles: TableHandles)? {
        guard editingTextView == nil, let ref = selected, case let (pi, ei)? = locate(ref) else { return nil }
        let e = pages[pi].elements[ei]
        guard let h = tableHandles(e, docRect: docFrame(of: e, pageIndex: pi)) else { return nil }
        return (ref, h)
    }

    func updateTableHandlesChrome() {
        if tool == .select, let s = selectedTableHandles() {
            overlay.showTableHandles(plus: (s.handles.plusCols + s.handles.plusRows).map(\.point),
                                     grips: (s.handles.colGrips + s.handles.rowGrips).map(\.point))
        } else {
            overlay.showTableHandles(plus: [], grips: [])
        }
    }

    /// 點到「＋」→ 插入欄或列
    func handleTablePlusTap(at p: CGPoint) -> Bool {
        guard let s = selectedTableHandles() else { return false }
        let tol = 18 / canvas.zoomScale
        if let c = s.handles.plusCols.first(where: { $0.point.distance(to: p) < tol }) {
            modifyTable(s.ref) { $0.insertColumn(at: c.index) }
            return true
        }
        if let r = s.handles.plusRows.first(where: { $0.point.distance(to: p) < tol }) {
            modifyTable(s.ref) { $0.insertRow(at: r.index) }
            return true
        }
        return false
    }

    /// 拖到格線拖拉點 → 調整那條線
    func tableGripTarget(at p: CGPoint) -> DragKind? {
        guard let s = selectedTableHandles() else { return nil }
        let tol = 18 / canvas.zoomScale
        if let c = s.handles.colGrips.first(where: { $0.point.distance(to: p) < tol }) { return .colLine(c.index) }
        if let r = s.handles.rowGrips.first(where: { $0.point.distance(to: p) < tol }) { return .rowLine(r.index) }
        return nil
    }
}

// MARK: - 擴展頁面（8 個控制點）

extension NotebookViewController {
    func pageResizeRects(_ i: Int, insets: PageInsets) -> (full: CGRect, content: CGRect) {
        let co = contentOrigin(i)
        let base = session.baseSize(of: pages[i])
        let content = CGRect(origin: co, size: base)
        let full = CGRect(x: co.x - insets.left, y: co.y - insets.top,
                          width: base.width + insets.left + insets.right,
                          height: base.height + insets.top + insets.bottom)
        return (full, content)
    }

    func pageHandlePoints(_ f: CGRect) -> [CGPoint] {
        [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
         CGPoint(x: f.maxX, y: f.midY), CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.midX, y: f.maxY),
         CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.minX, y: f.midY)]
    }

    func updatePageResizeChrome() {
        guard tool == .pageResize, let i = resizePageIndex, pages.indices.contains(i), pageFrames.indices.contains(i) else {
            overlay.showPageHandles(full: nil, content: nil, handles: [])
            return
        }
        let insets = resizeDrag?.preview ?? pages[i].insets
        let r = pageResizeRects(i, insets: insets)
        overlay.showPageHandles(full: r.full, content: r.content, handles: pageHandlePoints(r.full))
    }

    func pageHandle(at p: CGPoint) -> Int? {
        guard let i = resizePageIndex, pages.indices.contains(i) else { return nil }
        let pts = pageHandlePoints(pageResizeRects(i, insets: pages[i].insets).full)
        let tol = 26 / canvas.zoomScale
        var best: (Int, CGFloat)?
        for (k, pt) in pts.enumerated() {
            let d = pt.distance(to: p)
            if d < tol, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (k, d) }
        }
        return best?.0
    }

    func handlePageResizePan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began:
            guard let i = resizePageIndex, let h = pageHandle(at: p) else { return }
            let ins = pages[i].insets
            resizeDrag = PageResizeDrag(handle: h, start: p, original: ins, preview: ins)
        case .changed:
            guard var d = resizeDrag else { return }
            let dx = p.x - d.start.x, dy = p.y - d.start.y
            let limit: CGFloat = 8000
            var n = d.original
            if [0, 6, 7].contains(d.handle) { n.left = min(limit, max(0, (d.original.left - dx).rounded())) }
            if [2, 3, 4].contains(d.handle) { n.right = min(limit, max(0, (d.original.right + dx).rounded())) }
            if [0, 1, 2].contains(d.handle) { n.top = min(limit, max(0, (d.original.top - dy).rounded())) }
            if [4, 5, 6].contains(d.handle) { n.bottom = min(limit, max(0, (d.original.bottom + dy).rounded())) }
            d.preview = n
            resizeDrag = d
            updatePageResizeChrome()
        case .ended:
            guard let d = resizeDrag, let i = resizePageIndex else { return }
            resizeDrag = nil
            if d.preview != d.original {
                applyInsets(d.preview, pageIndex: i, toAll: false)
            } else {
                updatePageResizeChrome()
            }
        default:
            resizeDrag = nil
            updatePageResizeChrome()
        }
    }
}

// MARK: - 手繪表格

extension NotebookViewController {
    func handleTableDrawPan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        if let target = tableDrawTarget {
            switch g.state {
            case .began:
                tableDraftStart = p
            case .changed:
                if let s = tableDraftStart { overlay.showTableDraft(rect: nil, xs: [], ys: [], live: (s, p)) }
            case .ended:
                if let s = tableDraftStart { applyTableStroke(target, from: s, to: p) }
                tableDraftStart = nil
                updateTableDraftChrome()
            default:
                tableDraftStart = nil
                updateTableDraftChrome()
            }
            return
        }
        switch g.state {
        case .began:
            tableDraftStart = p
        case .changed:
            guard let s = tableDraftStart else { return }
            if let d = tableDraft {
                overlay.showTableDraft(rect: d.rect, xs: d.xs, ys: d.ys, live: straightLine(s, p))
            } else {
                overlay.showTableDraft(rect: rectFrom(s, p), xs: [], ys: [], live: nil)
            }
        case .ended:
            guard let s = tableDraftStart else { return }
            tableDraftStart = nil
            if tableDraft == nil {
                let r = rectFrom(s, p)
                if r.width >= 40, r.height >= 30 {
                    let i = pageIndex(containing: r.center) ?? nearestPageIndex(to: r.center)
                    tableDraft = TableDraft(pageIndex: i, rect: r)
                }
            } else {
                addTableDivider(from: s, to: p)
            }
            updateTableDraftChrome()
        default:
            tableDraftStart = nil
            updateTableDraftChrome()
        }
    }

    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func straightLine(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        if abs(b.x - a.x) >= abs(b.y - a.y) {
            let y = (a.y + b.y) / 2
            return (CGPoint(x: a.x, y: y), CGPoint(x: b.x, y: y))
        }
        let x = (a.x + b.x) / 2
        return (CGPoint(x: x, y: a.y), CGPoint(x: x, y: b.y))
    }

    private func addTableDivider(from a: CGPoint, to b: CGPoint) {
        guard var d = tableDraft else { return }
        let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
        let gap = TableData.minCell
        if dx >= dy * 1.5, dx > 20 {
            let y = (a.y + b.y) / 2
            guard y > d.rect.minY + gap, y < d.rect.maxY - gap, !d.ys.contains(where: { abs($0 - y) < gap }) else { return }
            d.ys.append(y)
        } else if dy >= dx * 1.5, dy > 20 {
            let x = (a.x + b.x) / 2
            guard x > d.rect.minX + gap, x < d.rect.maxX - gap, !d.xs.contains(where: { abs($0 - x) < gap }) else { return }
            d.xs.append(x)
        }
        tableDraft = d
    }

    func updateTableDraftChrome() {
        if tool == .tableDraw, let target = tableDrawTarget, case let (pi, ei)? = locate(target) {
            overlay.showTableDraft(rect: nil, xs: [], ys: [], live: nil)
            overlay.showSelection(docFrame(of: pages[pi].elements[ei], pageIndex: pi), locked: false, handle: nil)
            return
        }
        if tool == .tableDraw, let d = tableDraft {
            overlay.showTableDraft(rect: d.rect, xs: d.xs, ys: d.ys, live: nil)
        } else {
            overlay.showTableDraft(rect: nil, xs: [], ys: [], live: nil)
        }
    }

    func undoTableDivider() {
        guard var d = tableDraft else { return }
        if !d.xs.isEmpty || !d.ys.isEmpty {
            // 移除最後加入的那條（xs、ys 各自依加入順序）
            if d.ys.count >= d.xs.count, !d.ys.isEmpty { d.ys.removeLast() } else if !d.xs.isEmpty { d.xs.removeLast() }
            tableDraft = d
        } else {
            tableDraft = nil
        }
        updateTableDraftChrome()
    }

    func finishTableDraft() {
        guard let d = tableDraft, pages.indices.contains(d.pageIndex) else {
            setTool(.select)
            return
        }
        let xs = [d.rect.minX] + d.xs.sorted() + [d.rect.maxX]
        let ys = [d.rect.minY] + d.ys.sorted() + [d.rect.maxY]
        let widths = zip(xs.dropFirst(), xs).map { $0 - $1 }
        let heights = zip(ys.dropFirst(), ys).map { $0 - $1 }
        let t = TableData(colWidths: widths, rowHeights: heights,
                          cells: Array(repeating: Array(repeating: "", count: widths.count), count: heights.count))
        let o = contentOrigin(d.pageIndex)
        let e = PageElement(frame: CGRect(x: d.rect.minX - o.x, y: d.rect.minY - o.y, width: t.size.width, height: t.size.height),
                            content: .table(t))
        tableDraft = nil
        updatePage(d.pageIndex) { $0.elements.append(e) }
        setTool(.select)
        select(ElementRef(pageID: pages[d.pageIndex].id, elementID: e.id))
    }
}

// MARK: - Apple Pencil 點兩下切換橡皮擦

extension NotebookViewController: UIPencilInteractionDelegate {
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilDoubleTap(at: tap.hoverPose?.location)
    }

    /// Apple Pencil Pro 擠壓 → 在筆尖位置叫出圓形筆盤
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        if paletteOverlay != nil {
            dismissPalette()
            return
        }
        showPaletteLauncher(at: squeeze.hoverPose?.location, open: true)
    }

    // iOS 17.5 以前的系統呼叫這個（17.5 以後只會呼叫上面那個）
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        if #available(iOS 17.5, *) { return }
        handlePencilDoubleTap()
    }

    /// Apple Pencil 筆身點兩下：切換橡皮擦，同時在筆尖旁出現調色盤小圖示（點了才打開）
    private func handlePencilDoubleTap(at hover: CGPoint? = nil) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        // 電路工具：在接線和原本的模式（選取或放置元件）之間切換
        if tool == .circuit {
            if circuitMode == .wire {
                selectCircuitMode(circuitModeBeforeWire)
            } else {
                circuitModeBeforeWire = circuitMode
                selectCircuitMode(.wire)
                showToast("接線（筆身點兩下切回）")
            }
            return
        }
        if tool == .eraser {
            setTool(toolBeforeEraser)
        } else {
            setTool(.eraser)
        }
        if settings.paletteOnDoubleTap { showPaletteLauncher(at: hover) }
    }
}
