import UIKit
import PencilKit
import PDFKit
import PhotosUI

// MARK: - Gestures

extension NotebookViewController: UIGestureRecognizerDelegate {
    func setupGestures() {
        toolPan = UIPanGestureRecognizer(target: self, action: #selector(handleToolPan(_:)))
        toolPan.maximumNumberOfTouches = 1
        toolPan.delegate = self
        canvas.addGestureRecognizer(toolPan)

        doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.delegate = self
        canvas.addGestureRecognizer(doubleTapGesture)

        tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapGesture.delegate = self
        canvas.addGestureRecognizer(tapGesture)

        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.45
        longPressGesture.delegate = self
        canvas.addGestureRecognizer(longPressGesture)

        textLongPress = UILongPressGestureRecognizer(target: self, action: #selector(handleTextLongPress(_:)))
        textLongPress.minimumPressDuration = 0.5
        textLongPress.delegate = self
        canvas.addGestureRecognizer(textLongPress)

        eraserTracker = TouchTracker(target: nil, action: nil)
        eraserTracker.coordinateView = pagesContainer
        eraserTracker.delegate = self
        eraserTracker.onPoint = { [weak self] p in self?.eraseHighlights(at: p) }
        canvas.addGestureRecognizer(eraserTracker)

        // 記住筆尖最後的位置（調色盤小圖示出現在這附近）
        pencilPointTracker = TouchTracker(target: nil, action: nil)
        pencilPointTracker.coordinateView = view
        pencilPointTracker.delegate = self
        pencilPointTracker.onPoint = { [weak self] p in
            self?.lastPencilPoint = p
            self?.lastPencilTime = CACurrentMediaTime()
        }
        pencilPointTracker.onBegan = { [weak self] _ in
            guard let self else { return }
            self.pencilDown = true
            self.holdToShape.pencilTouchedDown()
            // 保險：書寫工具下 PencilKit 的書寫手勢一定要開著
            if self.tool.isDrawing, !self.canvas.drawingGestureRecognizer.isEnabled { self.canvas.drawingGestureRecognizer.isEnabled = true }
        }
        pencilPointTracker.onEnded = { [weak self] in
            self?.pencilDown = false
            self?.lastPencilTime = CACurrentMediaTime()
        }
        canvas.addGestureRecognizer(pencilPointTracker)

        palmBlocker = PalmBlocker(target: nil, action: nil)
        palmBlocker.delegate = self
        palmBlocker.isPalm = { [weak self] t in self?.isPalmTouch(t) ?? false }
        canvas.addGestureRecognizer(palmBlocker)

        holdRecognizer = PencilHoldRecognizer(target: nil, action: nil)
        holdRecognizer.coordinateView = pagesContainer
        holdRecognizer.delegate = self
        holdRecognizer.onHold = { [weak self] pts in self?.holdToShape.hold(pts) }
        holdRecognizer.onMove = { [weak self] p in self?.holdToShape.move(p) }
        holdRecognizer.onEnd = { [weak self] p, cancelled in self?.holdToShape.end(p, cancelled: cancelled) }
        canvas.addGestureRecognizer(holdRecognizer)
    }

    func updateGestureAvailability() {
        toolPan.isEnabled = tool.usesToolPan
        // 筆／橡皮擦／套索模式下，手指點物件也能直接選取（見 shouldReceive）
        tapGesture.isEnabled = true
        doubleTapGesture.isEnabled = tool == .select
        holdRecognizer.isEnabled = tool.isInking && settings.shapeSnap
        holdRecognizer.allowFinger = settings.fingerDrawing
        pencilPointTracker.isEnabled = true
        eraserTracker.isEnabled = tool == .eraser
        eraserTracker.allowFinger = settings.fingerDrawing
        longPressGesture.isEnabled = tool == .select
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === toolPan {
            switch tool {
            case .capture, .textSelect, .tableDraw:
                return true
            case .select:
                return editingTextView == nil && dragTarget(at: g.location(in: pagesContainer)) != nil
            case .pageResize:
                return pageHandle(at: g.location(in: pagesContainer)) != nil
            case .lasso:
                return true
            case .circuit:
                return circuitPanShouldBegin(at: panTouchDownPoint(g))
            default:
                return false
            }
        }
        return true
    }

    /// 這個手指觸碰是不是手掌（寫字時壓在螢幕上的手）
    func isPalmTouch(_ t: UITouch) -> Bool {
        let mode = settings.palmRejection
        guard mode != "off", t.type == .direct else { return false }
        // 只擋很大面積的觸碰（整個手掌）；一般手指平放也不會超過
        if t.majorRadius > 55 { return true }
        let now = CACurrentMediaTime()
        // 筆尖正在接觸螢幕，或剛離開不到 0.3 秒
        // （超過 3 秒沒收到筆尖移動就不算「正在寫字」，避免狀態卡住讓頁面一直沒反應）
        if pencilDown && now - lastPencilTime < 3 { return true }
        // 筆剛離開：只擋面積較大的觸碰（手掌），一般指尖馬上就能捲動頁面
        guard t.majorRadius > 25 else { return false }
        if now - lastPencilTime < 0.3 { return true }
        // 剛寫完 1.5 秒內，筆尖附近下方、寫字那一側的觸碰（手掌常壓的位置）
        guard now - lastPencilTime < 1.5, let pp = lastPencilPoint else { return false }
        let p = t.location(in: view)
        guard p.y > pp.y - 40, p.y < pp.y + 320 else { return false }
        if mode == "left" { return p.x < pp.x + 40 && p.x > pp.x - 320 }
        return p.x > pp.x - 40 && p.x < pp.x + 320
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // 手掌只擋畫布的捲動與縮放，其他手勢（含 PencilKit 書寫）照常
        if g === palmBlocker || other === palmBlocker {
            let o = g === palmBlocker ? other : g
            return !(o === canvas.panGestureRecognizer || o === canvas.pinchGestureRecognizer)
        }
        // 偵測停住的辨識器要和 PencilKit 同時運作
        let passive: [UIGestureRecognizer?] = [holdRecognizer, eraserTracker, pencilPointTracker]
        return passive.contains { $0 === g || $0 === other }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        g === tapGesture && other === doubleTapGesture && tool == .select
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g === toolPan && other === canvas.panGestureRecognizer && tool.panYieldsToScroll
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 手掌的觸碰不觸發點選、長按、拖曳物件
        if g !== palmBlocker, touch.type == .direct, isPalmTouch(touch) { return false }
        // 編輯文字時，點文字框內部交給 UITextView
        if let tv = editingTextView, touch.view?.isDescendant(of: tv) == true { return false }
        if g === textLongPress {
            // 手指長按：剪貼簿有東西就能貼上；PDF 頁面上也可以選字（選取工具有自己的長按選單）
            // 套索工具 Pencil 長按也可以（長按圈選範圍內則打開套索選單）
            guard tool != .select, !(settings.fingerDrawing && tool.isDrawing) else { return false }
            guard touch.type == .direct || tool == .lasso else { return false }
            if tool == .lasso, let sel = lassoSel, sel.bounds.insetBy(dx: -10, dy: -10).contains(touch.location(in: pagesContainer)) { return true }
            guard let i = pageIndex(containing: touch.location(in: pagesContainer)) else { return false }
            return clipboardHasContent || session.pdfPage(for: pages[i]) != nil
        }
        // 截圖、PDF 文字、手繪表格、套索：沒開「用手指書寫」時只接受 Pencil，手指只用來捲動
        if g === toolPan, tool.drawsWithPan {
            return touch.type == .pencil || settings.fingerDrawing
        }
        // 套索模式下 Pencil 或手指點鎖頭都可以
        if g === tapGesture, tool == .lasso, lockIconHit(at: touch.location(in: pagesContainer)) != nil { return true }
        if g === tapGesture, tool.isDrawing {
            // 只有手指點在表格／圖片／文字框上才接手，其餘交給 PencilKit
            guard touch.type == .direct, !settings.fingerDrawing else { return false }
            return hitElement(at: touch.location(in: pagesContainer)) != nil
        }
        return true
    }

    /// 拖曳手勢要移動一小段才會開始，這裡扣掉已移動的距離，得到筆尖剛碰到的位置
    func panTouchDownPoint(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: pagesContainer)
        guard let pan = g as? UIPanGestureRecognizer else { return p }
        let t = pan.translation(in: pagesContainer)
        return CGPoint(x: p.x - t.x, y: p.y - t.y)
    }

    @objc func handleToolPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: pagesContainer)
        switch tool {
        case .capture: handleCapturePan(g, p)
        case .textSelect: handleTextPan(g, p)
        case .select: handleElementPan(g, p)
        case .pageResize: handlePageResizePan(g, p)
        case .lasso: handleLassoPan(g, p)
        case .tableDraw: handleTableDrawPan(g, p)
        case .circuit: handleCircuitPan(g, p)
        default: break
        }
    }

    @objc func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: pagesContainer)
        if editingTextView != nil {
            endTextEditing()
            return
        }
        switch tool {
        case .lasso:
            if let ref = lockIconHit(at: p) {
                toggleLock(ref)
            } else if let sel = lassoSel, sel.bounds.insetBy(dx: -10, dy: -10).contains(p) {
                presentLassoMenu()
            } else {
                clearLassoSelection()
            }
        case .pen, .highlighter, .eraser:
            if let hit = hitElement(at: p) {
                setTool(.select)
                select(hit)
                if case let (pi, ei)? = locate(hit), pages[pi].elements[ei].isTable { updateCellSelection(from: p, to: p) }
            }
        case .select:
            if let del = tableDeleteHandlePoint(), p.distance(to: del) < 20 / canvas.zoomScale, let s = selectedTable() {
                deleteElement(s.ref)
                showToast("已刪除表格（可以按復原）")
                return
            }
            if let ref = lockIconHit(at: p) {
                toggleLock(ref)
                return
            }
            if handleTablePlusTap(at: p) { return }
            if let hit = hitElement(at: p) {
                if case let (pi, ei)? = locate(hit), pages[pi].elements[ei].isTable {
                    if hit != selected { select(hit) }
                    updateCellSelection(from: p, to: p)
                } else if hit == selected {
                    presentMenu(elementMenu(hit, at: p), atDocPoint: p)
                } else {
                    select(hit)
                }
            } else {
                select(nil)
            }
        case .textSelect:
            tapText(at: p)
        case .capture:
            clearCapture()
        case .pageResize:
            if let i = pageIndex(containing: p) {
                resizePageIndex = i
                updatePageResizeChrome()
            }
        case .tableDraw:
            break
        case .circuit:
            handleCircuitTap(at: p)
        }
    }

    @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard tool == .select else { return }
        let p = g.location(in: pagesContainer)
        guard let hit = hitElement(at: p), case let (pi, ei)? = locate(hit) else { return }
        select(hit)
        let e = pages[pi].elements[ei]
        switch e.content {
        case let .table(t):
            let local = p - contentOrigin(pi) - e.frame.origin
            if let cell = t.cell(at: local) { beginTextEditing(hit, cell: cell) }
        case .text:
            beginTextEditing(hit, cell: nil)
        case .image:
            presentMenu(elementMenu(hit, at: p), atDocPoint: p)
        case .circuit:
            editCircuit(hit)
        }
    }

    /// 切到電路工具編輯這個電路圖
    func editCircuit(_ ref: ElementRef) {
        setTool(.circuit)
        circuitTarget = ref
        updateCircuitChrome()
    }

    /// 筆模式下手指長按 PDF 文字 → 選取單字並顯示翻譯選單
    @objc func handleTextLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: pagesContainer)
        if tool == .lasso, let sel = lassoSel, sel.bounds.insetBy(dx: -10, dy: -10).contains(p) {
            presentLassoMenu()
            return
        }
        let onPDF = pageIndex(containing: p).map { session.pdfPage(for: pages[$0]) != nil } ?? false
        guard clipboardHasContent else {
            if onPDF {
                setTool(.textSelect)
                tapText(at: p)
            }
            return
        }
        var items: [UIMenuElement] = [
            UIAction(title: "貼上", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.pasteFromClipboard(at: p) },
        ]
        if onPDF {
            items.append(UIAction(title: "選取文字", image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in
                self?.setTool(.textSelect)
                self?.tapText(at: p)
            })
        }
        presentMenu(UIMenu(children: items), atDocPoint: p)
    }

    /// 剪貼簿裡有可以貼上的東西（截圖、圖片、文字、套索或物件拷貝）
    var clipboardHasContent: Bool {
        let pb = UIPasteboard.general
        if let c = lassoClipboard, c.changeCount == pb.changeCount { return true }
        if let c = clipboardElement, c.changeCount == pb.changeCount { return true }
        return pb.hasImages || pb.hasStrings
    }

    @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, tool == .select else { return }
        endTextEditing()
        let p = g.location(in: pagesContainer)
        if let hit = hitElement(at: p) {
            select(hit)
            presentMenu(elementMenu(hit, at: p), atDocPoint: p)
        } else {
            select(nil)
            presentMenu(emptyAreaMenu(at: p), atDocPoint: p)
        }
    }

    func presentMenu(_ menu: UIMenu, atDocPoint p: CGPoint) {
        pendingMenu = menu
        let pt = pagesContainer.convert(p, to: canvas)
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: pt))
    }

    func docRectInView(_ r: CGRect) -> CGRect { pagesContainer.convert(r, to: view) }
}

extension NotebookViewController: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        pendingMenu
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: UIEditMenuInteractionAnimating) {
        if tool == .capture {
            animator.addCompletion { [weak self] in self?.clearCapture() }
        }
    }
}

// MARK: - Elements (tables, text boxes, images)

extension NotebookViewController: UITextViewDelegate, PHPickerViewControllerDelegate {
    func locate(_ ref: ElementRef) -> (Int, Int)? {
        guard let pi = pageIndex(of: ref.pageID),
              let ei = pages[pi].elements.firstIndex(where: { $0.id == ref.elementID }) else { return nil }
        return (pi, ei)
    }

    func docFrame(of e: PageElement, pageIndex pi: Int) -> CGRect {
        let o = contentOrigin(pi)
        return e.frame.offsetBy(dx: o.x, dy: o.y)
    }

    func hitElement(at p: CGPoint) -> ElementRef? {
        guard let pi = pageIndex(containing: p) ?? Optional(nearestPageIndex(to: p)), pages.indices.contains(pi) else { return nil }
        let tol = 6 / canvas.zoomScale
        // 已選取的優先（方便選取被蓋住的物件後操作）
        if let sel = selected, case let (spi, sei)? = locate(sel),
           docFrame(of: pages[spi].elements[sei], pageIndex: spi).insetBy(dx: -tol, dy: -tol).contains(p) {
            return sel
        }
        for e in pages[pi].elements.reversed() where docFrame(of: e, pageIndex: pi).insetBy(dx: -tol, dy: -tol).contains(p) {
            return ElementRef(pageID: pages[pi].id, elementID: e.id)
        }
        return nil
    }

    func select(_ ref: ElementRef?) {
        let changed = ref != selected
        selected = ref
        if changed { tableCellSel = nil }
        updateSelectionChrome()
        if changed && tool == .select { rebuildSubBar() }
    }

    func updateSelectionChrome() {
        defer {
            updateTableHandlesChrome()
            updateTableCellChrome()
            updateLockChrome()
            updateCircuitChrome()
        }
        guard let ref = selected, case let (pi, ei)? = locate(ref) else {
            overlay.showSelection(nil, locked: false, handle: nil)
            return
        }
        let e = pages[pi].elements[ei]
        let r = docFrame(of: e, pageIndex: pi)
        overlay.showSelection(r, locked: e.locked, handle: e.locked ? nil : CGPoint(x: r.maxX, y: r.maxY))
    }

    func dragTarget(at p: CGPoint) -> (ElementRef, DragKind)? {
        guard let ref = selected, case let (pi, ei)? = locate(ref) else { return nil }
        let e = pages[pi].elements[ei]
        let r = docFrame(of: e, pageIndex: pi)
        let tol = 16 / canvas.zoomScale
        if case let .table(t) = e.content, t.size.width > 0, t.size.height > 0 {
            if !e.locked {
                if p.distance(to: CGPoint(x: r.maxX, y: r.maxY)) < tol * 1.5 { return (ref, .resize) }
                if let grip = tableGripTarget(at: p) { return (ref, grip) }
                if let m = tableMoveHandlePoint(), p.distance(to: m) < tol * 1.4 { return (ref, .move) }
                // 外框邊緣也能拖動整個表格
                let outer = r.insetBy(dx: -tol, dy: -tol), innerArea = r.insetBy(dx: tol * 0.6, dy: tol * 0.6)
                if outer.contains(p) && !innerArea.contains(p) { return (ref, .move) }
                // 內部格線（容許範圍較小，避免和選取儲存格衝突）
                let lineTol = 7 / canvas.zoomScale
                let sx = r.width / t.size.width, sy = r.height / t.size.height
                // 只認看得到的那一段格線（被合併格蓋住的不算）
                let atRow = t.rowIndex(at: (p.y - r.minY) / sy) ?? 0
                let atCol = t.colIndex(at: (p.x - r.minX) / sx) ?? 0
                for c in 1..<max(t.cols, 1) where abs(p.x - (r.minX + t.colX(c) * sx)) < lineTol && p.y > r.minY && p.y < r.maxY
                    && t.isColLineVisible(c, atRow: atRow) {
                    return (ref, .colLine(c))
                }
                for row in 1..<max(t.rows, 1) where abs(p.y - (r.minY + t.rowY(row) * sy)) < lineTol && p.x > r.minX && p.x < r.maxX
                    && t.isRowLineVisible(row, atColumn: atCol) {
                    return (ref, .rowLine(row))
                }
            }
            // 在表格裡拖曳 → 選取多個儲存格
            if r.contains(p) { return (ref, .cells) }
            return nil
        }
        guard !e.locked else { return nil }
        if !e.isCircuit, p.distance(to: CGPoint(x: r.maxX, y: r.maxY)) < tol * 1.5 { return (ref, .resize) }
        guard r.insetBy(dx: -tol, dy: -tol).contains(p) else { return nil }
        return (ref, .move)
    }

    func handleElementPan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began:
            guard case let (ref, kind)? = dragTarget(at: p), case let (pi, ei)? = locate(ref) else { return }
            dragState = DragState(ref: ref, kind: kind, start: p, original: pages[pi].elements[ei])
        case .changed:
            guard let d = dragState, case let (pi, ei)? = locate(d.ref) else { return }
            if case .cells = d.kind {
                updateCellSelection(from: d.start, to: p)
                return
            }
            let e = draggedElement(d, to: p)
            session.document.pages[pi].elements[ei] = e
            pageViews[pages[pi].id]?.liveUpdate(e)
            updateSelectionChrome()
        case .ended:
            if let d = dragState, case .cells = d.kind {
                updateCellSelection(from: d.start, to: p)
                dragState = nil
                return
            }
            finishDrag(at: p)
        default:
            if let d = dragState, case let (pi, ei)? = locate(d.ref) {
                session.document.pages[pi].elements[ei] = d.original
                pageViews[pages[pi].id]?.liveUpdate(d.original)
            }
            dragState = nil
            updateSelectionChrome()
        }
    }

    private func draggedElement(_ d: DragState, to p: CGPoint) -> PageElement {
        let dx = p.x - d.start.x, dy = p.y - d.start.y
        var e = d.original
        let o = d.original.frame
        let minCell = TableData.minCell
        switch d.kind {
        case .cells:
            break
        case .move:
            e.frame.origin = CGPoint(x: o.minX + dx, y: o.minY + dy)
            // 電路圖整個移動時也對齊頁面格點，才能和其他電路圖接得上
            e.snapCircuitToGrid()
        case .resize:
            switch e.content {
            case .image:
                let w = max(30, o.width + dx)
                e.frame.size = CGSize(width: w, height: w * o.height / max(o.width, 1))
            case .text:
                e.frame.size = CGSize(width: max(40, o.width + dx), height: max(28, o.height + dy))
            case var .table(t):
                t.scale(to: CGSize(width: o.width + dx, height: o.height + dy))
                e.content = .table(t)
                e.frame.size = t.size
            case .circuit:
                break
            }
        case let .colLine(c):
            if case var .table(t) = e.content {
                let k = c - 1
                if c < t.cols {
                    let total = t.colWidths[k] + t.colWidths[k + 1]
                    let left = min(max(t.colWidths[k] + dx, minCell), total - minCell)
                    t.colWidths[k] = left
                    t.colWidths[k + 1] = total - left
                } else {
                    t.colWidths[k] = max(minCell, t.colWidths[k] + dx)
                }
                e.content = .table(t)
                e.frame.size = t.size
            }
        case let .rowLine(r):
            if case var .table(t) = e.content {
                let k = r - 1
                if r < t.rows {
                    let total = t.rowHeights[k] + t.rowHeights[k + 1]
                    let top = min(max(t.rowHeights[k] + dy, minCell), total - minCell)
                    t.rowHeights[k] = top
                    t.rowHeights[k + 1] = total - top
                } else {
                    t.rowHeights[k] = max(minCell, t.rowHeights[k] + dy)
                }
                e.content = .table(t)
                e.frame.size = t.size
            }
        }
        return e
    }

    private func finishDrag(at p: CGPoint) {
        guard let d = dragState, case let (pi, ei)? = locate(d.ref) else { dragState = nil; return }
        dragState = nil
        var e = draggedElement(d, to: p)
        session.document.pages[pi].elements[ei] = d.original   // 還原後再用 updatePage 正式提交（才能復原）

        let fromFrame = docFrame(of: d.original, pageIndex: pi)
        let toFrame = docFrame(of: e, pageIndex: pi)
        var target = pi
        if case .move = d.kind, let j = pageIndex(containing: toFrame.center), j != pi { target = j }

        // 表格移動時，格子裡的手寫字一起移動
        if case .move = d.kind, e.isTable {
            moveStrokes(inside: fromFrame, by: CGPoint(x: toFrame.minX - fromFrame.minX, y: toFrame.minY - fromFrame.minY))
        }

        if target == pi {
            updatePage(pi) { $0.elements[ei] = e }
        } else {
            let no = contentOrigin(target)
            e.frame.origin = CGPoint(x: toFrame.minX - no.x, y: toFrame.minY - no.y)
            e.snapCircuitToGrid()
            let moved = e
            updatePage(pi) { $0.elements.removeAll { $0.id == moved.id } }
            updatePage(target) { $0.elements.append(moved) }
            selected = ElementRef(pageID: pages[target].id, elementID: e.id)
        }
        updateSelectionChrome()
    }

    func moveStrokes(inside rect: CGRect, by delta: CGPoint) {
        guard delta != .zero else { return }
        var d = canvas.drawing
        var changed = false
        let area = rect.insetBy(dx: -2, dy: -2)
        for i in d.strokes.indices where area.contains(d.strokes[i].renderBounds) {
            d.strokes[i].transform = d.strokes[i].transform.concatenating(CGAffineTransform(translationX: delta.x, y: delta.y))
            changed = true
        }
        if changed { setDrawing(d) }
    }

    // MARK: Menus

    func elementMenu(_ ref: ElementRef, at p: CGPoint) -> UIMenu {
        guard case let (pi, ei)? = locate(ref) else { return UIMenu() }
        let e = pages[pi].elements[ei]
        var items: [UIMenuElement] = []
        items.append(UIAction(title: e.locked ? "解除固定" : "固定位置",
                              image: UIImage(systemName: e.locked ? "lock.open" : "lock")) { [weak self] _ in
            self?.modifyElement(ref) { $0.locked.toggle() }
        })
        switch e.content {
        case let .table(t):
            let local = p - contentOrigin(pi) - e.frame.origin
            if let cell = t.cell(at: local) {
                items.append(UIAction(title: "編輯文字", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                    self?.beginTextEditing(ref, cell: cell)
                })
                items.append(UIMenu(title: "列與欄", image: UIImage(systemName: "tablecells"), children: [
                    UIAction(title: "在上方插入列") { [weak self] _ in self?.modifyTable(ref) { $0.insertRow(at: cell.row) } },
                    UIAction(title: "在下方插入列") { [weak self] _ in self?.modifyTable(ref) { $0.insertRow(at: cell.row + 1) } },
                    UIAction(title: "在左側插入欄") { [weak self] _ in self?.modifyTable(ref) { $0.insertColumn(at: cell.col) } },
                    UIAction(title: "在右側插入欄") { [weak self] _ in self?.modifyTable(ref) { $0.insertColumn(at: cell.col + 1) } },
                    UIAction(title: "刪除此列", attributes: t.rows > 1 ? [] : .disabled) { [weak self] _ in
                        self?.modifyTable(ref) { $0.removeRow(cell.row) }
                    },
                    UIAction(title: "刪除此欄", attributes: t.cols > 1 ? [] : .disabled) { [weak self] _ in
                        self?.modifyTable(ref) { $0.removeColumn(cell.col) }
                    },
                ]))
            }
            items.append(UIMenu(title: "格線", image: UIImage(systemName: "paintbrush"), children: [
                UIAction(title: "黑色") { [weak self] _ in self?.modifyTable(ref) { $0.lineColorHex = "#333333FF" } },
                UIAction(title: "灰色") { [weak self] _ in self?.modifyTable(ref) { $0.lineColorHex = "#9E9E9EFF" } },
                UIAction(title: "藍色") { [weak self] _ in self?.modifyTable(ref) { $0.lineColorHex = "#1E5BD8FF" } },
                UIAction(title: "加粗") { [weak self] _ in self?.modifyTable(ref) { $0.lineWidth = min($0.lineWidth + 0.5, 4) } },
                UIAction(title: "變細") { [weak self] _ in self?.modifyTable(ref) { $0.lineWidth = max($0.lineWidth - 0.5, 0.5) } },
            ]))
        case .text:
            items.append(UIAction(title: "編輯文字", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                self?.beginTextEditing(ref, cell: nil)
            })
            items.append(UIMenu(title: "樣式", image: UIImage(systemName: "textformat.size"), children: [
                UIAction(title: "字放大") { [weak self] _ in self?.modifyTextBox(ref) { $0.fontSize = min($0.fontSize + 2, 72) } },
                UIAction(title: "字縮小") { [weak self] _ in self?.modifyTextBox(ref) { $0.fontSize = max($0.fontSize - 2, 8) } },
                UIAction(title: "無底色") { [weak self] _ in self?.modifyTextBox(ref) { $0.backgroundHex = nil } },
                UIAction(title: "黃色便利貼") { [weak self] _ in self?.modifyTextBox(ref) { $0.backgroundHex = "#FFF59DFF" } },
                UIAction(title: "藍色便利貼") { [weak self] _ in self?.modifyTextBox(ref) { $0.backgroundHex = "#BBDEFBFF" } },
                UIAction(title: "紅字") { [weak self] _ in self?.modifyTextBox(ref) { $0.colorHex = "#D32F2FFF" } },
                UIAction(title: "黑字") { [weak self] _ in self?.modifyTextBox(ref) { $0.colorHex = "#1A1A1AFF" } },
            ]))
        case let .image(d):
            items.append(UIAction(title: "釘選在畫面上", image: UIImage(systemName: "pin")) { [weak self] _ in
                guard let self, let img = self.session.image(named: d.file) else { return }
                self.pinOverlay.addPin(image: img, near: self.docRectInView(self.docFrame(of: e, pageIndex: pi)))
            })
        case .circuit:
            items.append(UIAction(title: "編輯電路", image: UIImage(systemName: "bolt")) { [weak self] _ in
                self?.editCircuit(ref)
            })
        }
        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "拷貝", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyElement(ref) },
            UIAction(title: "複製一份", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateElement(ref) },
            UIAction(title: "刪除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteElement(ref) },
        ]))
        return UIMenu(children: items)
    }

    func emptyAreaMenu(at p: CGPoint) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "貼上", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.pasteFromClipboard(at: p) },
            UIAction(title: "插入表格…", image: UIImage(systemName: "tablecells")) { [weak self] _ in self?.promptInsertTable(at: p) },
            UIAction(title: "插入文字框", image: UIImage(systemName: "character.textbox")) { [weak self] _ in self?.insertTextBox(at: p) },
        ])
    }

    func modifyElement(_ ref: ElementRef, _ change: (inout PageElement) -> Void) {
        guard case let (pi, ei)? = locate(ref) else { return }
        updatePage(pi) { change(&$0.elements[ei]) }
    }

    func modifyTable(_ ref: ElementRef, _ change: @escaping (inout TableData) -> Void) {
        modifyElement(ref) { e in
            guard case var .table(t) = e.content else { return }
            change(&t)
            t.normalizeCells()
            e.content = .table(t)
            e.frame.size = t.size
        }
    }

    func modifyTextBox(_ ref: ElementRef, _ change: @escaping (inout TextBoxData) -> Void) {
        modifyElement(ref) { e in
            guard case var .text(t) = e.content else { return }
            change(&t)
            e.content = .text(t)
            e.frame.size.height = max(e.frame.height, ElementRenderer.textHeight(t, width: e.frame.width))
        }
    }

    func copyElement(_ ref: ElementRef) {
        guard case let (pi, ei)? = locate(ref) else { return }
        let e = pages[pi].elements[ei]
        let pb = UIPasteboard.general
        switch e.content {
        case let .image(d):
            if let img = session.image(named: d.file) { pb.image = img }
        case let .text(t):
            pb.string = t.text
        case let .table(t):
            pb.string = t.cells.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .circuit:
            if let img = renderRegion(UIBezierPath(rect: docFrame(of: e, pageIndex: pi))) { pb.image = img }
        }
        clipboardElement = (e, pb.changeCount)
    }

    func duplicateElement(_ ref: ElementRef) {
        guard case let (pi, ei)? = locate(ref) else { return }
        var e = pages[pi].elements[ei]
        e.id = UUID()
        e.locked = false
        e.frame = e.frame.offsetBy(dx: 24, dy: 24)
        e.snapCircuitToGrid()
        let copy = e
        updatePage(pi) { $0.elements.append(copy) }
        select(ElementRef(pageID: pages[pi].id, elementID: copy.id))
    }

    func deleteElement(_ ref: ElementRef) {
        guard case let (pi, _)? = locate(ref) else { return }
        updatePage(pi) { $0.elements.removeAll { $0.id == ref.elementID } }
        if selected == ref { select(nil) }
    }

    // MARK: Insert

    /// 在文件座標 p（或目前畫面中央）插入物件
    func insertElement(_ content: ElementContent, size: CGSize, at p: CGPoint?) -> ElementRef? {
        guard !pages.isEmpty else { return nil }
        let point: CGPoint
        let pi: Int
        if let p {
            point = p
            pi = pageIndex(containing: p) ?? nearestPageIndex(to: p)
        } else {
            let r = visibleDocRect()
            point = CGPoint(x: r.midX, y: r.midY)
            pi = currentPageIndex
        }
        let page = pages[pi]
        let o = contentOrigin(pi)
        let full = CGRect(x: -page.insets.left, y: -page.insets.top,
                          width: pageFrames[pi].width, height: pageFrames[pi].height)
        var c = CGPoint(x: point.x - o.x, y: point.y - o.y)
        c.x = min(max(c.x, full.minX + size.width / 2), max(full.minX + size.width / 2, full.maxX - size.width / 2))
        c.y = min(max(c.y, full.minY + size.height / 2), max(full.minY + size.height / 2, full.maxY - size.height / 2))
        let e = PageElement(frame: CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height),
                            content: content)
        updatePage(pi) { $0.elements.append(e) }
        if tool != .select { setTool(.select) }
        let ref = ElementRef(pageID: page.id, elementID: e.id)
        select(ref)
        return ref
    }

    func promptInsertTable(at p: CGPoint? = nil) {
        let a = UIAlertController(title: "插入表格", message: "輸入列數與欄數", preferredStyle: .alert)
        a.addTextField { tf in tf.placeholder = "列數"; tf.text = "3"; tf.keyboardType = .numberPad }
        a.addTextField { tf in tf.placeholder = "欄數"; tf.text = "3"; tf.keyboardType = .numberPad }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "插入", style: .default) { [weak self, weak a] _ in
            guard let self else { return }
            let rows = min(max(Int(a?.textFields?[0].text ?? "") ?? 3, 1), 40)
            let cols = min(max(Int(a?.textFields?[1].text ?? "") ?? 3, 1), 20)
            let pageW = self.session.baseSize(of: self.pages[self.currentPageIndex]).width
            let cellW = min(140, max(40, (pageW * 0.85) / CGFloat(cols)))
            let t = TableData.make(rows: rows, cols: cols, cellWidth: cellW.rounded(), cellHeight: 44)
            _ = self.insertElement(.table(t), size: t.size, at: p)
        })
        present(a, animated: true)
    }

    func insertTextBox(at p: CGPoint?, text: String = "") {
        var t = TextBoxData(text: text)
        let width: CGFloat = 260
        t.text = text
        let h = max(44, ElementRenderer.textHeight(t, width: width))
        if let ref = insertElement(.text(t), size: CGSize(width: width, height: h), at: p), text.isEmpty {
            beginTextEditing(ref, cell: nil)
        }
    }

    func insertImage(_ image: UIImage, jpeg: Bool, at p: CGPoint?) {
        let img = image.downscaled(maxPixel: 2400)
        guard let file = session.saveImage(img, jpeg: jpeg) else { return }
        let base = session.baseSize(of: pages[currentPageIndex])
        var size = img.size
        let s = min(1, base.width * 0.7 / max(size.width, 1), base.height * 0.6 / max(size.height, 1))
        size = CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
        _ = insertElement(.image(ImageData(file: file)), size: size, at: p)
    }

    func pasteFromClipboard(at p: CGPoint?) {
        let pb = UIPasteboard.general
        if let clip = lassoClipboard, clip.changeCount == pb.changeCount {
            let r = visibleDocRect()
            pasteLasso(clip, center: p ?? CGPoint(x: r.midX, y: r.midY))
            return
        }
        if let clip = clipboardElement, clip.changeCount == pb.changeCount {
            var e = clip.element
            e.id = UUID()
            e.locked = false
            _ = insertElement(e.content, size: e.frame.size, at: p)
            return
        }
        if let img = pb.image {
            insertImage(img, jpeg: false, at: p)
        } else if let s = pb.string, !s.isEmpty {
            insertTextBox(at: p, text: s)
        } else {
            showMessage("剪貼簿是空的")
        }
    }

    func presentPhotoPicker() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 5
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for r in results where r.itemProvider.canLoadObject(ofClass: UIImage.self) {
            r.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                guard let img = obj as? UIImage else { return }
                DispatchQueue.main.async { self?.insertImage(img, jpeg: true, at: nil) }
            }
        }
    }

    // MARK: Text editing

    func beginTextEditing(_ ref: ElementRef, cell: (row: Int, col: Int)?) {
        endTextEditing()
        guard case let (pi, ei)? = locate(ref) else { return }
        let e = pages[pi].elements[ei]
        var rect = docFrame(of: e, pageIndex: pi)
        var text = ""
        var fontSize: CGFloat = 16
        switch e.content {
        case let .table(t):
            guard let c = cell, c.row < t.rows, c.col < t.cols else { return }
            let cr = t.cellRect(row: c.row, col: c.col)
            rect = CGRect(x: rect.minX + cr.minX, y: rect.minY + cr.minY, width: cr.width, height: max(cr.height, 60))
            text = t.text(row: c.row, col: c.col)
            fontSize = t.fontSize
        case let .text(t):
            text = t.text
            fontSize = t.fontSize
            rect.size.height = max(rect.height, 80)
        case .image, .circuit:
            return
        }
        let z = canvas.zoomScale
        let tv = UITextView(frame: pagesContainer.convert(rect, to: canvas))
        tv.font = .systemFont(ofSize: fontSize * z)
        tv.text = text
        tv.backgroundColor = UIColor.white.withAlphaComponent(0.97)
        tv.layer.borderColor = UIColor.systemBlue.cgColor
        tv.layer.borderWidth = 1.5
        tv.layer.cornerRadius = 4
        tv.textContainerInset = UIEdgeInsets(top: 4 * z, left: 2 * z, bottom: 4 * z, right: 2 * z)
        tv.delegate = self
        canvas.addSubview(tv)
        editingTextView = tv
        editingTarget = (ref, cell)
        tv.becomeFirstResponder()
    }

    func endTextEditing() {
        guard let tv = editingTextView, let target = editingTarget else { return }
        editingTextView = nil
        editingTarget = nil
        let text = tv.text ?? ""
        tv.resignFirstResponder()
        tv.removeFromSuperview()
        guard case let (pi, ei)? = locate(target.ref) else { return }
        if case .text = pages[pi].elements[ei].content, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteElement(target.ref)
            return
        }
        updatePage(pi) { page in
            var e = page.elements[ei]
            switch e.content {
            case var .table(t):
                if let c = target.cell, c.row < t.rows, c.col < t.cols { t.setText(text, row: c.row, col: c.col) }
                e.content = .table(t)
            case var .text(t):
                t.text = text
                e.content = .text(t)
                e.frame.size.height = max(44, ElementRenderer.textHeight(t, width: e.frame.width))
            case .image, .circuit:
                break
            }
            page.elements[ei] = e
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if textView === editingTextView { endTextEditing() }
    }
}

// MARK: - Capture (截圖)

extension NotebookViewController {
    func handleCapturePan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began:
            capturePoints = [p]
        case .changed:
            capturePoints.append(p)
            overlay.showCapture(currentCapturePath())
        case .ended:
            capturePoints.append(p)
            finishCapture(currentCapturePath())
        default:
            clearCapture()
        }
    }

    func currentCapturePath() -> UIBezierPath? {
        guard let first = capturePoints.first, let last = capturePoints.last else { return nil }
        if settings.captureFreeform {
            let path = UIBezierPath()
            path.move(to: first)
            for pt in capturePoints.dropFirst() { path.addLine(to: pt) }
            path.close()
            return path
        }
        return UIBezierPath(rect: CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                         width: abs(last.x - first.x), height: abs(last.y - first.y)))
    }

    func clearCapture() {
        capturePoints = []
        overlay.showCapture(nil)
    }

    private func finishCapture(_ path: UIBezierPath?) {
        guard let path, path.bounds.width > 8, path.bounds.height > 8, let img = renderRegion(path) else {
            clearCapture()
            return
        }
        overlay.showCapture(path)
        let rect = path.bounds
        let viewRect = docRectInView(rect)
        let menu = UIMenu(children: [
            UIAction(title: "釘選在畫面上", image: UIImage(systemName: "pin")) { [weak self] _ in
                self?.pinOverlay.addPin(image: img, near: viewRect)
            },
            UIAction(title: "拷貝", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.image = img
            },
            UIAction(title: "翻譯文字", image: UIImage(systemName: "translate")) { [weak self] _ in
                TextServices.recognizeText(in: img) { text in
                    guard let self else { return }
                    if text.isEmpty { self.showMessage("沒有辨識到文字"); return }
                    TextServices.translate(text, from: self, anchor: viewRect)
                }
            },
            UIAction(title: "拷貝文字", image: UIImage(systemName: "text.viewfinder")) { [weak self] _ in
                TextServices.recognizeText(in: img) { text in
                    if text.isEmpty { self?.showMessage("沒有辨識到文字"); return }
                    UIPasteboard.general.string = text
                }
            },
            UIAction(title: "存到照片", image: UIImage(systemName: "photo.badge.arrow.down")) { _ in
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            },
            UIAction(title: "分享…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                let vc = UIActivityViewController(activityItems: [img], applicationActivities: nil)
                vc.popoverPresentationController?.sourceView = self.view
                vc.popoverPresentationController?.sourceRect = viewRect
                self.present(vc, animated: true)
            },
        ])
        presentMenu(menu, atDocPoint: CGPoint(x: rect.midX, y: rect.minY))
    }

    /// 把文件座標中的區域（含 PDF、物件、筆跡）畫成圖片
    func renderRegion(_ path: UIBezierPath) -> UIImage? {
        let rect = path.bounds.integral
        guard rect.width > 4, rect.height > 4 else { return nil }
        let scale = min(3, 4096 / max(rect.width, rect.height))
        let ink = PageRenderer.inkImage(canvas.drawing, rect: rect, scale: scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: fmt).image { rc in
            let ctx = rc.cgContext
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            path.addClip()
            for (i, f) in pageFrames.enumerated() where f.intersects(rect) {
                ctx.saveGState()
                ctx.translateBy(x: f.minX, y: f.minY)
                PageRenderer.drawPageWithoutInk(pages[i], session: session, in: ctx)
                ctx.restoreGState()
            }
            ink.draw(in: rect)
        }
    }
}

// MARK: - PDF text selection (翻譯、查詢、螢光)

extension NotebookViewController {
    func pdfPoint(_ docPoint: CGPoint, pageIndex i: Int, pdfPage: PDFPage) -> CGPoint {
        let o = contentOrigin(i)
        let local = CGPoint(x: docPoint.x - o.x, y: docPoint.y - o.y)
        return local.applying(NotebookSession.displayTransform(for: pdfPage).inverted())
    }

    func docRects(for sel: PDFSelection, pageIndex i: Int, pdfPage: PDFPage) -> [CGRect] {
        let t = NotebookSession.displayTransform(for: pdfPage)
        let o = contentOrigin(i)
        return sel.selectionsByLine().compactMap { line in
            let b = line.bounds(for: pdfPage)
            guard !b.isEmpty else { return nil }
            return b.applying(t).offsetBy(dx: o.x, dy: o.y)
        }
    }

    func handleTextPan(_ g: UIPanGestureRecognizer, _ p: CGPoint) {
        switch g.state {
        case .began:
            clearTextSelection()
            textPanStart = p
        case .changed, .ended:
            guard let s = textPanStart, let i = pageIndex(containing: s) else {
                if g.state == .ended { textPanStart = nil }
                return
            }
            // 沒有文字層（掃描檔）→ 用文字辨識
            guard let pdf = session.pdfPage(for: pages[i]), pageHasPDFText(i) else {
                let r = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
                if g.state == .ended {
                    textPanStart = nil
                    selectRecognizedText(pageIndex: i, docRect: r)
                } else {
                    overlay.showTextRects([r])
                }
                return
            }
            let a = pdfPoint(s, pageIndex: i, pdfPage: pdf)
            let b = pdfPoint(p, pageIndex: i, pdfPage: pdf)
            if let sel = robustSelection(pdf, pageID: pages[i].id, from: a, to: b), let text = sel.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let rects = docRects(for: sel, pageIndex: i, pdfPage: pdf)
                textSelection = TextSelectionState(pageIndex: i, text: text, docRects: rects)
                overlay.showTextRects(rects)
            }
            if g.state == .ended {
                textPanStart = nil
                if let ts = textSelection {
                    presentTextMenu(ts)
                } else {
                    // PDF 選字失敗 → 改用文字辨識
                    let r = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
                    selectRecognizedText(pageIndex: i, docRect: r)
                }
            }
        default:
            textPanStart = nil
        }
    }

    func tapText(at p: CGPoint) {
        // 點到螢光標示：一樣選取底下的字，選單裡多一個「移除螢光標示」
        let underHighlight = highlight(at: p)
        guard let i = pageIndex(containing: p) else {
            clearTextSelection()
            return
        }
        guard let pdf = session.pdfPage(for: pages[i]), pageHasPDFText(i) else {
            selectRecognizedText(pageIndex: i, docRect: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            return
        }
        guard let sel = robustWordSelection(pdf, pageID: pages[i].id, at: pdfPoint(p, pageIndex: i, pdfPage: pdf)),
              let text = sel.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // PDF 選字失敗 → 改用文字辨識
            selectRecognizedText(pageIndex: i, docRect: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            return
        }
        let rects = docRects(for: sel, pageIndex: i, pdfPage: pdf)
        let ts = TextSelectionState(pageIndex: i, text: text, docRects: rects)
        textSelection = ts
        overlay.showTextRects(rects)
        presentTextMenu(ts, removableHighlight: underHighlight)
    }

    func highlight(at p: CGPoint) -> (Int, UUID)? {
        guard let i = pageIndex(containing: p) else { return nil }
        let o = contentOrigin(i)
        let local = CGPoint(x: p.x - o.x, y: p.y - o.y)
        for h in pages[i].highlights.reversed() where h.rects.contains(where: { $0.contains(local) }) {
            return (i, h.id)
        }
        return nil
    }

    func clearTextSelection() {
        textSelection = nil
        overlay.showTextRects([])
    }

    func presentTextMenu(_ ts: TextSelectionState, removableHighlight: (Int, UUID)? = nil) {
        let bounds = ts.docRects.reduce(CGRect.null) { $0.union($1) }
        guard !bounds.isNull else { return }
        let anchor = docRectInView(bounds)
        let text = ts.text
        let colors = Palette.highlights.map { c in
            UIAction(title: c.name, image: UIImage(systemName: "circle.fill")?.withTintColor(UIColor(hex: c.hex), renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.addHighlight(ts, colorHex: c.hex)
            }
        }
        let menu = UIMenu(children: [
            UIAction(title: "翻譯", image: UIImage(systemName: "translate")) { [weak self] _ in
                guard let self else { return }
                TextServices.translate(text, from: self, anchor: anchor) { [weak self] translated in
                    self?.insertTextBox(at: CGPoint(x: bounds.midX, y: bounds.maxY + 50), text: translated)
                }
            },
            UIAction(title: "拷貝", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.string = text
                self?.clearTextSelection()
            },
            UIAction(title: "查詢", image: UIImage(systemName: "character.book.closed")) { [weak self] _ in
                guard let self else { return }
                TextServices.lookUp(text, from: self, anchor: anchor)
            },
            UIMenu(title: "螢光標示", image: UIImage(systemName: "highlighter"), children: colors),
        ] + removeHighlightActions(removableHighlight))
        presentMenu(menu, atDocPoint: CGPoint(x: bounds.midX, y: bounds.minY))
    }

    private func removeHighlightActions(_ h: (Int, UUID)?) -> [UIMenuElement] {
        guard case let (pi, hid)? = h else { return [] }
        return [UIAction(title: "移除螢光標示", image: UIImage(systemName: "eraser"), attributes: .destructive) { [weak self] _ in
            self?.updatePage(pi) { $0.highlights.removeAll { $0.id == hid } }
            self?.clearTextSelection()
        }]
    }

    func addHighlight(_ ts: TextSelectionState, colorHex: String) {
        let o = contentOrigin(ts.pageIndex)
        let rects = ts.docRects.map { $0.offsetBy(dx: -o.x, dy: -o.y) }
        updatePage(ts.pageIndex) { $0.highlights.append(TextHighlight(rects: rects, colorHex: colorHex)) }
        clearTextSelection()
    }

    /// 螢光筆畫在 PDF 文字上時，改成對齊文字、放在文字底下的螢光標示
    func snapHighlightToText(_ stroke: PKStroke) -> Bool {
        let b = stroke.renderBounds
        guard b.height < 48, b.width > 8 else { return false }
        let pts = stroke.path.map { $0.location.applying(stroke.transform) }
        guard let first = pts.first, let last = pts.last, let i = pageIndex(containing: b.center),
              let pdf = session.pdfPage(for: pages[i]) else { return false }
        let a = CGPoint(x: min(first.x, last.x), y: b.midY)
        let c = CGPoint(x: max(first.x, last.x), y: b.midY)
        guard let sel = pdf.selection(from: pdfPoint(a, pageIndex: i, pdfPage: pdf), to: pdfPoint(c, pageIndex: i, pdfPage: pdf)),
              let text = sel.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let rects = docRects(for: sel, pageIndex: i, pdfPage: pdf)
        guard rects.contains(where: { $0.insetBy(dx: 0, dy: -8).intersects(b) }) else { return false }
        let o = contentOrigin(i)
        // 畫在文字底下，用「和白色混合」模擬透明度，深淺和一般螢光筆跡一致
        let preset = BrushStore.shared.current
        let color = preset.color.lightened(1 - preset.effectiveOpacity).hexString
        updatePage(i) { $0.highlights.append(TextHighlight(rects: rects.map { $0.offsetBy(dx: -o.x, dy: -o.y) }, colorHex: color)) }
        return true
    }
}

extension UIImage {
    func downscaled(maxPixel: CGFloat) -> UIImage {
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        let longest = max(px.width, px.height)
        guard longest > maxPixel else { return self }
        let s = maxPixel / longest
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let target = CGSize(width: (px.width * s).rounded(), height: (px.height * s).rounded())
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
