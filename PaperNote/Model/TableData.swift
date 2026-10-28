import Foundation
import CoreGraphics

/// 合併儲存格範圍（左上角 row/col＋跨幾列幾欄）
struct CellMerge: Codable, Equatable {
    var row: Int
    var col: Int
    var rowSpan: Int
    var colSpan: Int

    func contains(_ r: Int, _ c: Int) -> Bool {
        r >= row && r < row + rowSpan && c >= col && c < col + colSpan
    }

    func intersects(r0: Int, c0: Int, r1: Int, c1: Int) -> Bool {
        row <= r1 && row + rowSpan - 1 >= r0 && col <= c1 && col + colSpan - 1 >= c0
    }
}

/// 儲存格斜線；reverse = 右上到左下
struct CellDiagonal: Codable, Equatable {
    var row: Int
    var col: Int
    var reverse: Bool
}

struct CellFill: Codable, Equatable {
    var row: Int
    var col: Int
    var hex: String
}

/// 重複一組列（或欄）做成大表格：原本那組從 start 開始、有 length 列；往下／右（before = false）或往上／左複製 count 組。
/// 記在表格裡，之後改 count 會增減組數
struct TableRepeat: Codable, Equatable {
    enum Axis: String, Codable { case rows, cols }
    var axis: Axis
    var start: Int
    var length: Int
    var before: Bool
    var count: Int

    /// 原本那組加上所有複製的範圍
    var span: Range<Int> {
        before ? (start - length * count)..<(start + length) : start..<(start + length * (count + 1))
    }
}

/// 儲存格範圍（已正規化：r0 <= r1、c0 <= c1）
struct CellRange: Equatable {
    var r0: Int, c0: Int, r1: Int, c1: Int

    init(_ a: (row: Int, col: Int), _ b: (row: Int, col: Int)) {
        r0 = min(a.row, b.row); r1 = max(a.row, b.row)
        c0 = min(a.col, b.col); c1 = max(a.col, b.col)
    }

    var isSingle: Bool { r0 == r1 && c0 == c1 }
}

struct TableData: Codable, Equatable {
    var colWidths: [CGFloat]
    var rowHeights: [CGFloat]
    var cells: [[String]]
    var lineColorHex: String = "#333333FF"
    var lineWidth: CGFloat = 2
    var fontSize: CGFloat = 16
    var merges: [CellMerge] = []
    var diagonals: [CellDiagonal] = []
    var fills: [CellFill] = []
    /// 鎖定高度的列、鎖定寬度的欄：縮放表格、平均分配時不會變
    var lockedRows: [Int] = []
    var lockedCols: [Int] = []
    /// 最近一次「重複」做出來的那一組（可以再改組數）
    var repeatGroup: TableRepeat?

    static let minCell: CGFloat = 24

    enum CodingKeys: String, CodingKey {
        case colWidths, rowHeights, cells, lineColorHex, lineWidth, fontSize, merges, diagonals, fills
        case lockedRows, lockedCols, repeatGroup
    }

    var rows: Int { rowHeights.count }
    var cols: Int { colWidths.count }
    var size: CGSize { CGSize(width: colWidths.reduce(0, +), height: rowHeights.reduce(0, +)) }

    static func make(rows: Int, cols: Int, cellWidth: CGFloat = 120, cellHeight: CGFloat = 48) -> TableData {
        TableData(colWidths: Array(repeating: cellWidth, count: cols),
                  rowHeights: Array(repeating: cellHeight, count: rows),
                  cells: Array(repeating: Array(repeating: "", count: cols), count: rows))
    }

    // MARK: 幾何

    /// 第 c 條直線的 x（0 為左邊框，cols 為右邊框）
    func colX(_ c: Int) -> CGFloat { colWidths.prefix(c).reduce(0, +) }
    func rowY(_ r: Int) -> CGFloat { rowHeights.prefix(r).reduce(0, +) }

    func rowIndex(at y: CGFloat) -> Int? {
        guard y >= 0 else { return nil }
        var acc: CGFloat = 0
        for (i, h) in rowHeights.enumerated() { if y < acc + h { return i }; acc += h }
        return nil
    }

    func colIndex(at x: CGFloat) -> Int? {
        guard x >= 0 else { return nil }
        var acc: CGFloat = 0
        for (i, w) in colWidths.enumerated() { if x < acc + w { return i }; acc += w }
        return nil
    }

    func merge(at r: Int, _ c: Int) -> CellMerge? { merges.first { $0.contains(r, c) } }

    /// 合併儲存格的左上角（沒合併就是自己）
    func anchor(_ r: Int, _ c: Int) -> (row: Int, col: Int) {
        if let m = merge(at: r, c) { return (m.row, m.col) }
        return (r, c)
    }

    func isAnchor(_ r: Int, _ c: Int) -> Bool {
        guard let m = merge(at: r, c) else { return true }
        return m.row == r && m.col == c
    }

    func span(_ r: Int, _ c: Int) -> CellMerge {
        merge(at: r, c) ?? CellMerge(row: r, col: c, rowSpan: 1, colSpan: 1)
    }

    /// 儲存格（含合併範圍）的矩形
    func cellRect(row: Int, col: Int) -> CGRect {
        let m = span(row, col)
        let x = colX(m.col), y = rowY(m.row)
        return CGRect(x: x, y: y, width: colX(m.col + m.colSpan) - x, height: rowY(m.row + m.rowSpan) - y)
    }

    func rangeRect(_ r: CellRange) -> CGRect {
        let x = colX(r.c0), y = rowY(r.r0)
        return CGRect(x: x, y: y, width: colX(r.c1 + 1) - x, height: rowY(r.r1 + 1) - y)
    }

    /// 點到的儲存格（合併的話回傳左上角）
    func cell(at p: CGPoint) -> (row: Int, col: Int)? {
        guard let r = rowIndex(at: p.y), let c = colIndex(at: p.x) else { return nil }
        return anchor(r, c)
    }

    // MARK: 格線是否看得到（被合併格蓋住的那段不算）

    /// 第 r 條橫線在第 col 欄那一段是否看得到
    func isRowLineVisible(_ r: Int, atColumn col: Int) -> Bool {
        guard r > 0, r < rows else { return true }
        if let m = merge(at: r - 1, col), m.contains(r, col) { return false }
        return true
    }

    /// 第 c 條直線在第 row 列那一段是否看得到
    func isColLineVisible(_ c: Int, atRow row: Int) -> Bool {
        guard c > 0, c < cols else { return true }
        if let m = merge(at: row, c - 1), m.contains(row, c) { return false }
        return true
    }

    func rowLineVisibleAnywhere(_ r: Int) -> Bool { (0..<cols).contains { isRowLineVisible(r, atColumn: $0) } }
    func colLineVisibleAnywhere(_ c: Int) -> Bool { (0..<rows).contains { isColLineVisible(c, atRow: $0) } }

    /// 擴大範圍直到完整包含所有碰到的合併儲存格
    func expanded(_ range: CellRange) -> CellRange {
        var r = range
        var changed = true
        while changed {
            changed = false
            for m in merges where m.intersects(r0: r.r0, c0: r.c0, r1: r.r1, c1: r.c1) {
                let nr0 = min(r.r0, m.row), nc0 = min(r.c0, m.col)
                let nr1 = max(r.r1, m.row + m.rowSpan - 1), nc1 = max(r.c1, m.col + m.colSpan - 1)
                if nr0 != r.r0 || nc0 != r.c0 || nr1 != r.r1 || nc1 != r.c1 {
                    r.r0 = nr0; r.c0 = nc0; r.r1 = nr1; r.c1 = nc1
                    changed = true
                }
            }
        }
        return r
    }

    // MARK: 文字

    func text(row: Int, col: Int) -> String {
        guard row < cells.count, col < cells[row].count else { return "" }
        return cells[row][col]
    }

    mutating func setText(_ text: String, row: Int, col: Int) {
        normalizeCells()
        guard row < rows, col < cols else { return }
        cells[row][col] = text
    }

    mutating func normalizeCells() {
        while cells.count < rows { cells.append(Array(repeating: "", count: cols)) }
        if cells.count > rows { cells.removeLast(cells.count - rows) }
        for r in cells.indices {
            while cells[r].count < cols { cells[r].append("") }
            if cells[r].count > cols { cells[r].removeLast(cells[r].count - cols) }
        }
        let rowCount = rows, colCount = cols
        merges.removeAll { $0.row < 0 || $0.col < 0 || $0.row + $0.rowSpan > rowCount || $0.col + $0.colSpan > colCount
            || $0.rowSpan * $0.colSpan <= 1 }
        diagonals.removeAll { $0.row >= rowCount || $0.col >= colCount }
        fills.removeAll { $0.row >= rowCount || $0.col >= colCount }
        lockedRows = Array(Set(lockedRows.filter { $0 >= 0 && $0 < rowCount })).sorted()
        lockedCols = Array(Set(lockedCols.filter { $0 >= 0 && $0 < colCount })).sorted()
        if let g = repeatGroup, g.span.lowerBound < 0 || g.span.upperBound > (g.axis == .rows ? rowCount : colCount) { repeatGroup = nil }
    }

    // MARK: 插入／刪除列欄

    mutating func insertRow(at r: Int, height: CGFloat? = nil) {
        normalizeCells()
        let h = height ?? (rowHeights.isEmpty ? 48 : rowHeights[max(0, min(r, rows) - 1)])
        rowHeights.insert(h, at: r)
        cells.insert(Array(repeating: "", count: cols), at: r)
        for i in merges.indices {
            if merges[i].row >= r { merges[i].row += 1 } else if merges[i].row + merges[i].rowSpan > r { merges[i].rowSpan += 1 }
        }
        for i in diagonals.indices where diagonals[i].row >= r { diagonals[i].row += 1 }
        for i in fills.indices where fills[i].row >= r { fills[i].row += 1 }
        lockedRows = lockedRows.map { $0 >= r ? $0 + 1 : $0 }
        if var g = repeatGroup, g.axis == .rows {
            // 插在整組前面：整組往後移；插在組裡面：組的結構變了，不再記
            if r <= g.span.lowerBound { g.start += 1; repeatGroup = g } else if r < g.span.upperBound { repeatGroup = nil }
        }
    }

    mutating func insertColumn(at c: Int, width: CGFloat? = nil) {
        normalizeCells()
        let w = width ?? (colWidths.isEmpty ? 120 : colWidths[max(0, min(c, cols) - 1)])
        colWidths.insert(w, at: c)
        for r in cells.indices { cells[r].insert("", at: c) }
        for i in merges.indices {
            if merges[i].col >= c { merges[i].col += 1 } else if merges[i].col + merges[i].colSpan > c { merges[i].colSpan += 1 }
        }
        for i in diagonals.indices where diagonals[i].col >= c { diagonals[i].col += 1 }
        for i in fills.indices where fills[i].col >= c { fills[i].col += 1 }
        lockedCols = lockedCols.map { $0 >= c ? $0 + 1 : $0 }
        if var g = repeatGroup, g.axis == .cols {
            if c <= g.span.lowerBound { g.start += 1; repeatGroup = g } else if c < g.span.upperBound { repeatGroup = nil }
        }
    }

    mutating func removeRow(_ r: Int) {
        guard rows > 1, r < rows else { return }
        normalizeCells()
        rowHeights.remove(at: r)
        cells.remove(at: r)
        merges = merges.compactMap { m in
            var m = m
            if m.row > r { m.row -= 1 } else if m.row + m.rowSpan > r { m.rowSpan -= 1 }
            return m.rowSpan >= 1 && m.rowSpan * m.colSpan > 1 ? m : nil
        }
        diagonals = diagonals.compactMap { d in
            var d = d
            if d.row == r { return nil }
            if d.row > r { d.row -= 1 }
            return d
        }
        fills = fills.compactMap { f in
            var f = f
            if f.row == r { return nil }
            if f.row > r { f.row -= 1 }
            return f
        }
        lockedRows = lockedRows.compactMap { $0 == r ? nil : ($0 > r ? $0 - 1 : $0) }
        if var g = repeatGroup, g.axis == .rows {
            if r < g.span.lowerBound { g.start -= 1; repeatGroup = g } else if g.span.contains(r) { repeatGroup = nil }
        }
    }

    mutating func removeColumn(_ c: Int) {
        guard cols > 1, c < cols else { return }
        normalizeCells()
        colWidths.remove(at: c)
        for r in cells.indices { cells[r].remove(at: c) }
        merges = merges.compactMap { m in
            var m = m
            if m.col > c { m.col -= 1 } else if m.col + m.colSpan > c { m.colSpan -= 1 }
            return m.colSpan >= 1 && m.rowSpan * m.colSpan > 1 ? m : nil
        }
        diagonals = diagonals.compactMap { d in
            var d = d
            if d.col == c { return nil }
            if d.col > c { d.col -= 1 }
            return d
        }
        fills = fills.compactMap { f in
            var f = f
            if f.col == c { return nil }
            if f.col > c { f.col -= 1 }
            return f
        }
        lockedCols = lockedCols.compactMap { $0 == c ? nil : ($0 > c ? $0 - 1 : $0) }
        if var g = repeatGroup, g.axis == .cols {
            if c < g.span.lowerBound { g.start -= 1; repeatGroup = g } else if g.span.contains(c) { repeatGroup = nil }
        }
    }

    // MARK: 合併／分割

    mutating func mergeCells(_ range: CellRange) {
        normalizeCells()
        let r = expanded(range)
        guard !r.isSingle else { return }
        var texts: [String] = []
        for row in r.r0...r.r1 {
            for col in r.c0...r.c1 {
                let t = text(row: row, col: col).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { texts.append(t) }
                cells[row][col] = ""
            }
        }
        cells[r.r0][r.c0] = texts.joined(separator: "\n")
        merges.removeAll { $0.intersects(r0: r.r0, c0: r.c0, r1: r.r1, c1: r.c1) }
        merges.append(CellMerge(row: r.r0, col: r.c0, rowSpan: r.r1 - r.r0 + 1, colSpan: r.c1 - r.c0 + 1))
        diagonals.removeAll { $0.row >= r.r0 && $0.row <= r.r1 && $0.col >= r.c0 && $0.col <= r.c1 && !($0.row == r.r0 && $0.col == r.c0) }
        fills.removeAll { $0.row >= r.r0 && $0.row <= r.r1 && $0.col >= r.c0 && $0.col <= r.c1 && !($0.row == r.r0 && $0.col == r.c0) }
    }

    mutating func unmerge(_ r: Int, _ c: Int) {
        merges.removeAll { $0.contains(r, c) }
    }

    /// 在第 r 列內 offset 處加一條橫線，只切開 columns 裡的欄（其他欄維持一格）
    mutating func splitRow(_ r: Int, at offset: CGFloat, columns split: Set<Int>) {
        guard r < rows, !split.isEmpty else { return }
        let total = rowHeights[r]
        let top = min(max(offset, 12), total - 12)
        guard top >= 12, total - top >= 12 else { return }
        // 跨欄合併且剛好在這列結束的儲存格，下面新的一列也要跨欄
        let endingMerges = merges.filter { $0.row + $0.rowSpan - 1 == r && $0.colSpan > 1 }
        insertRow(at: r + 1, height: total - top)
        rowHeights[r] = top
        if lockedRows.contains(r) { lockedRows.append(r + 1) }
        for m in endingMerges where (m.col..<(m.col + m.colSpan)).contains(where: { split.contains($0) }) {
            merges.append(CellMerge(row: r + 1, col: m.col, rowSpan: 1, colSpan: m.colSpan))
        }
        for c in 0..<cols where !split.contains(c) {
            if let i = merges.firstIndex(where: { $0.contains(r, c) }) {
                if !merges[i].contains(r + 1, c) { merges[i].rowSpan += 1 }
            } else {
                merges.append(CellMerge(row: r, col: c, rowSpan: 2, colSpan: 1))
            }
        }
    }

    /// 在第 c 欄內 offset 處加一條直線，只切開 rows 裡的列
    mutating func splitColumn(_ c: Int, at offset: CGFloat, rows split: Set<Int>) {
        guard c < cols, !split.isEmpty else { return }
        let total = colWidths[c]
        let left = min(max(offset, 12), total - 12)
        guard left >= 12, total - left >= 12 else { return }
        let endingMerges = merges.filter { $0.col + $0.colSpan - 1 == c && $0.rowSpan > 1 }
        insertColumn(at: c + 1, width: total - left)
        colWidths[c] = left
        if lockedCols.contains(c) { lockedCols.append(c + 1) }
        for m in endingMerges where (m.row..<(m.row + m.rowSpan)).contains(where: { split.contains($0) }) {
            merges.append(CellMerge(row: m.row, col: c + 1, rowSpan: m.rowSpan, colSpan: 1))
        }
        for r in 0..<rows where !split.contains(r) {
            if let i = merges.firstIndex(where: { $0.contains(r, c) }) {
                if !merges[i].contains(r, c + 1) { merges[i].colSpan += 1 }
            } else {
                merges.append(CellMerge(row: r, col: c, rowSpan: 1, colSpan: 2))
            }
        }
    }

    /// 像 Word 的「分割儲存格」：把一格（或合併格）分成 cols 欄 × rows 列
    mutating func splitCell(_ r: Int, _ c: Int, cols n: Int, rows m: Int) {
        guard n >= 1, m >= 1, r < rows, c < cols else { return }
        let region = span(r, c)
        let top = region.row, left = region.col
        var rCount = region.rowSpan, cCount = region.colSpan
        unmerge(r, c)

        // 1. 欄不夠就加直線（只切開這個範圍的列）
        if cCount < n {
            if cCount == 1 {
                if colWidths[left] / CGFloat(n) < 12 { colWidths[left] = CGFloat(n) * 24 }
                let piece = colWidths[left] / CGFloat(n)
                for i in 0..<(n - 1) {
                    splitColumn(left + i, at: piece, rows: Set(top..<(top + rCount)))
                }
            } else {
                while cCount < n {
                    let range = left..<(left + cCount)
                    guard let widest = range.max(by: { colWidths[$0] < colWidths[$1] }) else { break }
                    if colWidths[widest] < 24 { colWidths[widest] = 24 }
                    splitColumn(widest, at: colWidths[widest] / 2, rows: Set(top..<(top + rCount)))
                    cCount += 1
                }
            }
            cCount = max(cCount, n)
        }
        // 2. 列不夠就加橫線（只切開這個範圍的欄）
        if rCount < m {
            if rCount == 1 {
                if rowHeights[top] / CGFloat(m) < 12 { rowHeights[top] = CGFloat(m) * 24 }
                let piece = rowHeights[top] / CGFloat(m)
                for i in 0..<(m - 1) {
                    splitRow(top + i, at: piece, columns: Set(left..<(left + cCount)))
                }
            } else {
                while rCount < m {
                    let range = top..<(top + rCount)
                    guard let tallest = range.max(by: { rowHeights[$0] < rowHeights[$1] }) else { break }
                    if rowHeights[tallest] < 24 { rowHeights[tallest] = 24 }
                    splitRow(tallest, at: rowHeights[tallest] / 2, columns: Set(left..<(left + cCount)))
                    rCount += 1
                }
            }
            rCount = max(rCount, m)
        }
        // 3. 原本比較多格（合併格）→ 依序分組合併成 n × m
        func groups(_ count: Int, _ parts: Int) -> [(start: Int, length: Int)] {
            let base = count / parts, extra = count % parts
            var out: [(start: Int, length: Int)] = []
            var start = 0
            for i in 0..<parts {
                let len = base + (i < extra ? 1 : 0)
                out.append((start: start, length: len))
                start += len
            }
            return out
        }
        // 先清掉範圍內 splitColumn／splitRow 為其他格自動產生的合併
        merges.removeAll { $0.row >= top && $0.row + $0.rowSpan <= top + rCount && $0.col >= left && $0.col + $0.colSpan <= left + cCount }
        for rg in groups(rCount, m) {
            for cg in groups(cCount, n) where rg.length * cg.length > 1 {
                merges.append(CellMerge(row: top + rg.start, col: left + cg.start, rowSpan: rg.length, colSpan: cg.length))
            }
        }
        normalizeCells()
    }

    /// 選了很多格一起分割：選取範圍裡的每一欄切成 n 欄、每一列切成 m 列（只切開選取的範圍，其他格不變）。
    /// 只選一格（或一個合併格）時和 splitCell 一樣
    mutating func splitCells(_ range: CellRange, cols n: Int, rows m: Int) {
        guard n >= 1, m >= 1 else { return }
        let r = expanded(range)
        let a = span(r.r0, r.c0)
        if a.row == r.r0, a.col == r.c0, a.rowSpan == r.r1 - r.r0 + 1, a.colSpan == r.c1 - r.c0 + 1 {
            splitCell(r.r0, r.c0, cols: n, rows: m)
            return
        }
        if n > 1 {
            let rowSet = Set(r.r0...r.r1)
            // 從右邊的欄開始切，左邊的欄號才不會跑掉
            for c in (r.c0...r.c1).reversed() {
                if colWidths[c] / CGFloat(n) < 12 { colWidths[c] = CGFloat(n) * 24 }
                let piece = colWidths[c] / CGFloat(n)
                for i in 0..<(n - 1) { splitColumn(c + i, at: piece, rows: rowSet) }
            }
        }
        if m > 1 {
            let colSet = Set(r.c0...(r.c0 + (r.c1 - r.c0 + 1) * n - 1))
            for row in (r.r0...r.r1).reversed() {
                if rowHeights[row] / CGFloat(m) < 12 { rowHeights[row] = CGFloat(m) * 24 }
                let piece = rowHeights[row] / CGFloat(m)
                for i in 0..<(m - 1) { splitRow(row + i, at: piece, columns: colSet) }
            }
        }
        normalizeCells()
    }

    /// 把一格（或合併格）平分成左右兩格
    mutating func splitCellHorizontally(_ r: Int, _ c: Int) {
        let m = span(r, c)
        if m.colSpan > 1 {
            // 合併格：在中間那條既有直線切成兩個合併格
            unmerge(r, c)
            let mid = m.col + m.colSpan / 2
            merges.append(CellMerge(row: m.row, col: m.col, rowSpan: m.rowSpan, colSpan: mid - m.col))
            merges.append(CellMerge(row: m.row, col: mid, rowSpan: m.rowSpan, colSpan: m.col + m.colSpan - mid))
            normalizeCells()
            return
        }
        splitColumn(m.col, at: colWidths[m.col] / 2, rows: Set(m.row..<(m.row + m.rowSpan)))
    }

    /// 把一格（或合併格）平分成上下兩格
    mutating func splitCellVertically(_ r: Int, _ c: Int) {
        let m = span(r, c)
        if m.rowSpan > 1 {
            unmerge(r, c)
            let mid = m.row + m.rowSpan / 2
            merges.append(CellMerge(row: m.row, col: m.col, rowSpan: mid - m.row, colSpan: m.colSpan))
            merges.append(CellMerge(row: mid, col: m.col, rowSpan: m.row + m.rowSpan - mid, colSpan: m.colSpan))
            normalizeCells()
            return
        }
        splitRow(m.row, at: rowHeights[m.row] / 2, columns: Set(m.col..<(m.col + m.colSpan)))
    }

    // MARK: 斜線、底色、平均分配

    mutating func setDiagonal(_ r: Int, _ c: Int, reverse: Bool?) {
        let a = anchor(r, c)
        diagonals.removeAll { $0.row == a.row && $0.col == a.col }
        if let reverse { diagonals.append(CellDiagonal(row: a.row, col: a.col, reverse: reverse)) }
    }

    func diagonal(_ r: Int, _ c: Int) -> CellDiagonal? {
        let a = anchor(r, c)
        return diagonals.first { $0.row == a.row && $0.col == a.col }
    }

    mutating func setFill(_ range: CellRange, hex: String?) {
        for r in range.r0...range.r1 {
            for c in range.c0...range.c1 where isAnchor(r, c) {
                fills.removeAll { $0.row == r && $0.col == c }
                if let hex { fills.append(CellFill(row: r, col: c, hex: hex)) }
            }
        }
    }

    /// 平均分配欄寬：只分配 range 裡（沒給就是全部）沒鎖定的欄，總寬不變
    mutating func distributeColumns(_ range: ClosedRange<Int>? = nil) {
        guard cols > 0 else { return }
        colWidths = Self.evened(colWidths, Array(range ?? 0...(cols - 1)), locked: Set(lockedCols))
    }

    mutating func distributeRows(_ range: ClosedRange<Int>? = nil) {
        guard rows > 0 else { return }
        rowHeights = Self.evened(rowHeights, Array(range ?? 0...(rows - 1)), locked: Set(lockedRows))
    }

    private static func evened(_ sizes: [CGFloat], _ indices: [Int], locked: Set<Int>) -> [CGFloat] {
        let idx = indices.filter { sizes.indices.contains($0) && !locked.contains($0) }
        guard idx.count > 1 else { return sizes }
        let each = idx.reduce(0) { $0 + sizes[$1] } / CGFloat(idx.count)
        var out = sizes
        for i in idx { out[i] = each }
        return out
    }

    /// 縮放整個表格：鎖定的列高、欄寬不變，其他的照比例分掉
    mutating func scale(to newSize: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        colWidths = Self.scaled(colWidths, to: newSize.width, locked: Set(lockedCols))
        rowHeights = Self.scaled(rowHeights, to: newSize.height, locked: Set(lockedRows))
    }

    private static func scaled(_ sizes: [CGFloat], to total: CGFloat, locked: Set<Int>) -> [CGFloat] {
        let free = sizes.indices.filter { !locked.contains($0) }
        let fixed = sizes.indices.filter { locked.contains($0) }.reduce(0) { $0 + sizes[$1] }
        let freeSum = free.reduce(0) { $0 + sizes[$1] }
        guard !free.isEmpty, freeSum > 0 else { return sizes }
        let k = max(total - fixed, CGFloat(free.count) * minCell) / freeSum
        var out = sizes
        for i in free { out[i] = max(12, sizes[i] * k) }
        return out
    }

    // MARK: 鎖定列高、欄寬

    mutating func setRowsLocked(_ range: ClosedRange<Int>, _ locked: Bool) {
        lockedRows.removeAll { range.contains($0) }
        if locked { lockedRows += Array(range) }
        lockedRows.sort()
    }

    mutating func setColsLocked(_ range: ClosedRange<Int>, _ locked: Bool) {
        lockedCols.removeAll { range.contains($0) }
        if locked { lockedCols += Array(range) }
        lockedCols.sort()
    }

    // MARK: 重複一組列／欄（做大表格）

    /// 把 rows 或 cols 的 [start, start + length) 那一組重複成 count 份（before＝往上／往左）。
    /// 已經是同一組就增減份數：例如原本 15 組改 14，最後（或最前面）那一組會拿掉
    mutating func setRepeat(axis: TableRepeat.Axis, start: Int, length: Int, before: Bool, count: Int) {
        normalizeCells()
        let total = axis == .rows ? rows : cols
        guard length > 0, count >= 0, start >= 0, start + length <= total else { return }
        var g = TableRepeat(axis: axis, start: start, length: length, before: before, count: 0)
        if let old = repeatGroup, old.axis == axis, old.start == start, old.length == length, old.before == before {
            g = old
        }
        // 下面自己插入／刪除列欄時，不要讓 insertRow 等去調整組的位置
        repeatGroup = nil
        while g.count < count {
            let src = g.start..<(g.start + g.length)
            if g.before {
                insertCopy(axis, of: src, at: g.start - g.length * g.count)
                g.start += g.length
            } else {
                insertCopy(axis, of: src, at: g.start + g.length * (g.count + 1))
            }
            g.count += 1
        }
        while g.count > count {
            let first = g.before ? g.start - g.length * g.count : g.start + g.length * g.count
            for _ in 0..<g.length {
                if axis == .rows { removeRow(first) } else { removeColumn(first) }
            }
            if g.before { g.start -= g.length }
            g.count -= 1
        }
        repeatGroup = g.count > 0 ? g : nil
        normalizeCells()
    }

    /// 把 src 那幾列（欄）複製一份插在 dst：大小、文字、合併、斜線、底色、鎖定都一樣
    private mutating func insertCopy(_ axis: TableRepeat.Axis, of src: Range<Int>, at dst: Int) {
        let shift = dst - src.lowerBound
        if axis == .rows {
            let heights = Array(rowHeights[src]), texts = Array(cells[src])
            let ms = merges.filter { $0.row >= src.lowerBound && $0.row + $0.rowSpan <= src.upperBound }
            let ds = diagonals.filter { src.contains($0.row) }, fs = fills.filter { src.contains($0.row) }
            let locks = lockedRows.filter { src.contains($0) }
            for (i, h) in heights.enumerated() { insertRow(at: dst + i, height: h) }
            for i in texts.indices { cells[dst + i] = texts[i] }
            merges += ms.map { var m = $0; m.row += shift; return m }
            diagonals += ds.map { var d = $0; d.row += shift; return d }
            fills += fs.map { var f = $0; f.row += shift; return f }
            lockedRows += locks.map { $0 + shift }
        } else {
            let widths = Array(colWidths[src])
            let texts = cells.map { Array($0[src]) }
            let ms = merges.filter { $0.col >= src.lowerBound && $0.col + $0.colSpan <= src.upperBound }
            let ds = diagonals.filter { src.contains($0.col) }, fs = fills.filter { src.contains($0.col) }
            let locks = lockedCols.filter { src.contains($0) }
            for (i, w) in widths.enumerated() { insertColumn(at: dst + i, width: w) }
            for r in texts.indices { for i in texts[r].indices { cells[r][dst + i] = texts[r][i] } }
            merges += ms.map { var m = $0; m.col += shift; return m }
            diagonals += ds.map { var d = $0; d.col += shift; return d }
            fills += fs.map { var f = $0; f.col += shift; return f }
            lockedCols += locks.map { $0 + shift }
        }
    }
}

extension TableData {
    // 寫在 extension 裡才能保留自動產生的 memberwise init；舊版存檔沒有 merges 等欄位也能讀
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colWidths = try c.decode([CGFloat].self, forKey: .colWidths)
        rowHeights = try c.decode([CGFloat].self, forKey: .rowHeights)
        cells = try c.decodeIfPresent([[String]].self, forKey: .cells) ?? []
        lineColorHex = try c.decodeIfPresent(String.self, forKey: .lineColorHex) ?? "#333333FF"
        lineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? 2
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 16
        merges = try c.decodeIfPresent([CellMerge].self, forKey: .merges) ?? []
        diagonals = try c.decodeIfPresent([CellDiagonal].self, forKey: .diagonals) ?? []
        fills = try c.decodeIfPresent([CellFill].self, forKey: .fills) ?? []
        lockedRows = try c.decodeIfPresent([Int].self, forKey: .lockedRows) ?? []
        lockedCols = try c.decodeIfPresent([Int].self, forKey: .lockedCols) ?? []
        repeatGroup = try c.decodeIfPresent(TableRepeat.self, forKey: .repeatGroup)
    }
}

// MARK: - 手繪格線的手勢（不用找按鈕）

/// 在表格上畫的一筆代表什麼
enum TableGesture: Equatable {
    /// 劃掉格線（在線上來回塗）：合併線兩邊的格子
    case merge([CellRange])
    /// 在表格上下外側畫一條橫線：在那裡加一列（高度＝線到表格邊的距離）
    case addRow(at: Int, height: CGFloat)
    /// 在表格左右外側畫一條直線：加一欄
    case addColumn(at: Int, width: CGFloat)
}

extension TableData {
    /// 離表格多遠以內的線算是要加列／欄
    static let addReach: CGFloat = 200

    /// pts 是表格座標的一筆。認不出這兩種手勢就回傳 nil（照原本：切格子、加斜線）
    func gesture(for pts: [CGPoint]) -> TableGesture? {
        guard pts.count >= 2, rows > 0, cols > 0 else { return nil }
        if let m = scribbledLines(pts) { return .merge(m) }
        return outsideLine(pts)
    }

    /// 橡皮擦沿著格線擦（離線 tolerance 以內、擦過那段線的 coverage 以上）：回傳要合併的格子。
    /// 只是穿過格線（擦格子裡的字時常常會）不算
    func erasedLines(_ pts: [CGPoint], tolerance tol: CGFloat, coverage: CGFloat = 0.6) -> [CellRange] {
        guard pts.count >= 2, rows > 0, cols > 0 else { return [] }
        // 補成每 2pt 一點，才算得出沿著線擦了多長
        var dense: [CGPoint] = []
        for (a, b) in zip(pts, pts.dropFirst()) {
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 2))
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n)
                dense.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        dense.append(pts[pts.count - 1])
        var out: [CellRange] = []
        func add(_ r: CellRange) { if !out.contains(r) { out.append(r) } }
        for c in 1..<max(cols, 1) {
            let x = colX(c)
            for r in 0..<rows where isColLineVisible(c, atRow: r) {
                let y0 = rowY(r), y1 = rowY(r + 1)
                let ys = dense.filter { abs($0.x - x) <= tol && $0.y >= y0 && $0.y <= y1 }.map(\.y)
                if let lo = ys.min(), let hi = ys.max(), hi - lo >= (y1 - y0) * coverage { add(CellRange(anchor(r, c - 1), anchor(r, c))) }
            }
        }
        for r in 1..<max(rows, 1) {
            let y = rowY(r)
            for c in 0..<cols where isRowLineVisible(r, atColumn: c) {
                let x0 = colX(c), x1 = colX(c + 1)
                let xs = dense.filter { abs($0.y - y) <= tol && $0.x >= x0 && $0.x <= x1 }.map(\.x)
                if let lo = xs.min(), let hi = xs.max(), hi - lo >= (x1 - x0) * coverage { add(CellRange(anchor(r - 1, c), anchor(r, c))) }
            }
        }
        return out
    }

    /// 在同一段格線上來回穿過 2 次以上（整筆至少 3 次）＝劃掉那段線
    private func scribbledLines(_ pts: [CGPoint]) -> [CellRange]? {
        var ranges: [CellRange] = []
        var total = 0
        for c in 1..<max(cols, 1) {
            let x = colX(c)
            var hits: [Int: Int] = [:]
            for (a, b) in zip(pts, pts.dropFirst()) where (a.x - x) * (b.x - x) < 0 {
                let y = a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
                if let r = rowIndex(at: y), isColLineVisible(c, atRow: r) { hits[r, default: 0] += 1 }
            }
            for (r, n) in hits where n >= 2 {
                ranges.append(CellRange(anchor(r, c - 1), anchor(r, c)))
                total += n
            }
        }
        for r in 1..<max(rows, 1) {
            let y = rowY(r)
            var hits: [Int: Int] = [:]
            for (a, b) in zip(pts, pts.dropFirst()) where (a.y - y) * (b.y - y) < 0 {
                let x = a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y)
                if let c = colIndex(at: x), isRowLineVisible(r, atColumn: c) { hits[c, default: 0] += 1 }
            }
            for (c, n) in hits where n >= 2 {
                ranges.append(CellRange(anchor(r - 1, c), anchor(r, c)))
                total += n
            }
        }
        return total >= 3 && !ranges.isEmpty ? ranges : nil
    }

    /// 表格外面、和邊平行、長度至少蓋過一半的線
    private func outsideLine(_ pts: [CGPoint]) -> TableGesture? {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let w = size.width, h = size.height
        func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b1: CGFloat) -> CGFloat { max(0, min(a1, b1) - max(a0, 0)) }
        if box.width >= box.height * 2, overlap(box.minX, box.maxX, w) >= w * 0.5 {
            if box.minY >= h - 2, box.midY - h <= Self.addReach {
                return .addRow(at: rows, height: max(Self.minCell, box.midY - h))
            }
            if box.maxY <= 2, -box.midY <= Self.addReach {
                return .addRow(at: 0, height: max(Self.minCell, -box.midY))
            }
        }
        if box.height >= box.width * 2, overlap(box.minY, box.maxY, h) >= h * 0.5 {
            if box.minX >= w - 2, box.midX - w <= Self.addReach {
                return .addColumn(at: cols, width: max(Self.minCell, box.midX - w))
            }
            if box.maxX <= 2, -box.midX <= Self.addReach {
                return .addColumn(at: 0, width: max(Self.minCell, -box.midX))
            }
        }
        return nil
    }
}

// MARK: - 範本

enum TableTemplate: String, CaseIterable, Identifiable {
    case timetable, lab, week, compare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timetable: return "課表"
        case .lab: return "實驗紀錄"
        case .week: return "週計畫"
        case .compare: return "比較表"
        }
    }

    var symbol: String {
        switch self {
        case .timetable: return "calendar"
        case .lab: return "flask"
        case .week: return "checklist"
        case .compare: return "rectangle.split.3x1"
        }
    }

    /// 第一列（和第一欄）是標題，淡灰底
    var table: TableData {
        func make(_ header: [String], firstColumn: [String], widths: [CGFloat], height: CGFloat) -> TableData {
            var t = TableData.make(rows: firstColumn.count + 1, cols: header.count, cellHeight: height)
            t.colWidths = widths
            for (c, s) in header.enumerated() { t.setText(s, row: 0, col: c) }
            for (r, s) in firstColumn.enumerated() { t.setText(s, row: r + 1, col: 0) }
            t.setFill(CellRange((0, 0), (0, header.count - 1)), hex: "#EEEEEEFF")
            return t
        }
        switch self {
        case .timetable:
            return make(["", "一", "二", "三", "四", "五"], firstColumn: (1...8).map { "\($0)" },
                        widths: [44] + Array(repeating: 92, count: 5), height: 44)
        case .lab:
            return make(["次數", "測量 1", "測量 2", "測量 3", "平均"], firstColumn: (1...5).map { "\($0)" },
                        widths: [64, 100, 100, 100, 100], height: 40)
        case .week:
            return make(["星期", "待辦"], firstColumn: ["一", "二", "三", "四", "五", "六", "日"],
                        widths: [64, 380], height: 48)
        case .compare:
            return make(["項目", "A", "B"], firstColumn: ["", "", "", ""], widths: [120, 160, 160], height: 44)
        }
    }
}
