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

    /// 擦線：p 是到目前為止擦過的路徑（文件座標）。會被擦掉的線先變半透明
    func previewTableErase(_ ref: ElementRef, points: [CGPoint]) {
        guard case let (pi, ei)? = locate(ref), case let .table(t) = pages[pi].elements[ei].content else { return }
        let o = docFrame(of: pages[pi].elements[ei], pageIndex: pi).origin
        tableErasePreview = t.erasedLines(points.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) }, tolerance: 10 / canvas.zoomScale)
        overlay.showFadedLines(tableErasePreview.map { (CGPoint(x: $0.from.x + o.x, y: $0.from.y + o.y), CGPoint(x: $0.to.x + o.x, y: $0.to.y + o.y)) },
                               width: t.lineWidth + 3)
    }

    /// 擦線放開：擦掉預覽裡的線（合併兩邊的格子）
    func finishTableErase(_ ref: ElementRef, points: [CGPoint]) {
        previewTableErase(ref, points: points)
        let ranges = tableErasePreview.map(\.range)
        tableErasePreview = []
        overlay.showFadedLines([], width: 0)
        guard !ranges.isEmpty else { return }
        modifyTable(ref) { for r in ranges { $0.mergeCells(r) } }
        updateTableDraftChrome()
    }

    // MARK: - 欄、列標頭

    /// 選到表格時，上方的欄標頭、左邊的列標頭（文件座標）
    func tableHeaderRects() -> (cols: [CGRect], rows: [CGRect])? {
        guard tool == .select, editingTextView == nil, let s = selectedTable(), s.table.rows > 0, s.table.cols > 0 else { return nil }
        let t = s.table, o = s.docRect.origin
        let h = 20 / canvas.zoomScale, gap = 4 / canvas.zoomScale
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
        }
    }

    /// 選取範圍在文件上的位置（小視窗指著它）
    func tableSelectionDocRect() -> CGRect? {
        guard let s = selectedTable() else { return nil }
        let r = tableCellSel ?? CellRange((0, 0), (s.table.rows - 1, s.table.cols - 1))
        return s.table.rangeRect(r).offsetBy(dx: s.docRect.minX, dy: s.docRect.minY)
    }

    /// 列與欄：插入、刪除、重複、平均分配、鎖定寬高（照目前選取的範圍）
    func tableRowColItems(anchor: TablePanelAnchor) -> [UIMenuElement] {
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
            UIAction(title: "重複…", image: UIImage(systemName: "square.stack.3d.down.right")) { [weak self] _ in
                self?.presentRepeatPanel(anchor: anchor)
            },
            UIMenu(title: "平均分配", image: UIImage(systemName: "arrow.left.and.right"), children: [
                tableAct("平均分配欄寬（\(r.c1 > r.c0 ? colsName : "全部欄")）") { t, r in t.distributeColumns(r.c1 > r.c0 ? r.c0...r.c1 : nil) },
                tableAct("平均分配列高（\(r.r1 > r.r0 ? rowsName : "全部列")）") { t, r in t.distributeRows(r.r1 > r.r0 ? r.r0...r.r1 : nil) },
            ]),
            UIMenu(title: "鎖定寬高", image: UIImage(systemName: "lock.rectangle"), children: [
                tableAct("鎖定欄寬（\(colsName)）", "lock") { t, r in t.setColsLocked(r.c0...r.c1, true) },
                tableAct("鎖定列高（\(rowsName)）", "lock") { t, r in t.setRowsLocked(r.r0...r.r1, true) },
                tableAct("解除選取範圍的鎖定", "lock.open") { t, r in
                    t.setColsLocked(r.c0...r.c1, false)
                    t.setRowsLocked(r.r0...r.r1, false)
                },
                tableAct("解除全部鎖定", "lock.open", attributes: .destructive) { t, _ in
                    t.lockedCols = []
                    t.lockedRows = []
                },
            ]),
            UIMenu(title: "刪除", image: UIImage(systemName: "minus.rectangle"), children: [
                tableAct("刪除\(rowsName)", attributes: .destructive) { t, r in for row in (r.r0...r.r1).reversed() { t.removeRow(row) } },
                tableAct("刪除\(colsName)", attributes: .destructive) { t, r in for col in (r.c0...r.c1).reversed() { t.removeColumn(col) } },
                UIAction(title: "刪除整個表格", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    guard let self, let s = self.selectedTable() else { return }
                    self.deleteElement(s.ref)
                },
            ]),
        ]
    }

    /// 儲存格：合併、分割、取消合併、斜線、底色
    func tableCellItems(anchor: TablePanelAnchor) -> [UIMenuElement] {
        guard let s = selectedTable() else { return [] }
        let r = s.table.expanded(tableCellSel ?? CellRange((0, 0), (0, 0)))
        let span = s.table.span(r.r0, r.c0)
        let single = span.rowSpan == r.r1 - r.r0 + 1 && span.colSpan == r.c1 - r.c0 + 1
        var items: [UIMenuElement] = [
            UIAction(title: "合併", image: TableIcons.merge, attributes: single ? .disabled : []) { [weak self] _ in
                self?.tableAction { t, r in t.mergeCells(r) }
            },
            UIAction(title: single ? "分割…" : "分割每一格…", image: TableIcons.split) { [weak self] _ in
                self?.presentSplitPanel(anchor: anchor)
            },
        ]
        if single && span.rowSpan * span.colSpan > 1 {
            items.append(tableAct("取消合併", "square.split.2x2") { t, r in t.unmerge(r.r0, r.c0) })
        }
        let fills: [(String, String?)] = [("黃色", "#FFF59DFF"), ("綠色", "#C8E6C9FF"), ("藍色", "#BBDEFBFF"),
                                          ("粉紅", "#F8BBD0FF"), ("灰色", "#E0E0E0FF"), ("無底色", nil)]
        items.append(UIMenu(title: "底色", image: UIImage(systemName: "drop.fill"), children: fills.map { name, hex in
            tableAct(name, hex == nil ? "circle.slash" : "circle.fill") { t, r in t.setFill(r, hex: hex) }
        }))
        items.append(UIMenu(title: "斜線", image: UIImage(systemName: "line.diagonal"), children: [
            tableAct("左上到右下") { t, r in t.setDiagonal(r.r0, r.c0, reverse: false) },
            tableAct("右上到左下") { t, r in t.setDiagonal(r.r0, r.c0, reverse: true) },
            tableAct("移除斜線", attributes: .destructive) { t, r in t.setDiagonal(r.r0, r.c0, reverse: nil) },
        ]))
        return items
    }

    /// 樣式：格線顏色粗細、字級
    func tableStyleItems() -> [UIMenuElement] {
        [
            UIMenu(title: "格線", image: UIImage(systemName: "squareshape.split.3x3"), children: [
                tableAct("黑色") { t, _ in t.lineColorHex = "#333333FF" },
                tableAct("灰色") { t, _ in t.lineColorHex = "#9E9E9EFF" },
                tableAct("藍色") { t, _ in t.lineColorHex = "#1E5BD8FF" },
                tableAct("紅色") { t, _ in t.lineColorHex = "#D32F2FFF" },
                tableAct("加粗", "plus") { t, _ in t.lineWidth = min(t.lineWidth + 0.5, 5) },
                tableAct("變細", "minus") { t, _ in t.lineWidth = max(t.lineWidth - 0.5, 0.5) },
            ]),
            UIMenu(title: "字級", image: UIImage(systemName: "textformat.size"), children: [
                tableAct("字放大", "plus") { t, _ in t.fontSize = min(t.fontSize + 2, 48) },
                tableAct("字縮小", "minus") { t, _ in t.fontSize = max(t.fontSize - 2, 8) },
            ]),
        ]
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

    // MARK: - 插入表格（拖格子選大小，或用範本）

    func presentInsertTablePanel(anchor: TablePanelAnchor, at p: CGPoint? = nil) {
        let pageW = pages.isEmpty ? 595 : session.baseSize(of: pages[currentPageIndex]).width
        let panel = TableInsertPanel { [weak self] choice in
            guard let self else { return }
            self.dismissToolPopover()
            let t: TableData
            switch choice {
            case let .size(cols, rows):
                let cellW = min(140, max(40, (pageW * 0.85) / CGFloat(cols)))
                t = TableData.make(rows: rows, cols: cols, cellWidth: cellW.rounded(), cellHeight: 44)
            case let .template(k):
                t = k.table
            }
            _ = self.insertElement(.table(t), size: t.size, at: p)
        }
        presentTablePanel(hosting(panel), anchor: anchor, size: CGSize(width: 340, height: 520))
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

/// 插入表格：在格子上拖曳選大小（不用打數字），或選一個範本
struct TableInsertPanel: View {
    enum Choice {
        case size(cols: Int, rows: Int)
        case template(TableTemplate)
    }

    let onInsert: (Choice) -> Void
    @State private var cols = 3
    @State private var rows = 3
    private let maxCols = 10, maxRows = 8, cell: CGFloat = 22, gap: CGFloat = 3

    var body: some View {
        VStack(spacing: 12) {
            Text("插入表格").font(.headline)
            Text("\(cols) 欄 × \(rows) 列").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            VStack(spacing: gap) {
                ForEach(0..<maxRows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<maxCols, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(c < cols && r < rows ? Color.accentColor.opacity(0.75) : Color.gray.opacity(0.18))
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                cols = min(max(Int(v.location.x / (cell + gap)) + 1, 1), maxCols)
                rows = min(max(Int(v.location.y / (cell + gap)) + 1, 1), maxRows)
            })
            Button("插入 \(cols) × \(rows) 表格") { onInsert(.size(cols: cols, rows: rows)) }
                .buttonStyle(.borderedProminent)
            Divider()
            Text("範本").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(TableTemplate.allCases) { k in
                    Button { onInsert(.template(k)) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: k.symbol).font(.title3)
                            Text(k.title).font(.caption)
                        }
                        .frame(width: 64, height: 54)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
    }
}
