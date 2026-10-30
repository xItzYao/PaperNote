import UIKit
import SwiftUI

/// 點到的是第幾欄（或第幾列）的標頭
struct TableHeaderHit: Equatable {
    var columns: Bool
    var index: Int
}

/// 表格的小視窗（重複、分割）要指著哪裡：工具列的按鈕，或文件上的位置（長按、標頭）
enum TablePanelAnchor {
    case view(UIView)
    case doc(CGRect)
    /// 打開時目前選取的格子（工具列的按鈕先做好，選取範圍之後可能會變）
    case selection
}

extension NotebookViewController {
    // MARK: - 手繪格線：用筆就能做

    /// 手繪格線模式畫的一筆（文件座標）：劃掉格線＝合併兩邊的格子、畫在表格外側＝在那裡加一列／欄；
    /// 其他照原本（切開格子、加斜線）
    func applyTableStroke(_ ref: ElementRef, points: [CGPoint]) {
        guard let a = points.first, let b = points.last, case let (pi, ei)? = locate(ref),
              case let .table(t) = pages[pi].elements[ei].content else { return }
        let o = docFrame(of: pages[pi].elements[ei], pageIndex: pi).origin
        let local = points.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }
        guard let g = t.gesture(for: local) else {
            applyTableStroke(ref, from: a, to: b)
            return
        }
        switch g {
        case let .merge(ranges):
            modifyTable(ref) { for r in ranges { $0.mergeCells(r) } }
            showToast(ranges.count > 1 ? "已合併 \(ranges.count) 組格子" : "已合併格子")
        case let .addRow(at, height):
            modifyElement(ref) { e in
                guard case var .table(t) = e.content else { return }
                t.insertRow(at: at, height: height)
                t.normalizeCells()
                // 加在上面：表格往上長，原本的格子留在原地
                if at == 0 { e.frame.origin.y -= height }
                e.content = .table(t)
                e.frame.size = t.size
            }
            showToast(at == 0 ? "已在上面加一列" : "已在下面加一列")
        case let .addColumn(at, width):
            modifyElement(ref) { e in
                guard case var .table(t) = e.content else { return }
                t.insertColumn(at: at, width: width)
                t.normalizeCells()
                if at == 0 { e.frame.origin.x -= width }
                e.content = .table(t)
                e.frame.size = t.size
            }
            showToast(at == 0 ? "已在左邊加一欄" : "已在右邊加一欄")
        }
        updateTableDraftChrome()
    }

    /// 手繪格線模式：畫線 ↔ 擦線（工具列的切換和 Pencil 筆身點兩下都用這個）
    func toggleTableEraseLines() {
        tableEraseLines.toggle()
        rebuildSubBar()
        showToast(tableEraseLines ? "擦線：沿著格線擦，放開就合併兩邊的格子；沿著斜線擦就拿掉斜線" : "畫線：切開格子、畫斜線、在表格旁邊加列欄")
    }

    /// 擦線：p 是到目前為止擦過的路徑（文件座標）。會被擦掉的線先變半透明
    func previewTableErase(_ ref: ElementRef, points: [CGPoint]) {
        guard case let (pi, ei)? = locate(ref), case let .table(t) = pages[pi].elements[ei].content else { return }
        let o = docFrame(of: pages[pi].elements[ei], pageIndex: pi).origin
        tableErasePreview = t.erasedLines(points.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }, tolerance: 10 / canvas.zoomScale)
        overlay.showFadedLines(tableErasePreview.map { (CGPoint(x: $0.from.x + o.x, y: $0.from.y + o.y), CGPoint(x: $0.to.x + o.x, y: $0.to.y + o.y)) },
                               width: t.lineWidth + 3)
    }

    /// 擦線放開：擦掉預覽裡的線（格線＝合併兩邊的格子；斜線＝拿掉斜線）
    func finishTableErase(_ ref: ElementRef, points: [CGPoint]) {
        previewTableErase(ref, points: points)
        let lines = tableErasePreview
        tableErasePreview = []
        overlay.showFadedLines([], width: 0)
        guard !lines.isEmpty else { return }
        modifyTable(ref) { t in
            for l in lines where l.diagonal { t.setDiagonal(l.range.r0, l.range.c0, reverse: nil) }
            for l in lines where !l.diagonal { t.mergeCells(l.range) }
        }
        updateTableDraftChrome()
    }

    // MARK: - 欄、列標頭

    /// 標頭的粗細、離表格多遠（螢幕上的大小）
    static let tableHeaderSize: CGFloat = 20
    static let tableHeaderGap: CGFloat = 4

    /// 選到表格時，上方的欄標頭、左邊的列標頭（文件座標）
    func tableHeaderRects() -> (cols: [CGRect], rows: [CGRect])? {
        guard tool == .select, editingTextView == nil, let s = selectedTable(), s.table.rows > 0, s.table.cols > 0 else { return nil }
        let t = s.table, o = s.docRect.origin
        let h = Self.tableHeaderSize / canvas.zoomScale, gap = Self.tableHeaderGap / canvas.zoomScale
        let cols = (0..<t.cols).map { CGRect(x: o.x + t.colX($0), y: o.y - gap - h, width: t.colWidths[$0], height: h) }
        let rows = (0..<t.rows).map { CGRect(x: o.x - gap - h, y: o.y + t.rowY($0), width: h, height: t.rowHeights[$0]) }
        return (cols, rows)
    }

    func tableHeaderHit(at p: CGPoint) -> TableHeaderHit? {
        guard let r = tableHeaderRects() else { return nil }
        let slop = 6 / canvas.zoomScale
        if let i = r.cols.firstIndex(where: { $0.insetBy(dx: 0, dy: -slop).contains(p) }) { return TableHeaderHit(columns: true, index: i) }
        if let i = r.rows.firstIndex(where: { $0.insetBy(dx: -slop, dy: 0).contains(p) }) { return TableHeaderHit(columns: false, index: i) }
        return nil
    }

    /// 選整欄（整列）；拖曳時 start 是一開始按的那一欄，一路選到 hit
    func selectTableHeaders(_ hit: TableHeaderHit, from start: Int? = nil) {
        guard let s = selectedTable() else { return }
        let t = s.table
        let a = start ?? hit.index, lo = min(a, hit.index), hi = max(a, hit.index)
        tableCellSel = hit.columns ? CellRange((0, lo), (t.rows - 1, hi)) : CellRange((lo, 0), (hi, t.cols - 1))
        updateTableCellChrome()
    }

    /// 拖曳標頭：p 在哪一欄（列）就選到哪（超出表格就到第一或最後一欄）
    func dragTableHeaders(columns: Bool, from start: Int, to p: CGPoint) {
        guard let s = selectedTable() else { return }
        let t = s.table
        let local = columns ? p.x - s.docRect.minX : p.y - s.docRect.minY
        let i: Int
        if columns {
            i = local <= 0 ? 0 : (t.colIndex(at: local) ?? t.cols - 1)
        } else {
            i = local <= 0 ? 0 : (t.rowIndex(at: local) ?? t.rows - 1)
        }
        selectTableHeaders(TableHeaderHit(columns: columns, index: i), from: start)
    }

    /// 這個標頭的整欄（整列）已經選起來了
    func isTableHeaderSelected(_ h: TableHeaderHit) -> Bool {
        guard let t = selectedTable()?.table, let sel = tableCellSel else { return false }
        return h.columns ? (h.index >= sel.c0 && h.index <= sel.c1 && sel.r0 == 0 && sel.r1 == t.rows - 1)
            : (h.index >= sel.r0 && h.index <= sel.r1 && sel.c0 == 0 && sel.c1 == t.cols - 1)
    }

    /// 列與欄的選單，指著這個標頭（還沒選起來就先選整欄、整列；已經選了好幾欄就不變）
    func presentTableHeaderMenu(_ h: TableHeaderHit, at p: CGPoint) {
        if !isTableHeaderSelected(h) { selectTableHeaders(h) }
        let anchor = tableHeaderRects().map { h.columns ? $0.cols[h.index] : $0.rows[h.index] } ?? CGRect(origin: p, size: .zero)
        presentMenu(UIMenu(children: tableRowColItems()), atDocPoint: p, avoiding: anchor)
    }

    func updateTableHeadersChrome() {
        guard let r = tableHeaderRects(), let s = selectedTable() else {
            overlay.showTableHeaders([])
            return
        }
        let t = s.table, sel = tableCellSel
        var headers = r.cols.enumerated().map { c, rect in
            OverlayView.TableHeader(rect: rect, label: columnName(c), selected: sel.map { (c >= $0.c0 && c <= $0.c1) } ?? false,
                                    locked: t.lockedCols.contains(c))
        }
        headers += r.rows.enumerated().map { row, rect in
            OverlayView.TableHeader(rect: rect, label: "\(row + 1)", selected: sel.map { (row >= $0.r0 && row <= $0.r1) } ?? false,
                                    locked: t.lockedRows.contains(row))
        }
        overlay.showTableHeaders(headers)
    }

    // MARK: - 選單（工具列、長按、標頭共用）

    private func tableAct(_ title: String, _ symbol: String? = nil, attributes: UIMenuElement.Attributes = [],
                          _ change: @escaping (inout TableData, CellRange) -> Void) -> UIAction {
        UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) }, attributes: attributes) { [weak self] _ in
            self?.tableAction(change)
        }
    }

    /// 調色盤（從 source 跳出），點一個顏色就套用並關掉。
    /// 和其他表格小視窗一樣讓頁面接得到觸碰（不用系統的顏色選擇器：點旁邊關掉它之後，頁面的手勢會卡住捲不動）
    func presentColorPalette(title: String, selected: String?, clear: String?, from source: UIView, _ pick: @escaping (String?) -> Void) {
        let panel = ColorPalettePanel(title: title, selected: selected, clearTitle: clear) { [weak self] hex in
            self?.dismissToolPopover()
            pick(hex)
        }
        presentTablePanel(hosting(panel), anchor: .view(source), size: CGSize(width: 320, height: clear == nil ? 250 : 300))
    }

    /// SwiftUI 小視窗：大小跟著內容（不會被切掉）
    func hosting<V: View>(_ v: V) -> UIHostingController<V> {
        let h = UIHostingController(rootView: v)
        h.sizingOptions = .preferredContentSize
        return h
    }

    func presentTablePanel(_ vc: UIViewController, anchor: TablePanelAnchor, size: CGSize) {
        switch anchor {
        case let .view(v): presentToolPopover(vc, from: v, size: size)
        case let .doc(r): presentToolPopover(vc, from: canvas, rect: pagesContainer.convert(r, to: canvas), size: size)
        case .selection:
            guard let r = tableSelectionDocRect() else { return }
            presentToolPopover(vc, from: canvas, rect: pagesContainer.convert(r, to: canvas), size: size)
        }
    }

    /// 選取範圍在文件上的位置（小視窗指著它）
    func tableSelectionDocRect() -> CGRect? {
        guard let s = selectedTable() else { return nil }
        let r = tableCellSel ?? CellRange((0, 0), (s.table.rows - 1, s.table.cols - 1))
        return s.table.rangeRect(r).offsetBy(dx: s.docRect.minX, dy: s.docRect.minY)
    }

    /// 工具列的按鈕（先做好，按的時候才看選取範圍）：
    /// edit＝重複、合併、分割、取消合併、手繪格線、刪除列、刪除欄；deleteTable 放在最右邊
    func tableRibbonActions() -> (edit: [UIAction], deleteTable: UIAction) {
        let edit = [
            UIAction(title: "重複…", image: UIImage(systemName: "square.stack.3d.down.right")) { [weak self] _ in
                self?.presentRepeatPanel(anchor: .selection)
            },
            UIAction(title: "合併", image: TableIcons.merge) { [weak self] _ in self?.tableAction { t, r in t.mergeCells(r) } },
            UIAction(title: "分割…", image: TableIcons.split) { [weak self] _ in self?.presentSplitPanel(anchor: .selection) },
            tableAct("取消合併", "square.split.2x2") { t, r in t.unmerge(r.r0, r.c0) },
            UIAction(title: "手繪格線", image: UIImage(systemName: "pencil.and.outline")) { [weak self] _ in
                guard let self, let s = self.selectedTable() else { return }
                self.setTool(.tableDraw)
                self.tableDrawTarget = s.ref
                self.rebuildSubBar()
                self.updateTableDraftChrome()
            },
            tableAct("刪除列", "minus.rectangle", attributes: .destructive) { t, r in for row in (r.r0...r.r1).reversed() { t.removeRow(row) } },
            tableAct("刪除欄", "minus.rectangle.portrait", attributes: .destructive) { t, r in for col in (r.c0...r.c1).reversed() { t.removeColumn(col) } },
        ]
        let deleteTable = UIAction(title: "刪除表格", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            guard let self, let s = self.selectedTable() else { return }
            self.deleteElement(s.ref)
            self.showToast("已刪除表格（可以按復原）")
        }
        return (edit, deleteTable)
    }

    /// 工具列「平均分配」的選單：選取範圍的欄寬或列高（只選一欄、一列時是整個表格）
    func tableDistributeItems() -> [UIMenuElement] {
        [
            tableAct("平均分配欄寬", "arrow.left.and.right") { t, r in t.distributeColumns(r.c1 > r.c0 ? r.c0...r.c1 : nil) },
            tableAct("平均分配列高", "arrow.up.and.down") { t, r in t.distributeRows(r.r1 > r.r0 ? r.r0...r.r1 : nil) },
        ]
    }

    /// 工具列「鎖定」的選單：打勾＝選取範圍的欄寬（列高）已經鎖住，再選一次解除
    func tableLockItems() -> [UIMenuElement] {
        guard let s = selectedTable() else { return [] }
        let r = tableCellSel ?? CellRange((0, 0), (0, 0))
        let cols = (r.c0...r.c1).allSatisfy(s.table.lockedCols.contains)
        let rows = (r.r0...r.r1).allSatisfy(s.table.lockedRows.contains)
        return [
            UIAction(title: "鎖定欄寬", image: UIImage(systemName: "arrow.left.and.right"), state: cols ? .on : .off) { [weak self] _ in
                self?.toggleTableLock(columns: true)
            },
            UIAction(title: "鎖定列高", image: UIImage(systemName: "arrow.up.and.down"), state: rows ? .on : .off) { [weak self] _ in
                self?.toggleTableLock(columns: false)
            },
        ]
    }

    /// 選取範圍的欄寬（列高）全部鎖住了就解除，否則鎖住
    func toggleTableLock(columns: Bool) {
        tableAction { t, r in
            if columns {
                t.setColsLocked(r.c0...r.c1, !(r.c0...r.c1).allSatisfy(t.lockedCols.contains))
            } else {
                t.setRowsLocked(r.r0...r.r1, !(r.r0...r.r1).allSatisfy(t.lockedRows.contains))
            }
        }
    }

    /// 列與欄：插入、刪除（點選起來的標頭、長按標頭的選單；其他功能在工具列）
    func tableRowColItems() -> [UIMenuElement] {
        guard selectedTable() != nil else { return [] }
        let r = tableCellSel ?? CellRange((0, 0), (0, 0))
        let colsName = r.c1 > r.c0 ? "\(columnName(r.c0))–\(columnName(r.c1)) 欄" : "\(columnName(r.c0)) 欄"
        let rowsName = r.r1 > r.r0 ? "第 \(r.r0 + 1)–\(r.r1 + 1) 列" : "第 \(r.r0 + 1) 列"
        return [
            UIMenu(title: "插入", image: UIImage(systemName: "plus.rectangle.on.rectangle"), children: [
                tableAct("在上方插入列", "arrow.up.to.line") { t, r in t.insertRow(at: r.r0) },
                tableAct("在下方插入列", "arrow.down.to.line") { t, r in t.insertRow(at: r.r1 + 1) },
                tableAct("在左側插入欄", "arrow.left.to.line") { t, r in t.insertColumn(at: r.c0) },
                tableAct("在右側插入欄", "arrow.right.to.line") { t, r in t.insertColumn(at: r.c1 + 1) },
            ]),
            UIMenu(title: "刪除", image: UIImage(systemName: "minus.rectangle"), children: [
                tableAct("刪除\(rowsName)", "minus.rectangle", attributes: .destructive) { t, r in for row in (r.r0...r.r1).reversed() { t.removeRow(row) } },
                tableAct("刪除\(colsName)", "minus.rectangle", attributes: .destructive) { t, r in for col in (r.c0...r.c1).reversed() { t.removeColumn(col) } },
            ]),
        ]
    }

    // MARK: - 長按格子的選單：文字、拷貝、剪下、貼上（多格記相對位置）

    func tableCellMenuItems(_ ref: ElementRef, cell: (row: Int, col: Int)?) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if let cell {
            items.append(UIAction(title: "編輯文字", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                self?.beginTextEditing(ref, cell: cell)
            })
        }
        let canPaste = tableCellClipboard.map { $0.changeCount == UIPasteboard.general.changeCount } == true || UIPasteboard.general.hasStrings
        items += [
            UIAction(title: "刪除文字", image: UIImage(systemName: "delete.left"), attributes: .destructive) { [weak self] _ in self?.clearTableCellText() },
            UIAction(title: "複製一份", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateElement(ref) },
            UIAction(title: "拷貝", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyTableCells() },
            UIAction(title: "剪下", image: UIImage(systemName: "scissors")) { [weak self] _ in self?.cutTableCells() },
            UIAction(title: "貼上", image: UIImage(systemName: "doc.on.clipboard"), attributes: canPaste ? [] : .disabled) { [weak self] _ in
                self?.pasteTableCells()
            },
        ]
        return items
    }

    /// 選取範圍的文字，照相對位置排（合併格蓋住的格子是空字串）
    func selectedCellTexts() -> [[String]]? {
        guard let s = selectedTable() else { return nil }
        let r = s.table.expanded(tableCellSel ?? CellRange((0, 0), (0, 0)))
        return (r.r0...r.r1).map { row in
            (r.c0...r.c1).map { col in s.table.isAnchor(row, col) ? s.table.text(row: row, col: col) : "" }
        }
    }

    /// 拷貝選取的格子：App 裡記下相對位置；別的 App 拿到的是 Tab 分欄、換行分列的文字
    func copyTableCells() {
        guard let grid = selectedCellTexts() else { return }
        let pb = UIPasteboard.general
        pb.string = grid.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        tableCellClipboard = (grid, pb.changeCount)
    }

    func cutTableCells() {
        copyTableCells()
        clearTableCellText()
    }

    func clearTableCellText() {
        tableAction { t, r in
            t.normalizeCells()
            for row in r.r0...r.r1 { for col in r.c0...r.c1 { t.cells[row][col] = "" } }
        }
    }

    /// 貼上：從選取範圍的左上那格開始，照拷貝時的相對位置填（超出表格的不貼）。
    /// 別的 App 的文字：有 Tab 就當成表格（Tab 分欄、換行分列），沒有就整段放進一格
    func pasteTableCells() {
        guard let s = selectedTable() else { return }
        let pb = UIPasteboard.general
        let grid: [[String]]
        if let c = tableCellClipboard, c.changeCount == pb.changeCount {
            grid = c.cells
        } else if let text = pb.string, !text.isEmpty {
            grid = text.contains("\t") ? text.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") } : [[text]]
        } else {
            return
        }
        let (r0, c0) = tableSelectionAnchor()
        modifyTable(s.ref) { t in
            t.normalizeCells()
            for (i, line) in grid.enumerated() {
                for (j, text) in line.enumerated() {
                    let r = r0 + i, c = c0 + j
                    guard r < t.rows, c < t.cols, t.isAnchor(r, c) else { continue }
                    t.cells[r][c] = text
                }
            }
        }
        // 選起貼上的範圍
        if let t = selectedTable()?.table {
            let width = grid.map(\.count).max() ?? 1
            tableCellSel = t.expanded(CellRange((r0, c0), (min(r0 + grid.count - 1, t.rows - 1), min(c0 + width - 1, t.cols - 1))))
        }
        updateTableCellChrome()
    }

    // MARK: - 分割（不用打字：加減欄數、列數）

    func presentSplitPanel(anchor: TablePanelAnchor) {
        guard let s = selectedTable() else { return }
        let range = s.table.expanded(tableCellSel ?? CellRange((0, 0), (0, 0)))
        let span = s.table.span(range.r0, range.c0)
        let single = span.rowSpan == range.r1 - range.r0 + 1 && span.colSpan == range.c1 - range.c0 + 1
        let merged = single && span.rowSpan * span.colSpan > 1
        let panel = TableSplitPanel(title: single ? "分割 \(cellLabel(range))" : "分割選取的每一格（\(cellLabel(range))）",
                                    cols: single ? max(2, span.colSpan) : 2, rows: single ? span.rowSpan : 1, canUnmerge: merged,
                                    onSplit: { [weak self] c, r in
                                        self?.dismissToolPopover()
                                        self?.tableAction { t, sel in t.splitCells(sel, cols: c, rows: r) }
                                        self?.tableCellSel = nil
                                        self?.updateTableCellChrome()
                                    },
                                    onUnmerge: { [weak self] in
                                        self?.dismissToolPopover()
                                        self?.tableAction { t, r in t.unmerge(r.r0, r.c0) }
                                    })
        presentTablePanel(hosting(panel), anchor: anchor, size: CGSize(width: 320, height: 340))
    }

    // MARK: - 插入表格（拖格子選大小，或直接打數字）

    func presentInsertTablePanel(anchor: TablePanelAnchor, at p: CGPoint? = nil) {
        let page = pages.isEmpty ? CGSize(width: 595, height: 842) : session.baseSize(of: pages[currentPageIndex])
        let panel = TableInsertPanel { [weak self] cols, rows in
            guard let self else { return }
            self.dismissToolPopover()
            let t = TableData.fitted(rows: rows, cols: cols, page: page)
            _ = self.insertElement(.table(t), size: t.size, at: p)
        }
        presentTablePanel(hosting(panel), anchor: anchor, size: CGSize(width: 320, height: 440))
    }
}

/// 分割儲存格：用 ＋／− 選要分成幾欄、幾列，上面看得到切完的樣子
struct TableSplitPanel: View {
    let title: String
    @State var cols: Int
    @State var rows: Int
    let canUnmerge: Bool
    let onSplit: (_ cols: Int, _ rows: Int) -> Void
    let onUnmerge: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            Canvas { ctx, size in
                let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                var p = Path(r)
                for i in 1..<max(cols, 1) {
                    let x = r.minX + r.width * CGFloat(i) / CGFloat(cols)
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                }
                for i in 1..<max(rows, 1) {
                    let y = r.minY + r.height * CGFloat(i) / CGFloat(rows)
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
                ctx.stroke(p, with: .color(.accentColor), lineWidth: 1.5)
            }
            .frame(width: 160, height: 90)
            Stepper("左右分成 \(cols) 欄", value: $cols, in: 1...20)
            Stepper("上下分成 \(rows) 列", value: $rows, in: 1...20)
            HStack {
                if canUnmerge { Button("取消合併", action: onUnmerge) }
                Spacer()
                Button("分割") { onSplit(cols, rows) }
                    .buttonStyle(.borderedProminent)
                    .disabled(cols * rows <= 1)
            }
        }
        .padding(18)
    }
}

/// 插入表格：在格子上拖曳選大小（不用打數字），比格子大的表格直接打欄數、列數
struct TableInsertPanel: View {
    static let maxCount = 40

    let onInsert: (_ cols: Int, _ rows: Int) -> Void
    @State private var cols = 3
    @State private var rows = 3
    private let gridCols = 10, gridRows = 8, cell: CGFloat = 22, gap: CGFloat = 3

    var body: some View {
        VStack(spacing: 12) {
            Text("插入表格").font(.headline)
            VStack(spacing: gap) {
                ForEach(0..<gridRows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<gridCols, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(c < cols && r < rows ? Color.accentColor.opacity(0.75) : Color.gray.opacity(0.18))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                cols = min(max(Int(v.location.x / (cell + gap)) + 1, 1), gridCols)
                rows = min(max(Int(v.location.y / (cell + gap)) + 1, 1), gridRows)
            })
            CountField(label: "欄", value: $cols, range: 1...Self.maxCount)
            CountField(label: "列", value: $rows, range: 1...Self.maxCount)
            Button("插入 \(cols) × \(rows) 表格") { onInsert(cols, rows) }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}

/// 打數字或按 ＋／−；打到一半（空白）不改，超出範圍就拉回來
private struct CountField: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(label, text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
            Text(label)
            Spacer(minLength: 8)
            Stepper(label, value: $value, in: range).labelsHidden()
        }
        .frame(width: 240)
        .onAppear { text = "\(value)" }
        .onChange(of: value) { _, v in
            if Int(text) != v { text = "\(v)" }
        }
        .onChange(of: text) { _, t in
            guard let n = Int(t) else { return }
            let clamped = min(max(n, range.lowerBound), range.upperBound)
            if clamped != value { value = clamped }
            if clamped != n { text = "\(clamped)" }
        }
    }
}

/// 調色盤：一格一個顏色，點了就套用；clearTitle 不是 nil 時多一個「無」（回傳 nil）
struct ColorPalettePanel: View {
    static let colors: [[String]] = [
        ["#FFFFFFFF", "#F2F2F2FF", "#D9D9D9FF", "#BFBFBFFF", "#808080FF", "#595959FF", "#333333FF", "#000000FF"],
        ["#FFCDD2FF", "#F8BBD0FF", "#E1BEE7FF", "#C5CAE9FF", "#BBDEFBFF", "#C8E6C9FF", "#FFF59DFF", "#FFE0B2FF"],
        ["#EF9A9AFF", "#F48FB1FF", "#CE93D8FF", "#9FA8DAFF", "#90CAF9FF", "#A5D6A7FF", "#FFF176FF", "#FFCC80FF"],
        ["#E53935FF", "#D81B60FF", "#8E24AAFF", "#3949ABFF", "#1E88E5FF", "#43A047FF", "#FDD835FF", "#FB8C00FF"],
        ["#B71C1CFF", "#880E4FFF", "#4A148CFF", "#1A237EFF", "#0D47A1FF", "#1B5E20FF", "#F57F17FF", "#E65100FF"],
    ]

    let title: String
    let selected: String?
    let clearTitle: String?
    let onPick: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            VStack(spacing: 6) {
                ForEach(Self.colors, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { hex in swatch(hex) }
                    }
                }
            }
            if let clearTitle {
                Button { onPick(nil) } label: { Label(clearTitle, systemImage: "circle.slash") }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private func swatch(_ hex: String) -> some View {
        let on = selected?.uppercased() == hex
        return Button { onPick(hex) } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(uiColor: UIColor(hex: hex)))
                .frame(width: 30, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: on ? 3 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex)
    }
}
