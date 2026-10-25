import UIKit

// MARK: - 表格：儲存格選取

extension NotebookViewController {
    func selectedTable() -> (ref: ElementRef, element: PageElement, table: TableData, docRect: CGRect)? {
        guard let ref = selected, case let (pi, ei)? = locate(ref) else { return nil }
        let e = pages[pi].elements[ei]
        guard case let .table(t) = e.content else { return nil }
        return (ref, e, t, docFrame(of: e, pageIndex: pi))
    }

    func tableMoveHandlePoint() -> CGPoint? {
        guard let s = selectedTable(), !s.element.locked else { return nil }
        let off = 36 / canvas.zoomScale
        return CGPoint(x: s.docRect.minX - off, y: s.docRect.minY - off)
    }

    /// 刪除鈕：在移動按鈕上方（鎖定的表格不顯示）
    func tableDeleteHandlePoint() -> CGPoint? {
        guard let move = tableMoveHandlePoint() else { return nil }
        return CGPoint(x: move.x, y: move.y - 42 / canvas.zoomScale)
    }

    private func clampedRange(_ r: CellRange, in t: TableData) -> CellRange {
        var r = r
        r.r0 = min(max(r.r0, 0), t.rows - 1); r.r1 = min(max(r.r1, 0), t.rows - 1)
        r.c0 = min(max(r.c0, 0), t.cols - 1); r.c1 = min(max(r.c1, 0), t.cols - 1)
        return t.expanded(r)
    }

    /// 由文件座標 a 到 b 選取儲存格範圍
    func updateCellSelection(from a: CGPoint, to b: CGPoint) {
        guard let s = selectedTable(), s.table.rows > 0, s.table.cols > 0 else { return }
        let t = s.table
        func cellAt(_ p: CGPoint) -> (row: Int, col: Int) {
            let x = min(max(p.x - s.docRect.minX, 0), t.size.width - 0.01)
            let y = min(max(p.y - s.docRect.minY, 0), t.size.height - 0.01)
            return (t.rowIndex(at: y) ?? 0, t.colIndex(at: x) ?? 0)
        }
        tableCellSel = clampedRange(CellRange(cellAt(a), cellAt(b)), in: t)
        updateTableCellChrome()
    }

    func updateTableCellChrome() {
        guard tool == .select, editingTextView == nil, let s = selectedTable(), s.table.rows > 0, s.table.cols > 0 else {
            overlay.showCellSelection(nil)
            overlay.showMoveHandle(nil)
            overlay.showDeleteHandle(nil)
            return
        }
        overlay.showMoveHandle(tableMoveHandlePoint())
        overlay.showDeleteHandle(tableDeleteHandlePoint())
        if let sel = tableCellSel {
            let r = clampedRange(sel, in: s.table)
            tableCellSel = r
            overlay.showCellSelection(s.table.rangeRect(r).offsetBy(dx: s.docRect.minX, dy: s.docRect.minY))
        } else {
            overlay.showCellSelection(nil)
        }
        tableCellLabel?.text = cellLabel(tableCellSel)
    }

    private func columnName(_ c: Int) -> String {
        var n = c, s = ""
        repeat {
            s = String(Character(UnicodeScalar(UInt8(65 + n % 26)))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    func cellLabel(_ r: CellRange?) -> String {
        guard let r else { return "" }
        let a = "\(columnName(r.c0))\(r.r0 + 1)"
        return r.isSingle ? a : "\(a):\(columnName(r.c1))\(r.r1 + 1)"
    }

    // MARK: - 表格工具列（像 Word 的表格設計）

    private func tableAction(_ change: @escaping (inout TableData, CellRange) -> Void) {
        guard let s = selectedTable() else { return }
        let range = tableCellSel ?? CellRange((0, 0), (0, 0))
        modifyTable(s.ref) { change(&$0, range) }
        updateTableCellChrome()
    }

    func buildTableRibbon() -> [UIView] {
        guard let s = selectedTable() else { return [] }
        var views: [UIView] = []

        func menuButton(_ symbol: String, _ label: String, _ items: [UIMenuElement]) -> UIButton {
            let b = makeButton(symbol: symbol, title: nil, action: nil)
            b.accessibilityLabel = label
            b.menu = UIMenu(title: label, children: items)
            b.showsMenuAsPrimaryAction = true
            return b
        }
        func actionButton(_ symbol: String, _ label: String, _ handler: @escaping () -> Void) -> UIButton {
            let b = makeButton(symbol: symbol, title: nil, action: nil)
            b.accessibilityLabel = label
            b.addAction(UIAction { _ in handler() }, for: .touchUpInside)
            return b
        }
        func act(_ title: String, _ symbol: String? = nil, attributes: UIMenuElement.Attributes = [],
                 _ change: @escaping (inout TableData, CellRange) -> Void) -> UIAction {
            UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, attributes: attributes) { [weak self] _ in
                self?.tableAction(change)
            }
        }

        let cell = UILabel()
        cell.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        cell.textColor = .systemBlue
        cell.text = cellLabel(tableCellSel)
        cell.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        tableCellLabel = cell
        views.append(cell)

        views.append(actionButton("keyboard", "編輯文字") { [weak self] in
            guard let self, let s = self.selectedTable() else { return }
            let r = self.tableCellSel ?? CellRange((0, 0), (0, 0))
            self.beginTextEditing(s.ref, cell: (r.r0, r.c0))
        })

        views.append(menuButton("plus.rectangle.on.rectangle", "插入", [
            act("在上方插入列", "arrow.up.to.line") { t, r in t.insertRow(at: r.r0) },
            act("在下方插入列", "arrow.down.to.line") { t, r in t.insertRow(at: r.r1 + 1) },
            act("在左側插入欄", "arrow.left.to.line") { t, r in t.insertColumn(at: r.c0) },
            act("在右側插入欄", "arrow.right.to.line") { t, r in t.insertColumn(at: r.c1 + 1) },
        ]))

        views.append(menuButton("minus.rectangle", "刪除", [
            act("刪除列", attributes: .destructive) { t, r in for row in (r.r0...r.r1).reversed() { t.removeRow(row) } },
            act("刪除欄", attributes: .destructive) { t, r in for col in (r.c0...r.c1).reversed() { t.removeColumn(col) } },
            UIAction(title: "刪除整個表格", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self, let s = self.selectedTable() else { return }
                self.deleteElement(s.ref)
            },
        ]))

        func imageButton(_ image: UIImage, _ label: String, _ handler: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.plain()
            config.image = image
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            let b = UIButton(configuration: config)
            b.accessibilityLabel = label
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.addAction(UIAction { _ in handler() }, for: .touchUpInside)
            return b
        }

        views.append(imageButton(TableIcons.merge, "合併儲存格") { [weak self] in
            guard let self else { return }
            guard let r = self.tableCellSel, !r.isSingle else {
                self.showToast("先在表格裡拖曳，選取要合併的儲存格")
                return
            }
            self.tableAction { t, r in t.mergeCells(r) }
        })

        views.append(imageButton(TableIcons.split, "分割儲存格") { [weak self] in
            self?.presentSplitDialog()
        })

        views.append(menuButton("line.diagonal", "斜線", [
            act("左上到右下") { t, r in t.setDiagonal(r.r0, r.c0, reverse: false) },
            act("右上到左下") { t, r in t.setDiagonal(r.r0, r.c0, reverse: true) },
            act("移除斜線", attributes: .destructive) { t, r in t.setDiagonal(r.r0, r.c0, reverse: nil) },
        ]))

        views.append(actionButton("pencil.and.outline", "手繪格線") { [weak self] in
            guard let self, let s = self.selectedTable() else { return }
            self.setTool(.tableDraw)
            self.tableDrawTarget = s.ref
            self.rebuildSubBar()
            self.updateTableDraftChrome()
        })

        let fills: [(String, String?)] = [("黃色", "#FFF59DFF"), ("綠色", "#C8E6C9FF"), ("藍色", "#BBDEFBFF"),
                                          ("粉紅", "#F8BBD0FF"), ("灰色", "#E0E0E0FF"), ("無底色", nil)]
        views.append(menuButton("drop.fill", "儲存格底色", fills.map { name, hex in
            act(name, hex == nil ? "circle.slash" : "circle.fill") { t, r in t.setFill(r, hex: hex) }
        }))

        views.append(menuButton("squareshape.split.3x3", "格線", [
            act("黑色") { t, _ in t.lineColorHex = "#333333FF" },
            act("灰色") { t, _ in t.lineColorHex = "#9E9E9EFF" },
            act("藍色") { t, _ in t.lineColorHex = "#1E5BD8FF" },
            act("紅色") { t, _ in t.lineColorHex = "#D32F2FFF" },
            act("加粗", "plus") { t, _ in t.lineWidth = min(t.lineWidth + 0.5, 5) },
            act("變細", "minus") { t, _ in t.lineWidth = max(t.lineWidth - 0.5, 0.5) },
        ]))

        views.append(menuButton("textformat.size", "字級", [
            act("字放大", "plus") { t, _ in t.fontSize = min(t.fontSize + 2, 48) },
            act("字縮小", "minus") { t, _ in t.fontSize = max(t.fontSize - 2, 8) },
        ]))

        views.append(menuButton("arrow.left.and.right", "平均分配", [
            act("平均分配欄寬") { t, _ in t.distributeColumns() },
            act("平均分配列高") { t, _ in t.distributeRows() },
        ]))

        views.append(actionButton(s.element.locked ? "lock.fill" : "lock.open", s.element.locked ? "解除固定" : "固定位置") { [weak self] in
            guard let self, let s = self.selectedTable() else { return }
            self.modifyElement(s.ref) { $0.locked.toggle() }
            self.rebuildSubBar()
        })
        return views
    }

    /// 像 Word 一樣輸入要分割成幾欄、幾列
    func presentSplitDialog() {
        guard let s = selectedTable() else { return }
        let range = tableCellSel ?? CellRange((0, 0), (0, 0))
        let span = s.table.span(range.r0, range.c0)
        let isMerged = span.rowSpan * span.colSpan > 1
        let a = UIAlertController(title: "分割儲存格", message: cellLabel(range), preferredStyle: .alert)
        a.addTextField { tf in
            tf.placeholder = "欄數（左右）"
            tf.text = "\(max(2, span.colSpan))"
            tf.keyboardType = .numberPad
        }
        a.addTextField { tf in
            tf.placeholder = "列數（上下）"
            tf.text = "\(span.rowSpan)"
            tf.keyboardType = .numberPad
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        if isMerged {
            a.addAction(UIAlertAction(title: "取消合併", style: .default) { [weak self] _ in
                self?.tableAction { t, r in t.unmerge(r.r0, r.c0) }
            })
        }
        a.addAction(UIAlertAction(title: "分割", style: .default) { [weak self, weak a] _ in
            let cols = min(max(Int(a?.textFields?[0].text ?? "") ?? 2, 1), 20)
            let rows = min(max(Int(a?.textFields?[1].text ?? "") ?? 1, 1), 20)
            guard cols * rows > 1 || isMerged else { return }
            self?.tableAction { t, r in t.splitCell(r.r0, r.c0, cols: cols, rows: rows) }
            self?.tableCellSel = nil
            self?.updateTableCellChrome()
        })
        present(a, animated: true)
    }

    // MARK: - 在已有的表格上手繪格線

    /// 橫線：把碰到的儲存格切成上下兩格；直線：切成左右兩格；斜線：加上斜線
    func applyTableStroke(_ ref: ElementRef, from a: CGPoint, to b: CGPoint) {
        guard case let (pi, ei)? = locate(ref), case let .table(t) = pages[pi].elements[ei].content else { return }
        let r = docFrame(of: pages[pi].elements[ei], pageIndex: pi)
        let la = CGPoint(x: a.x - r.minX, y: a.y - r.minY)
        let lb = CGPoint(x: b.x - r.minX, y: b.y - r.minY)
        let dx = lb.x - la.x, dy = lb.y - la.y
        guard hypot(dx, dy) > 12 else {
            showToast("線太短了")
            return
        }
        let before = t
        let size = t.size

        // 先看是不是斜線：線的寬、高都超過中間那一格（含合併格）的一半，就當作那格的斜線。
        // 用格子大小判斷而不是角度，寬的格子裡畫的平緩斜線也能認得。
        let mid = CGPoint(x: (la.x + lb.x) / 2, y: (la.y + lb.y) / 2)
        if let cell = t.cell(at: mid) {
            let cr = t.cellRect(row: cell.row, col: cell.col)
            if abs(dx) >= cr.width * 0.5 && abs(dy) >= cr.height * 0.5 {
                // 往右上畫（dx、dy 異號）＝右上到左下的斜線
                let reverse = (dx * dy) < 0
                if let existing = t.diagonal(cell.row, cell.col), existing.reverse == reverse {
                    showToast("這格已經有斜線了（要移除請用表格工具列的斜線選單）")
                    return
                }
                modifyTable(ref) { $0.setDiagonal(cell.row, cell.col, reverse: reverse) }
                return
            }
        }

        if abs(dx) >= abs(dy) {
            let y = (la.y + lb.y) / 2
            guard y > 0, y < size.height, let row = t.rowIndex(at: y) else {
                showToast("橫線要畫在表格裡面")
                return
            }
            let x0 = max(0, min(la.x, lb.x)), x1 = min(size.width, max(la.x, lb.x))
            let cols = Set((0..<t.cols).filter { c in
                let overlap = min(x1, t.colX(c + 1)) - max(x0, t.colX(c))
                return overlap >= t.colWidths[c] * 0.5
            })
            guard !cols.isEmpty else {
                showToast("橫線要至少橫跨一格的一半")
                return
            }
            modifyTable(ref) { $0.splitRow(row, at: y - t.rowY(row), columns: cols) }
        } else {
            let x = (la.x + lb.x) / 2
            guard x > 0, x < size.width, let col = t.colIndex(at: x) else {
                showToast("直線要畫在表格裡面")
                return
            }
            let y0 = max(0, min(la.y, lb.y)), y1 = min(size.height, max(la.y, lb.y))
            let rows = Set((0..<t.rows).filter { rr in
                let overlap = min(y1, t.rowY(rr + 1)) - max(y0, t.rowY(rr))
                return overlap >= t.rowHeights[rr] * 0.5
            })
            guard !rows.isEmpty else {
                showToast("直線要至少縱跨一格的一半")
                return
            }
            modifyTable(ref) { $0.splitColumn(col, at: x - t.colX(col), rows: rows) }
        }
        // 沒有任何變化（例如太靠近既有格線）
        if case let (pi2, ei2)? = locate(ref), case let .table(after) = pages[pi2].elements[ei2].content, after == before {
            showToast("這條線太靠近既有的格線，沒有切出新的格子")
        }
    }

    func finishTableEditDraw() {
        let target = tableDrawTarget
        setTool(.select)
        if let target, locate(target) != nil { select(target) }
    }
}

// MARK: - 讓 Pencil 能用在截圖、選取、PDF 文字；筆模式下關掉系統的「插入空格」選單

extension NotebookViewController {
    var ownGestureRecognizers: [UIGestureRecognizer] {
        [toolPan, tapGesture, doubleTapGesture, longPressGesture, holdRecognizer, textLongPress, eraserTracker, pencilPointTracker, palmBlocker, inkRecognizer].compactMap { $0 }
    }

    func configurePencilKitGestures() {
        let drawingTool = tool.isDrawing
        var all: [UIGestureRecognizer] = []
        func collect(_ v: UIView) {
            if v is UITextView || v === pagesContainer { return }
            all.append(contentsOf: v.gestureRecognizers ?? [])
            v.subviews.forEach(collect)
        }
        collect(canvas)
        let mine = Set(ownGestureRecognizers.map { ObjectIdentifier($0) })
        for g in all where !mine.contains(ObjectIdentifier(g)) {
            if g === canvas.panGestureRecognizer || g === canvas.pinchGestureRecognizer { continue }
            if g === canvas.drawingGestureRecognizer {
                g.isEnabled = drawingTool
                continue
            }
            if !drawingTool {
                g.isEnabled = false
            } else if g is UITapGestureRecognizer || g is UILongPressGestureRecognizer {
                // PencilKit 點空白處的「插入空格」等選單：只在套索模式保留
                g.isEnabled = tool == .lasso
            } else {
                g.isEnabled = true
            }
        }
    }

    // MARK: 橡皮擦擦掉螢光標示

    /// 橡皮擦的半徑（文件座標）。大小是螢幕上的大小（和 PencilKit 橡皮擦的圓圈一樣），放大頁面時擦到的範圍跟著變小
    var eraserRadius: CGFloat {
        (settings.pixelEraser ? settings.eraserWidth / 2 : 4) / canvas.zoomScale
    }

    func eraseHighlights(at p: CGPoint) {
        guard tool == .eraser, let i = pageIndex(containing: p) else { return }
        let o = contentOrigin(i)
        let local = CGPoint(x: p.x - o.x, y: p.y - o.y)
        let radius = eraserRadius
        func hit(_ r: CGRect) -> Bool { r.insetBy(dx: -radius, dy: -radius).contains(local) }
        guard pages[i].highlights.contains(where: { $0.rects.contains(where: hit) }) else { return }
        let pixel = settings.pixelEraser
        updatePage(i) { page in
            if pixel {
                // 局部擦除：只擦掉碰到的那一行
                for k in page.highlights.indices { page.highlights[k].rects.removeAll(where: hit) }
                page.highlights.removeAll { $0.rects.isEmpty }
            } else {
                page.highlights.removeAll { $0.rects.contains(where: hit) }
            }
        }
    }
}

/// 仿 Word 的「合併儲存格」「分割儲存格」圖示
enum TableIcons {
    private static let gray = UIColor(white: 0.45, alpha: 1)
    private static let lightGray = UIColor(white: 0.72, alpha: 1)
    private static let blue = UIColor(red: 0.17, green: 0.42, blue: 0.84, alpha: 1)
    private static let fill = UIColor(red: 0.74, green: 0.85, blue: 0.98, alpha: 1)

    private static func render(_ draw: @escaping (CGRect) -> Void) -> UIImage {
        let size = CGSize(width: 30, height: 24)
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(CGRect(x: 1.5, y: 1.5, width: size.width - 3, height: size.height - 3))
        }.withRenderingMode(.alwaysOriginal)
    }

    private static func line(_ a: CGPoint, _ b: CGPoint, _ color: UIColor, _ width: CGFloat = 1) {
        let p = UIBezierPath()
        p.move(to: a)
        p.addLine(to: b)
        p.lineWidth = width
        color.setStroke()
        p.stroke()
    }

    /// 3×3 格，中間一列合併成一格（藍色）
    static let merge: UIImage = render { r in
        let w = r.width / 3, h = r.height / 3
        let mid = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: h)
        fill.setFill()
        UIRectFill(mid)
        for i in 1...2 {
            let x = r.minX + w * CGFloat(i)
            line(CGPoint(x: x, y: r.minY), CGPoint(x: x, y: mid.minY), lightGray)
            line(CGPoint(x: x, y: mid.maxY), CGPoint(x: x, y: r.maxY), lightGray)
        }
        line(CGPoint(x: r.minX, y: mid.minY), CGPoint(x: r.maxX, y: mid.minY), lightGray)
        line(CGPoint(x: r.minX, y: mid.maxY), CGPoint(x: r.maxX, y: mid.maxY), lightGray)
        let outer = UIBezierPath(rect: r)
        outer.lineWidth = 1
        gray.setStroke()
        outer.stroke()
        let box = UIBezierPath(rect: mid)
        box.lineWidth = 1.5
        blue.setStroke()
        box.stroke()
    }

    /// 2×2 格，右上那格用藍線再切成四格
    static let split: UIImage = render { r in
        let w = r.width / 2, h = r.height / 2
        let cell = CGRect(x: r.minX + w, y: r.minY, width: w, height: h)
        fill.setFill()
        UIRectFill(cell)
        line(CGPoint(x: r.minX + w, y: r.minY), CGPoint(x: r.minX + w, y: r.maxY), lightGray)
        line(CGPoint(x: r.minX, y: r.minY + h), CGPoint(x: r.maxX, y: r.minY + h), lightGray)
        let outer = UIBezierPath(rect: r)
        outer.lineWidth = 1
        gray.setStroke()
        outer.stroke()
        line(CGPoint(x: cell.midX, y: cell.minY), CGPoint(x: cell.midX, y: cell.maxY), blue, 1.5)
        line(CGPoint(x: cell.minX, y: cell.midY), CGPoint(x: cell.maxX, y: cell.midY), blue, 1.5)
        let box = UIBezierPath(rect: cell)
        box.lineWidth = 1.5
        blue.setStroke()
        box.stroke()
    }
}
