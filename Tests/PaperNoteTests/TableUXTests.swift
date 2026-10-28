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

    func testTemplatesHaveHeaders() {
        let tt = TableTemplate.timetable.table
        XCTAssertEqual(tt.cols, 6)
        XCTAssertEqual(tt.rows, 9)
        XCTAssertEqual(tt.text(row: 0, col: 1), "一")
        XCTAssertEqual(tt.text(row: 8, col: 0), "8")
        XCTAssertEqual(TableTemplate.week.table.text(row: 7, col: 0), "日")
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

    func testToolbarIsGroupedAndHasNoTypingButton() {
        let labels = editor.buildTableRibbon().compactMap(\.accessibilityLabel)
        XCTAssertFalse(labels.contains("編輯文字"), "打字改成點兩下格子")
        for group in ["列與欄", "儲存格", "樣式", "手繪格線"] { XCTAssertTrue(labels.contains(group), "工具列要有「\(group)」") }
        XCTAssertLessThanOrEqual(editor.buildTableRibbon().count, 7, "按鈕收成幾組，不要一長排")
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
        XCTAssertEqual(host.sizingOptions, .preferredContentSize, "小視窗大小跟著內容，標題、範本不會被切掉")
        host.rootView.onInsert(.size(cols: 4, rows: 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(table.cols, 4)
        XCTAssertEqual(table.rows, 2)
    }

    func testInsertTemplate() throws {
        editor.select(nil)
        let o = editor.contentOrigin(0)
        let p = CGPoint(x: o.x + 250, y: o.y + 600)
        editor.presentInsertTablePanel(anchor: .doc(CGRect(origin: p, size: CGSize(width: 1, height: 1))), at: p)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let host = try XCTUnwrap(editor.presentedViewController as? UIHostingController<TableInsertPanel>)
        host.rootView.onInsert(.template(.lab))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(table.text(row: 0, col: 0), "次數")
    }
}
