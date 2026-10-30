import XCTest
import SwiftUI
@testable import PaperNote

/// 回報的需求：表格要好用，交互盡量放到畫畫上，少用工具和鍵盤
final class TableGestureTests: XCTestCase {
    /// 3 × 3、每格 100 × 40
    private let t = TableData.make(rows: 3, cols: 3, cellWidth: 100, cellHeight: 40)

    /// 在 x 這條直線附近從 y0 畫到 y1 來回塗
    private func scribble(acrossX x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> [CGPoint] {
        stride(from: y0, through: y1, by: 4).enumerated().map { i, y in CGPoint(x: x + (i % 2 == 0 ? -15 : 15), y: y) }
    }

    func testScribblingOverALineMergesTheTwoCells() {
        let g = t.gesture(for: scribble(acrossX: 100, from: 8, to: 30))
        XCTAssertEqual(g, .merge([CellRange((0, 0), (0, 1))]), "在 A1、B1 中間的線上來回塗＝合併這兩格")
    }

    func testScribblingAlongALineMergesEveryRowItCrosses() {
        guard case let .merge(ranges)? = t.gesture(for: scribble(acrossX: 200, from: 6, to: 74)) else {
            return XCTFail("沿著線塗兩格長也要認得")
        }
        XCTAssertEqual(Set(ranges.map { "\($0.r0)\($0.c0)\($0.r1)\($0.c1)" }), ["0102", "1112"], "第 1、2 列的 B、C 都合併")
    }

    func testScribblingOverAHorizontalLine() {
        let pts = stride(from: CGFloat(110), through: 190, by: 4).enumerated().map { i, x in CGPoint(x: x, y: 40 + (i % 2 == 0 ? -12 : 12)) }
        XCTAssertEqual(t.gesture(for: pts), .merge([CellRange((0, 1), (1, 1))]), "塗掉 B1、B2 中間的橫線")
    }

    func testAStraightLineIsStillASplit() {
        XCTAssertNil(t.gesture(for: [CGPoint(x: 10, y: 20), CGPoint(x: 150, y: 20), CGPoint(x: 290, y: 20)]), "直直畫過去還是切開格子")
    }

    func testLineBelowTheTableAddsARow() {
        XCTAssertEqual(t.gesture(for: [CGPoint(x: 20, y: 150), CGPoint(x: 280, y: 152)]), .addRow(at: 3, height: 31))
    }

    func testLineAboveAndBesideTheTableAddsThere() {
        XCTAssertEqual(t.gesture(for: [CGPoint(x: 30, y: -40), CGPoint(x: 260, y: -40)]), .addRow(at: 0, height: 40))
        XCTAssertEqual(t.gesture(for: [CGPoint(x: 340, y: 10), CGPoint(x: 341, y: 110)]), .addColumn(at: 3, width: 40.5))
        XCTAssertEqual(t.gesture(for: [CGPoint(x: -30, y: 10), CGPoint(x: -32, y: 110)]), .addColumn(at: 0, width: 31))
    }

    func testLinesFarAwayOrTooShortAreIgnored() {
        XCTAssertNil(t.gesture(for: [CGPoint(x: 20, y: 400), CGPoint(x: 280, y: 400)]), "離表格太遠不算")
        XCTAssertNil(t.gesture(for: [CGPoint(x: 20, y: 150), CGPoint(x: 60, y: 150)]), "太短（不到一半寬）不算")
    }

    // MARK: 橡皮擦擦掉格線

    func testErasingAlongALineMergesTheCells() {
        // 沿著 A1、B1 中間的直線從上擦到下
        let pts = stride(from: CGFloat(2), through: 38, by: 3).map { CGPoint(x: 100 + sin($0) * 3, y: $0) }
        let lines = t.erasedLines(pts, tolerance: 8)
        XCTAssertEqual(lines.map(\.range), [CellRange((0, 0), (0, 1))])
        XCTAssertEqual(lines.first?.from, CGPoint(x: 100, y: 0), "預覽畫的是整段線")
        XCTAssertEqual(lines.first?.to, CGPoint(x: 100, y: 40))
    }

    func testErasingAcrossALineDoesNotMerge() {
        // 擦格子裡的字時，橡皮擦橫著穿過格線：不能合併
        let pts = [CGPoint(x: 60, y: 20), CGPoint(x: 140, y: 22), CGPoint(x: 60, y: 24)]
        XCTAssertEqual(t.erasedLines(pts, tolerance: 8), [])
    }

    func testErasingPartOfALineIsNotEnough() {
        let pts = [CGPoint(x: 100, y: 2), CGPoint(x: 100, y: 12)]
        XCTAssertEqual(t.erasedLines(pts, tolerance: 8), [], "只擦了一小段（不到六成）不算")
    }

    func testErasingAHorizontalLineAcrossTwoCells() {
        let pts = [CGPoint(x: 4, y: 41), CGPoint(x: 196, y: 39)]
        XCTAssertEqual(Set(t.erasedLines(pts, tolerance: 8).map { "\($0.range.r0)\($0.range.c0)\($0.range.r1)\($0.range.c1)" }), ["0010", "0111"],
                       "擦掉第 1、2 列中間的橫線（A、B 兩欄）")
    }

    // MARK: 合併後把原本的線畫回去

    func testRedrawingALineInsideAVerticalMergeRestoresIt() {
        var m = t
        m.mergeCells(CellRange((0, 0), (1, 0)))
        XCTAssertEqual(m.nearestRowLine(to: 43, within: 12), 1)
        XCTAssertTrue(m.restoreRowLine(1, columns: [0]))
        XCTAssertNil(m.merge(at: 0, 0), "畫回去之後又是兩格")
        XCTAssertFalse(m.restoreRowLine(1, columns: [0]), "線本來就看得到：不算接回去")
    }

    func testRedrawingALineThroughABlockSplitsItIntoTwoMerges() {
        var m = t
        m.mergeCells(CellRange((0, 0), (1, 1)))
        XCTAssertTrue(m.restoreRowLine(1, columns: [0, 1]))
        XCTAssertEqual(m.span(0, 0), CellMerge(row: 0, col: 0, rowSpan: 1, colSpan: 2), "上半塊還是兩格合併")
        XCTAssertEqual(m.span(1, 0), CellMerge(row: 1, col: 0, rowSpan: 1, colSpan: 2), "下半塊也是")
        XCTAssertTrue(m.restoreColLine(1, rows: [0]))
        XCTAssertNil(m.merge(at: 0, 0), "再畫直線：上面那塊也拆開")
        XCTAssertEqual(m.span(1, 0).colSpan, 2, "下面那塊沒畫到，維持合併")
    }

    /// 回報的需求：要能插入超過 10 × 10 的表格，而且放得進頁面
    func testBigInsertedTablesFitThePage() {
        let a4 = CGSize(width: 595, height: 842)
        let big = TableData.fitted(rows: 20, cols: 15, page: a4)
        XCTAssertEqual(big.cols, 15)
        XCTAssertEqual(big.rows, 20)
        XCTAssertLessThanOrEqual(big.size.width, a4.width)
        XCTAssertLessThanOrEqual(big.size.height, a4.height)
        let small = TableData.fitted(rows: 3, cols: 3, page: a4)
        XCTAssertEqual(small.colWidths[0], 140, "小表格的格子不會變得很大")
        XCTAssertEqual(small.rowHeights[0], 44)
    }

    /// 移動表格時哪些字跟著走
    func testWhichStrokesBelongToTheTable() {
        let table = CGRect(x: 0, y: 0, width: 300, height: 120)
        XCTAssertTrue(InkCarry.isOn(CGRect(x: 20, y: 10, width: 60, height: 20), element: table))
        XCTAssertTrue(InkCarry.isOn(CGRect(x: 20, y: 100, width: 60, height: 26), element: table), "字的尾巴稍微超出表格也算")
        XCTAssertFalse(InkCarry.isOn(CGRect(x: -40, y: -40, width: 380, height: 200), element: table), "圈住整個表格的大圈不算")
        XCTAssertFalse(InkCarry.isOn(CGRect(x: 320, y: 10, width: 40, height: 20), element: table), "表格外面的字不算")
    }
}

final class TableEditorUXTests: XCTestCase {
    private final class FakePan: UIPanGestureRecognizer {
        var fake: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { fake }
            set { fake = newValue }
        }
    }

    private final class FakeTap: UITapGestureRecognizer {
        let point: CGPoint
        init(_ p: CGPoint) {
            point = p
            super.init(target: nil, action: nil)
        }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var ref: ElementRef!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "TableUX", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let t = TableData.make(rows: 3, cols: 3, cellWidth: 100, cellHeight: 40)
        let o = editor.contentOrigin(0)
        ref = try XCTUnwrap(editor.insertElement(.table(t), size: t.size, at: CGPoint(x: o.x + 250, y: o.y + 300)))
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private var table: TableData { editor.selectedTable()!.table }
    private var origin: CGPoint { editor.selectedTable()!.docRect.origin }

    private func titles(_ items: [UIMenuElement]) -> [String] {
        items.flatMap { e -> [String] in
            if let m = e as? UIMenu { return [m.title] + titles(m.children) }
            return [e.title]
        }
    }

    // MARK: 用筆

    func testScribbleMergesInTheEditor() {
        let o = origin
        let pts = stride(from: CGFloat(8), through: 30, by: 4).enumerated().map { i, y in
            CGPoint(x: o.x + 100 + (i % 2 == 0 ? -15 : 15), y: o.y + y)
        }
        editor.applyTableStroke(ref, points: pts)
        XCTAssertEqual(table.span(0, 0).colSpan, 2, "塗掉格線就合併")
    }

    func testDrawingAboveTheTableAddsARowWithoutMovingTheCells() {
        let o = origin
        let before = CGPoint(x: o.x + table.cellRect(row: 0, col: 0).midX, y: o.y + table.cellRect(row: 0, col: 0).midY)
        editor.applyTableStroke(ref, points: [CGPoint(x: o.x + 20, y: o.y - 40), CGPoint(x: o.x + 280, y: o.y - 40)])
        XCTAssertEqual(table.rows, 4)
        let o2 = origin
        let after = CGPoint(x: o2.x + table.cellRect(row: 1, col: 0).midX, y: o2.y + table.cellRect(row: 1, col: 0).midY)
        XCTAssertEqual(after.y, before.y, accuracy: 0.5, "原本的格子留在原地，新的一列長在上面")
    }

    /// 回報的需求：表格工具裡的「擦線」，會被擦掉的線先變半透明，放開才合併
    func testEraseModeFadesTheLineThenMerges() {
        final class FakePan: UIPanGestureRecognizer {
            var fake: UIGestureRecognizer.State = .possible
            override var state: UIGestureRecognizer.State {
                get { fake }
                set { fake = newValue }
            }
        }
        editor.setTool(.tableDraw)
        editor.tableDrawTarget = ref
        editor.tableEraseLines = true
        let o = origin(of: ref)
        let pts = stride(from: CGFloat(2), through: 38, by: 3).map { CGPoint(x: o.x + 200, y: o.y + $0) }
        let g = FakePan(target: nil, action: nil)
        for (i, p) in pts.enumerated() where i < pts.count - 1 {
            g.fake = i == 0 ? .began : .changed
            editor.handleTableDrawPan(g, p)
        }
        XCTAssertEqual(editor.tableErasePreview.map(\.range), [CellRange((0, 1), (0, 2))], "擦到的線先變半透明（還沒合併）")
        XCTAssertEqual(tableAt(ref).span(0, 1).colSpan, 1)
        g.fake = .ended
        editor.handleTableDrawPan(g, pts[pts.count - 1])
        XCTAssertEqual(tableAt(ref).span(0, 1).colSpan, 2, "放開就合併")
        XCTAssertTrue(editor.tableErasePreview.isEmpty)
    }

    /// 回報的問題：合併後要把原本的線畫回去，會說太靠近原有的格線
    func testDrawingTheOldLineInAMergedCellRestoresIt() {
        editor.modifyTable(ref) { $0.mergeCells(CellRange((0, 0), (1, 0))) }
        let o = origin(of: ref)
        editor.applyTableStroke(ref, points: [CGPoint(x: o.x + 8, y: o.y + 42), CGPoint(x: o.x + 50, y: o.y + 41), CGPoint(x: o.x + 92, y: o.y + 39)])
        XCTAssertNil(tableAt(ref).merge(at: 0, 0), "沿著原本的線畫：接回去")
        XCTAssertEqual(tableAt(ref).rows, 3, "不是多切一列")
    }

    /// 回報的需求：編輯表格時 Pencil 筆身點兩下切換「擦線」，不要切到橡皮擦
    func testPencilDoubleTapTogglesEraseLines() throws {
        try XCTSkipIf(UIPencilInteraction.preferredTapAction == .ignore, "系統設定成點兩下不做事")
        editor.setTool(.tableDraw)
        editor.tableDrawTarget = ref
        editor.rebuildSubBar()
        editor.handlePencilDoubleTap()
        XCTAssertEqual(editor.tool, .tableDraw, "不要切到橡皮擦")
        XCTAssertTrue(editor.tableEraseLines, "切到擦線")
        let toggle = editor.subBarStack.arrangedSubviews.compactMap { $0 as? UISegmentedControl }.first
        XCTAssertEqual(toggle?.selectedSegmentIndex, 1, "工具列的切換也跟著變")
        editor.handlePencilDoubleTap()
        XCTAssertFalse(editor.tableEraseLines, "再點兩下切回畫線")
    }

    func testEraserToolDoesNotTouchTables() {
        // 真的橡皮擦只擦筆跡，不會動表格
        editor.setTool(.eraser)
        XCTAssertNil(editor.eraserTracker.onEnded)
    }

    private func tableAt(_ r: ElementRef) -> TableData {
        guard case let (pi, ei)? = editor.locate(r), case let .table(t) = editor.pages[pi].elements[ei].content else { return .make(rows: 1, cols: 1) }
        return t
    }

    private func origin(of r: ElementRef) -> CGPoint {
        guard case let (pi, ei)? = editor.locate(r) else { return .zero }
        return editor.docFrame(of: editor.pages[pi].elements[ei], pageIndex: pi).origin
    }

    // MARK: 標頭

    func testTappingAColumnHeaderSelectsTheWholeColumn() throws {
        let headers = try XCTUnwrap(editor.tableHeaderRects(), "選到表格要有標頭")
        XCTAssertEqual(headers.cols.count, 3)
        XCTAssertEqual(headers.rows.count, 3)
        editor.handleTap(FakeTap(headers.cols[1].center))
        XCTAssertEqual(editor.tableCellSel, CellRange((0, 1), (2, 1)), "點 B 欄標頭＝選整個 B 欄")
        editor.handleTap(FakeTap(headers.rows[2].center))
        XCTAssertEqual(editor.tableCellSel, CellRange((2, 0), (2, 2)), "點第 3 列標頭＝選整列")
    }

    func testDraggingAcrossHeadersSelectsSeveralColumns() throws {
        let headers = try XCTUnwrap(editor.tableHeaderRects())
        guard case .colHeaders(0)? = editor.dragTarget(at: headers.cols[0].center)?.1 else { return XCTFail("按在標頭上要能拖") }
        let g = FakePan(target: nil, action: nil)
        for (i, p) in [headers.cols[0].center, headers.cols[1].center, headers.cols[2].center].enumerated() {
            g.fake = i == 0 ? .began : (i == 2 ? .ended : .changed)
            editor.handleElementPan(g, p)
        }
        XCTAssertEqual(editor.tableCellSel, CellRange((0, 0), (2, 2)), "從 A 拖到 C＝選 A–C 三欄")
    }

    // MARK: 工具列、長按

    private func ribbonButtons(tab: Int) -> [UIButton] {
        editor.tableRibbonTab = tab
        func buttons(_ v: UIView) -> [UIButton] { (v as? UIButton).map { [$0] } ?? v.subviews.flatMap(buttons) }
        return editor.buildTableRibbon().flatMap(buttons)
    }

    /// 回報的需求：樣式、列與欄不要藏在兩三層選單裡，直接攤平，每個按鈕都寫名稱（功能複雜，只有圖示看不懂）
    func testRibbonIsFlatWithLabeledButtons() throws {
        editor.tableRibbonTab = 0
        let tabs = try XCTUnwrap(editor.buildTableRibbon().compactMap { $0 as? UISegmentedControl }.first, "分頁切換")
        XCTAssertEqual((0..<tabs.numberOfSegments).compactMap { tabs.titleForSegment(at: $0) }, ["列與欄", "儲存格", "樣式"])
        for tab in 0..<3 {
            let bs = ribbonButtons(tab: tab)
            XCTAssertFalse(bs.isEmpty)
            XCTAssertTrue(bs.allSatisfy { $0.menu == nil && !$0.showsMenuAsPrimaryAction }, "分頁 \(tab)：沒有要再點開的選單")
            XCTAssertTrue(bs.allSatisfy { !($0.configuration?.title ?? "").isEmpty }, "分頁 \(tab)：每個按鈕都寫名稱")
        }
        let rowCol = ribbonButtons(tab: 0).compactMap { $0.configuration?.title }
        for t in ["在上方插入列", "在右側插入欄", "平均分配欄寬", "刪除選取的列", "手繪格線"] { XCTAssertTrue(rowCol.contains(t), "列與欄要直接看到「\(t)」") }
        XCTAssertFalse(rowCol.contains("編輯文字"), "打字改成點兩下格子")
        let cells = ribbonButtons(tab: 1).compactMap { $0.configuration?.title }
        for t in ["合併", "取消合併", "黃色", "左上到右下"] { XCTAssertTrue(cells.contains(t), "儲存格要直接看到「\(t)」") }
        let style = ribbonButtons(tab: 2).compactMap { $0.configuration?.title }
        for t in ["黑色", "加粗", "變細", "字放大"] { XCTAssertTrue(style.contains(t), "樣式要直接看到「\(t)」") }

        // 按鈕真的有作用
        let cell = CGPoint(x: origin.x + 150, y: origin.y + 60)
        editor.updateCellSelection(from: cell, to: cell)
        let insert = try XCTUnwrap(ribbonButtons(tab: 0).first { $0.configuration?.title == "在右側插入欄" })
        insert.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(table.cols, 4)
    }

    /// 回報的問題：拖動表格的線沒反應。拖曳要移動一小段才開始，那時手指已經離開格線了，要用按下的位置判斷
    func testDraggingAnInnerLineStartsWhereTheFingerTouchedDown() {
        let line = CGPoint(x: origin.x + 100, y: origin.y + 60)
        let g = TouchPan()
        editor.toolPan = g
        var began: Bool?
        g.drag(from: line, to: CGPoint(x: line.x + 30, y: line.y), slop: CGPoint(x: 12, y: 0)) { g in
            if g.state == .began { began = editor.gestureRecognizerShouldBegin(g) }
            editor.handleToolPan(g)
        }
        XCTAssertEqual(began, true, "按在格線上拖：手勢要開始（不能用已經移開的位置判斷）")
        XCTAssertEqual(table.colWidths[0], 130, accuracy: 0.5, "A 欄變寬")
        XCTAssertEqual(table.colWidths[1], 70, accuracy: 0.5)
    }

    /// 回報的需求：鎖頭放在左上角
    func testLockIconIsAtTheTopLeft() throws {
        let lock = try XCTUnwrap(editor.lockIconTargets().first { $0.ref == ref })
        XCTAssertLessThan(lock.point.x, origin.x, "在表格左邊")
        XCTAssertLessThan(lock.point.y, origin.y, "在表格上面")
        let move = try XCTUnwrap(editor.tableMoveHandlePoint())
        XCTAssertGreaterThan(lock.point.distance(to: move), 30 / editor.canvas.zoomScale, "不和移動按鈕疊在一起")
    }

    /// 回報的需求：手繪表格的工具列不要放上一步（和右上角的上一步重複）；右上角的上一步收回最後一條線
    func testDrawingANewTableUsesTheMainUndo() {
        editor.select(nil)
        editor.setTool(.tableDraw)
        editor.tableDrawTarget = nil
        editor.tableDraft = TableDraft(pageIndex: 0, rect: CGRect(x: 60, y: 60, width: 300, height: 200), xs: [160], ys: [110])
        editor.rebuildSubBar()
        func buttons(_ v: UIView) -> [UIButton] { (v as? UIButton).map { [$0] } ?? v.subviews.flatMap(buttons) }
        let titles = editor.subBarStack.arrangedSubviews.flatMap(buttons).map { $0.configuration?.title ?? $0.accessibilityLabel ?? "" }
        XCTAssertFalse(titles.contains { $0.contains("收回") || $0.contains("上一步") }, "工具列沒有自己的上一步")
        editor.undoTapped()
        XCTAssertEqual(editor.tableDraft?.ys, [], "上一步：收回最後畫的那條線")
        XCTAssertEqual(editor.tableDraft?.xs, [160])

        editor.tableDrawTarget = ref
        editor.rebuildSubBar()
        let editTitles = editor.subBarStack.arrangedSubviews.flatMap(buttons).map { $0.configuration?.title ?? $0.accessibilityLabel ?? "" }
        XCTAssertFalse(editTitles.contains { $0.contains("收回") || $0.contains("上一步") }, "在既有表格上畫線也沒有")
    }

    func testLongPressOnACellOffersTheCellActions() {
        let o = origin
        let p = CGPoint(x: o.x + 150, y: o.y + 60)
        let t = titles(editor.elementMenu(ref, at: p).children)
        // 列與欄、樣式直接排在長按選單裡（不再包一層「列與欄」子選單）
        for item in ["合併", "分割…", "底色", "插入", "刪除", "平均分配", "鎖定寬高", "重複…", "格線", "字級"] {
            XCTAssertTrue(t.contains(item), "長按格子要有「\(item)」")
        }
        XCTAssertEqual(editor.tableCellSel, CellRange((1, 1), (1, 1)), "長按的格子被選起來")
    }

    // MARK: 不用打字

    func testInsertTablePanelInsertsTheChosenSize() throws {
        editor.select(nil)
        let o = editor.contentOrigin(0)
        let p = CGPoint(x: o.x + 250, y: o.y + 600)
        editor.presentInsertTablePanel(anchor: .doc(CGRect(origin: p, size: CGSize(width: 1, height: 1))), at: p)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let host = try XCTUnwrap(editor.presentedViewController as? UIHostingController<TableInsertPanel>, "要跳出插入表格的小視窗")
        XCTAssertEqual(host.sizingOptions, .preferredContentSize, "小視窗大小跟著內容，不會被切掉")
        host.rootView.onInsert(4, 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(table.cols, 4)
        XCTAssertEqual(table.rows, 2)
    }

    /// 回報的需求：除了拖格子，也要能自訂數字（超過 10 × 10）
    func testInsertTablePanelTakesNumbersBeyondTheGrid() throws {
        XCTAssertGreaterThanOrEqual(TableInsertPanel.maxCount, 30)
        editor.select(nil)
        let o = editor.contentOrigin(0)
        let p = CGPoint(x: o.x + 40, y: o.y + 40)
        editor.presentInsertTablePanel(anchor: .doc(CGRect(origin: p, size: CGSize(width: 1, height: 1))), at: p)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let host = try XCTUnwrap(editor.presentedViewController as? UIHostingController<TableInsertPanel>)
        host.rootView.onInsert(12, 15)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(table.cols, 12)
        XCTAssertEqual(table.rows, 15)
    }

    // MARK: 重新設計：＋ 只在選整欄整列時出現、拖標頭分界、再點一下打開選單

    /// 回報的問題：行列編號擋到 ＋。＋ 只在選了整欄（整列）時出現在兩側，不和標頭重疊
    func testPlusOnlyBesideASelectedColumnAndNotOnTheHeaders() throws {
        let cell = CGPoint(x: origin.x + 150, y: origin.y + 60)
        editor.updateCellSelection(from: cell, to: cell)
        let none = try XCTUnwrap(editor.selectedTableHandles()).handles
        XCTAssertTrue(none.plusCols.isEmpty && none.plusRows.isEmpty, "只選一格：不顯示 ＋")
        let headers = try XCTUnwrap(editor.tableHeaderRects())
        editor.handleTap(FakeTap(headers.cols[1].center))
        let h = try XCTUnwrap(editor.selectedTableHandles()).handles
        XCTAssertEqual(h.plusCols.map(\.index), [1, 2], "B 欄左右兩側各一個 ＋")
        XCTAssertTrue(h.plusRows.isEmpty)
        let r = 11 / editor.canvas.zoomScale
        for plus in h.plusCols {
            let circle = CGRect(x: plus.point.x - r, y: plus.point.y - r, width: 2 * r, height: 2 * r)
            XCTAssertFalse((headers.cols + headers.rows).contains { $0.intersects(circle) }, "＋ 不能疊在標頭上")
        }
        editor.handleTap(FakeTap(h.plusCols[1].point))
        XCTAssertEqual(table.cols, 4, "按右邊的 ＋ 插入一欄")
        XCTAssertEqual(editor.tableCellSel, CellRange((0, 2), (2, 2)), "選起新的那一欄，可以接著再按")
    }

    func testTappingASelectedHeaderAgainOpensTheRowColumnMenu() throws {
        let headers = try XCTUnwrap(editor.tableHeaderRects())
        editor.handleTap(FakeTap(headers.rows[0].center))
        XCTAssertNil(editor.pendingMenu, "第一下只選整列")
        editor.handleTap(FakeTap(headers.rows[0].center))
        let t = titles(try XCTUnwrap(editor.pendingMenu, "再點一下打開列與欄的選單").children)
        XCTAssertTrue(t.contains("插入"))
        XCTAssertEqual(editor.tableCellSel, CellRange((0, 0), (0, 2)))
    }

    func testTappingTheSelectedCellAgainOpensTheCellMenu() throws {
        let p = CGPoint(x: origin.x + 150, y: origin.y + 60)
        editor.handleTap(FakeTap(p))
        XCTAssertEqual(editor.tableCellSel, CellRange((1, 1), (1, 1)))
        XCTAssertNil(editor.pendingMenu, "第一下只選格子")
        editor.handleTap(FakeTap(p))
        let t = titles(try XCTUnwrap(editor.pendingMenu, "再點一下選起來的格子打開選單").children)
        XCTAssertTrue(t.contains("合併"))
        editor.handleTap(FakeTap(CGPoint(x: origin.x + 50, y: origin.y + 100)))
        XCTAssertEqual(editor.tableCellSel, CellRange((2, 0), (2, 0)), "點別格：改選那一格")
    }

    func testDraggingBetweenTwoHeadersResizesTheColumn() throws {
        let headers = try XCTUnwrap(editor.tableHeaderRects())
        let edge = CGPoint(x: headers.cols[0].maxX, y: headers.cols[0].midY)
        guard case .colLine(1)? = editor.dragTarget(at: edge)?.1 else { return XCTFail("按在 A、B 標頭的分界：拖曳調整欄寬") }
        let g = FakePan(target: nil, action: nil)
        for (i, p) in [edge, CGPoint(x: edge.x + 15, y: edge.y), CGPoint(x: edge.x + 30, y: edge.y)].enumerated() {
            g.fake = i == 0 ? .began : (i == 2 ? .ended : .changed)
            editor.handleElementPan(g, p)
        }
        XCTAssertEqual(table.colWidths[0], 130, accuracy: 0.5)
        XCTAssertEqual(table.colWidths[1], 70, accuracy: 0.5)
        guard case .colHeaders(1)? = editor.dragTarget(at: headers.cols[1].center)?.1 else { return XCTFail("標頭中間還是拖曳選欄") }
    }

    // MARK: 移動表格、套索

    private func word(at p: CGPoint) -> InkStroke {
        let page = editor.contentOrigin(0)
        return InkStroke(colorHex: "#1A1A1AFF", points: (0...5).map { InkPoint(CGPoint(x: p.x - page.x + CGFloat($0) * 10, y: p.y - page.y), width: 2) })
    }

    /// 回報的問題：移動表格時，用自製筆刷寫在格子裡的字留在原地
    func testMovingTheTableCarriesTheHandwriting() throws {
        let o = origin
        let inCell = word(at: CGPoint(x: o.x + 120, y: o.y + 60))
        let outside = word(at: CGPoint(x: o.x - 200, y: o.y - 100))
        editor.updatePage(0) { $0.ink = [inCell, outside] }
        // 同一輪 run loop 記的動作會併成一步：先讓插入表格、寫字結束，拖曳才是自己的一步（和實際操作一樣）
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let grab = try XCTUnwrap(editor.tableMoveHandlePoint())
        guard case .move? = editor.dragTarget(at: grab)?.1 else { return XCTFail("左上角的按鈕可以拖") }
        let g = FakePan(target: nil, action: nil)
        for (i, p) in [grab, CGPoint(x: grab.x, y: grab.y + 40), CGPoint(x: grab.x, y: grab.y + 80)].enumerated() {
            g.fake = i == 0 ? .began : (i == 2 ? .ended : .changed)
            editor.handleElementPan(g, p)
        }
        XCTAssertEqual(origin.y - o.y, 80, accuracy: 0.5, "表格移動了")
        let ink = editor.pages[0].ink
        XCTAssertEqual(ink.first { $0.id == inCell.id }?.points[0].point.y ?? 0, inCell.points[0].point.y + 80, accuracy: 0.01, "格子裡的字跟著表格走")
        XCTAssertEqual(ink.first { $0.id == outside.id }?.points[0].point, outside.points[0].point, "表格外面的字不動")
        editor.undoTapped()
        XCTAssertEqual(origin.y, o.y, accuracy: 0.5, "復原一次：表格回去")
        XCTAssertEqual(editor.pages[0].ink.first { $0.id == inCell.id }?.points[0].point, inCell.points[0].point, "同一次復原：字也回去")
    }

    /// 回報的需求：套索要把整個表格圈起來才選到表格；只圈表格上的字，表格不會被拿走
    func testLassoTakesTheTableOnlyWhenItIsFullyCircled() {
        let o = origin
        let w = word(at: CGPoint(x: o.x + 120, y: o.y + 60))
        editor.updatePage(0) { $0.ink = [w] }
        editor.setTool(.lasso)
        func lasso(_ r: CGRect) {
            let g = FakePan(target: nil, action: nil)
            let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY + 2), CGPoint(x: r.minX + 1, y: r.minY + 1)]
            for (i, p) in pts.enumerated() {
                g.fake = i == 0 ? .began : (i == pts.count - 1 ? .ended : .changed)
                editor.handleLassoPan(g, p)
            }
        }
        lasso(CGRect(x: o.x + 110, y: o.y + 45, width: 80, height: 30))
        XCTAssertEqual(editor.lassoSel?.ink.count, 1, "圈到表格上的字")
        XCTAssertEqual(editor.lassoSel?.elements.count, 0, "只圈到表格的一部分：不選表格")
        editor.clearLassoSelection()
        lasso(CGRect(x: o.x - 20, y: o.y - 20, width: 340, height: 160))
        XCTAssertEqual(editor.lassoSel?.elements, [ref], "整個表格圈起來才選到")
    }
}
