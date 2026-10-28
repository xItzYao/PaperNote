import XCTest
@testable import PaperNote

/// 回報的需求：做大表格
/// - 平均分配欄寬只分配選取的欄
/// - 選了很多格，分割要每一格都分割
/// - 鎖定列高／欄寬，縮放表格時不動
/// - 做好一組後往上／下／左／右重複，接成一份大表格；組數之後可以改（15 改 14 就少一組）
final class BigTableTests: XCTestCase {
    private func filled(rows: Int, cols: Int) -> TableData {
        var t = TableData.make(rows: rows, cols: cols, cellWidth: 100, cellHeight: 40)
        for r in 0..<rows { for c in 0..<cols { t.setText("\(r),\(c)", row: r, col: c) } }
        return t
    }

    // MARK: 平均分配

    func testDistributeOnlyTheSelectedColumns() {
        var t = TableData.make(rows: 2, cols: 4)
        t.colWidths = [50, 100, 200, 80]
        t.distributeColumns(1...2)
        XCTAssertEqual(t.colWidths, [50, 150, 150, 80], "只平均分配 B、C 欄，A、D 不動")
        t.distributeColumns()
        XCTAssertEqual(t.colWidths.reduce(0, +), 430, accuracy: 0.01)
        XCTAssertEqual(Set(t.colWidths.map { Int($0.rounded()) }).count, 1, "沒指定就全部平均")
    }

    func testDistributeSkipsLockedColumns() {
        var t = TableData.make(rows: 1, cols: 3)
        t.colWidths = [60, 100, 200]
        t.setColsLocked(0...0, true)
        t.distributeColumns()
        XCTAssertEqual(t.colWidths, [60, 150, 150], "鎖定的欄不平均分配")
    }

    // MARK: 分割很多格

    func testSplittingASelectionSplitsEveryCell() {
        var t = TableData.make(rows: 3, cols: 3, cellWidth: 100, cellHeight: 40)
        t.splitCells(CellRange((0, 0), (1, 1)), cols: 2, rows: 1)
        XCTAssertEqual(t.cols, 5, "選了兩欄，每欄切成兩欄")
        for r in 0...1 {
            for c in 0..<4 {
                XCTAssertNil(t.merge(at: r, c), "選到的第 \(r + 1) 列每一格都切開了（第 \(c + 1) 欄）")
            }
        }
        // 沒選到的第 3 列維持原本兩格大（合併起來）
        XCTAssertEqual(t.span(2, 0).colSpan, 2)
        XCTAssertEqual(t.span(2, 2).colSpan, 2)
        XCTAssertEqual(t.colWidths[0], 50, accuracy: 0.01)
    }

    func testSplittingASelectionIntoRows() {
        var t = TableData.make(rows: 2, cols: 3, cellWidth: 100, cellHeight: 40)
        t.splitCells(CellRange((0, 0), (0, 1)), cols: 1, rows: 2)
        XCTAssertEqual(t.rows, 3)
        XCTAssertNil(t.merge(at: 0, 0))
        XCTAssertNil(t.merge(at: 1, 1))
        XCTAssertEqual(t.span(0, 2).rowSpan, 2, "沒選到的 C 欄維持一格")
    }

    // MARK: 鎖定

    func testScalingKeepsLockedSizes() {
        var t = TableData.make(rows: 3, cols: 3, cellWidth: 100, cellHeight: 40)
        t.setColsLocked(0...0, true)
        t.setRowsLocked(2...2, true)
        t.scale(to: CGSize(width: 500, height: 200))
        XCTAssertEqual(t.colWidths[0], 100, "鎖定的欄寬不變")
        XCTAssertEqual(t.rowHeights[2], 40, "鎖定的列高不變")
        XCTAssertEqual(t.size.width, 500, accuracy: 0.01)
        XCTAssertEqual(t.size.height, 200, accuracy: 0.01)
        XCTAssertEqual(t.colWidths[1], 200, accuracy: 0.01)
    }

    func testLocksFollowInsertedAndRemovedRows() {
        var t = TableData.make(rows: 4, cols: 2)
        t.setRowsLocked(2...2, true)
        t.insertRow(at: 0)
        XCTAssertEqual(t.lockedRows, [3], "上面插入一列，鎖定的列跟著往下")
        t.removeRow(1)
        XCTAssertEqual(t.lockedRows, [2])
        t.removeRow(2)
        XCTAssertEqual(t.lockedRows, [], "刪掉鎖定的那列，鎖定也不見")
    }

    // MARK: 重複

    func testRepeatRowsDownAndChangeTheCount() {
        var t = filled(rows: 3, cols: 2)
        t.mergeCells(CellRange((1, 0), (1, 1)))
        // 第 2–3 列是一組（第 2 列合併），往下重複 15 組
        t.setRepeat(axis: .rows, start: 1, length: 2, before: false, count: 15)
        XCTAssertEqual(t.rows, 3 + 2 * 15)
        XCTAssertEqual(t.text(row: 3, col: 0), t.text(row: 1, col: 0), "複製的那組文字一樣")
        XCTAssertEqual(t.text(row: 4, col: 1), "2,1")
        XCTAssertEqual(t.span(3, 0).colSpan, 2, "合併的格子也一起複製")
        XCTAssertEqual(t.span(31, 0).colSpan, 2)
        XCTAssertEqual(t.repeatGroup?.count, 15)
        // 15 改 14：少一組
        t.setRepeat(axis: .rows, start: 1, length: 2, before: false, count: 14)
        XCTAssertEqual(t.rows, 3 + 2 * 14)
        XCTAssertEqual(t.repeatGroup?.count, 14)
        XCTAssertEqual(t.text(row: 0, col: 0), "0,0", "原本的資料不動")
        // 改回 0：全部拿掉
        t.setRepeat(axis: .rows, start: 1, length: 2, before: false, count: 0)
        XCTAssertEqual(t.rows, 3)
        XCTAssertNil(t.repeatGroup)
    }

    func testRepeatUpShiftsTheOriginalAndCanShrink() {
        var t = filled(rows: 2, cols: 2)
        t.setRepeat(axis: .rows, start: 1, length: 1, before: true, count: 3)
        XCTAssertEqual(t.rows, 5)
        XCTAssertEqual(t.repeatGroup?.start, 4, "原本那組被往下推")
        XCTAssertEqual(t.text(row: 1, col: 0), "1,0")
        XCTAssertEqual(t.text(row: 0, col: 0), "0,0", "第一列在整組上面，不動")
        t.setRepeat(axis: .rows, start: 4, length: 1, before: true, count: 1)
        XCTAssertEqual(t.rows, 3)
        XCTAssertEqual(t.repeatGroup?.start, 2)
    }

    func testRepeatColumnsRightAndLeft() {
        var t = filled(rows: 2, cols: 3)
        t.colWidths = [80, 120, 60]
        t.setRepeat(axis: .cols, start: 0, length: 2, before: false, count: 2)
        XCTAssertEqual(t.cols, 3 + 4)
        XCTAssertEqual(Array(t.colWidths.prefix(6)), [80, 120, 80, 120, 80, 120], "欄寬一起複製")
        XCTAssertEqual(t.text(row: 1, col: 5), "1,1")
        XCTAssertEqual(t.text(row: 0, col: 6), "0,2", "原本後面的欄被往右推")

        var u = filled(rows: 1, cols: 2)
        u.setRepeat(axis: .cols, start: 1, length: 1, before: true, count: 2)
        XCTAssertEqual(u.cols, 4)
        XCTAssertEqual(u.text(row: 0, col: 1), "0,1", "往左複製")
        XCTAssertEqual(u.repeatGroup?.start, 3)
    }

    func testRepeatGroupFollowsRowsInsertedAboveIt() {
        var t = filled(rows: 3, cols: 1)
        t.setRepeat(axis: .rows, start: 1, length: 1, before: false, count: 2)
        t.insertRow(at: 0)
        XCTAssertEqual(t.repeatGroup?.start, 2, "上面插一列，組跟著往下")
        t.setRepeat(axis: .rows, start: 2, length: 1, before: false, count: 1)
        XCTAssertEqual(t.rows, 5, "還是同一組，改組數就好")
    }

    func testLocksAndRepeatAreSaved() throws {
        var t = filled(rows: 3, cols: 2)
        t.setColsLocked(1...1, true)
        t.setRepeat(axis: .rows, start: 0, length: 1, before: false, count: 2)
        let back = try JSONDecoder().decode(TableData.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
        // 舊檔沒有這些欄位也能讀
        let old = try JSONDecoder().decode(TableData.self, from: Data(#"{"colWidths":[100],"rowHeights":[40],"cells":[[""]]}"#.utf8))
        XCTAssertEqual(old.lockedRows, [])
        XCTAssertNil(old.repeatGroup)
    }
}

/// 編輯器：拖曳選取範圍右下角的藍點重複；擴展頁面時最後一頁可以往下拉
final class BigTableEditorTests: XCTestCase {
    private final class FakePan: UIPanGestureRecognizer {
        var fake: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { fake }
            set { fake = newValue }
        }
    }

    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "BigTable", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private var table: TableData? { editor.selectedTable()?.table }

    func testDraggingTheFillHandleRepeatsTheSelectedRows() throws {
        let t = TableData.make(rows: 3, cols: 3, cellWidth: 100, cellHeight: 40)
        let o = editor.contentOrigin(0)
        _ = editor.insertElement(.table(t), size: t.size, at: CGPoint(x: o.x + 250, y: o.y + 150))
        // 選第 1–2 列
        editor.tableCellSel = CellRange((0, 0), (1, 2))
        editor.updateTableCellChrome()
        let handle = try XCTUnwrap(editor.tableFillHandlePoint(), "選取範圍右下角要有藍點")
        guard case .fill? = editor.dragTarget(at: handle)?.1 else { return XCTFail("按在藍點上要能拖") }
        // 往下拖兩組多一點（一組 80pt）
        let g = FakePan(target: nil, action: nil)
        for (i, dy) in [CGFloat(0), 90, 170].enumerated() {
            g.fake = i == 0 ? .began : (i == 2 ? .ended : .changed)
            editor.handleElementPan(g, CGPoint(x: handle.x, y: handle.y + dy))
        }
        XCTAssertEqual(table?.rows, 3 + 2 * 2, "往下重複兩組")
        XCTAssertEqual(table?.repeatGroup?.count, 2)
        // 藍點移到整組的尾端；往上拖一組＝少一組
        let end = try XCTUnwrap(editor.tableFillHandlePoint())
        XCTAssertGreaterThan(end.y, handle.y + 150)
        for (i, dy) in [CGFloat(0), -40, -80].enumerated() {
            g.fake = i == 0 ? .began : (i == 2 ? .ended : .changed)
            editor.handleElementPan(g, CGPoint(x: end.x, y: end.y + dy))
        }
        XCTAssertEqual(table?.repeatGroup?.count, 1, "往上拖一組，少一組")
        XCTAssertEqual(table?.rows, 3 + 2)
    }

    func testRepeatPanelAppliesAndEditsTheCount() throws {
        let t = TableData.make(rows: 2, cols: 2, cellWidth: 100, cellHeight: 40)
        let o = editor.contentOrigin(0)
        _ = editor.insertElement(.table(t), size: t.size, at: CGPoint(x: o.x + 250, y: o.y + 150))
        let sel = CellRange((1, 0), (1, 1))
        editor.tableCellSel = sel
        editor.applyTableRepeat(direction: 1, count: 15, editing: nil, selection: sel)
        XCTAssertEqual(table?.rows, 2 + 15)
        editor.applyTableRepeat(direction: 1, count: 14, editing: table?.repeatGroup, selection: sel)
        XCTAssertEqual(table?.rows, 2 + 14, "15 組改 14 組，少一組")
    }

    func testPageResizeLeavesRoomBelowAndDoesNotAddPages() {
        editor.setTool(.pageResize)
        XCTAssertGreaterThan(editor.canvas.contentInset.bottom, 100, "最後一頁底下要能再往下拉，才擴展得到")
        let c = editor.canvas
        let maxY = c.contentSize.height + c.adjustedContentInset.bottom - c.bounds.height
        c.contentOffset.y = maxY + NotebookViewController.addPagePullThreshold + 30
        editor.scrollViewDidScroll(c)
        XCTAssertTrue(editor.addPagePull.isHidden, "擴展頁面時不出現新增頁面的＋")
        editor.setTool(.pen)
        XCTAssertEqual(editor.canvas.contentInset.bottom, 0)
    }
}
