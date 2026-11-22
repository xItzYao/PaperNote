import XCTest
import UIKit
@testable import PaperNote

/// 回報的問題（11/22）：
/// 1. 電路圖、表格用手指點兩下就要能編輯，不管在哪個工具、有沒有開「用手指書寫」
/// 2. 表格工具列「底色」旁邊的顏色要跟著選到的格子
/// 3. 套索選表格和上面的字一起移動，放開時字先跳回原本的位置再跳回來
final class EditorRequestsNov22Tests: XCTestCase {
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
    private var savedFingerDrawing = false
    private var savedCustomInk = false

    override func setUpWithError() throws {
        savedFingerDrawing = EditorSettings.shared.fingerDrawing
        savedCustomInk = EditorSettings.shared.customInk
        EditorSettings.shared.fingerDrawing = false
        EditorSettings.shared.customInk = true
        let meta = LibraryStore.shared.createNotebook(title: "Nov22", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        spin(0.3)
    }

    override func tearDown() {
        editor.endTextEditing()
        EditorSettings.shared.fingerDrawing = savedFingerDrawing
        EditorSettings.shared.customInk = savedCustomInk
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private func doc(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    private func moved(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }

    /// 3 欄 2 列、每格 100×50，中心在 (250, 200)
    private func addTable() throws -> ElementRef {
        let t = TableData.make(rows: 2, cols: 3, cellWidth: 100, cellHeight: 50)
        return try XCTUnwrap(editor.insertElement(.table(t), size: t.size, at: doc(250, 200)))
    }

    private func addCircuit() throws -> ElementRef {
        var d = CircuitData()
        d.components = [CircuitComponent(part: .resistor, position: CGPoint(x: 120, y: 100))]
        return try XCTUnwrap(editor.insertElement(.circuit(d), size: CGSize(width: 240, height: 200), at: doc(250, 600)))
    }

    private func center(_ ref: ElementRef) -> CGPoint {
        guard case let (pi, ei)? = editor.locate(ref) else { return .zero }
        let r = editor.docFrame(of: editor.pages[pi].elements[ei], pageIndex: pi)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// 這個觸碰「點兩下」的手勢收不收（手勢關著也算不收）
    private func doubleTapReceives(_ type: UITouch.TouchType, at p: CGPoint) -> Bool {
        guard let g = editor.doubleTapGesture, g.isEnabled else { return false }
        return editor.gestureRecognizer(g, shouldReceive: FakeTouch(type: type, location: p))
    }

    // MARK: 1. 手指點兩下編輯

    func testAFingerDoubleTapReachesTablesAndCircuitsInEveryTool() throws {
        let table = try addTable(), circuit = try addCircuit()
        for finger in [false, true] {
            EditorSettings.shared.fingerDrawing = finger
            for tool: EditorTool in [.pen, .highlighter, .eraser, .lasso, .capture, .select] {
                editor.setTool(tool)
                editor.select(nil)
                XCTAssertTrue(doubleTapReceives(.direct, at: center(table)), "表格：\(tool) 手指書寫=\(finger)")
                XCTAssertTrue(doubleTapReceives(.direct, at: center(circuit)), "電路圖：\(tool) 手指書寫=\(finger)")
            }
        }
    }

    func testAFingerDoubleTapInTheCircuitToolReachesTheTable() throws {
        let table = try addTable()
        editor.setTool(.circuit)
        XCTAssertTrue(doubleTapReceives(.direct, at: center(table)))
    }

    func testOnlyAFingerOnATableOrCircuitCountsWhileWriting() throws {
        let table = try addTable()
        editor.setTool(.pen)
        XCTAssertFalse(doubleTapReceives(.pencil, at: center(table)), "Pencil 在表格上點兩點是寫字")
        XCTAssertFalse(doubleTapReceives(.direct, at: doc(400, 780)), "空白處的手指照樣捲動")
        editor.lastPencilTime = CACurrentMediaTime()
        XCTAssertFalse(doubleTapReceives(.direct, at: center(table)), "筆尖剛離開：是壓著螢幕的手，不是要編輯")
        editor.lastPencilTime = 0
        editor.setPreviewMode(true)
        XCTAssertFalse(doubleTapReceives(.direct, at: center(table)), "預覽模式不能編輯")
        editor.setPreviewMode(false)
    }

    func testDoubleTappingATableWhileWritingEditsThatCell() throws {
        let ref = try addTable()
        editor.setTool(.pen)
        editor.handleDoubleTap(FakeTap(moved(center(ref), 100, 25)))
        spin(0.2)
        XCTAssertEqual(editor.tool, .select, "表格的工具列要出來")
        XCTAssertEqual(editor.selected, ref)
        XCTAssertEqual(editor.tableCellSel, CellRange((1, 2), (1, 2)))
        XCTAssertNotNil(editor.editingTextView, "那一格可以打字")
    }

    func testDoubleTappingACircuitWhileWritingEditsIt() throws {
        let ref = try addCircuit()
        editor.setTool(.pen)
        editor.handleDoubleTap(FakeTap(center(ref)))
        spin(0.2)
        XCTAssertEqual(editor.tool, .circuit)
        XCTAssertEqual(editor.circuitTarget, ref)
    }

    /// 開了「用手指書寫」：點兩下也會先點出兩個墨點。進入編輯時要收回去，也不能留在上一步裡
    func testTheDotsMadeByTheDoubleTapAreTakenBack() throws {
        let ref = try addTable()
        EditorSettings.shared.fingerDrawing = true
        editor.setTool(.pen)
        spin(0.05)
        let p = center(ref), o = editor.contentOrigin(0)
        let local = CGPoint(x: p.x - o.x, y: p.y - o.y)
        let steps = editor.history.undoCount
        _ = doubleTapReceives(.direct, at: p)
        for _ in 0..<2 {
            editor.updatePage(0) { $0.ink.append(InkStroke(colorHex: "#000000FF", points: [InkPoint(local, width: 2)])) }
            spin(0.02)
        }
        let twice = try XCTUnwrap(editor.doubleTapGesture)
        XCTAssertTrue(editor.gestureRecognizer(twice, shouldRecognizeSimultaneouslyWith: editor.inkRecognizer),
                      "寫字的手勢不能把點兩下擋掉")
        editor.handleDoubleTap(FakeTap(p))
        spin(0.3)
        XCTAssertEqual(editor.pages[0].ink.count, 0, "兩個墨點要收回去")
        XCTAssertEqual(editor.history.undoCount, steps)
        XCTAssertEqual(editor.selected, ref)
    }

    func testOnlyTwoShortStillTapsCloseTogetherCount() {
        var t = FingerTaps()
        XCTAssertTrue(t.began(at: CGPoint(x: 100, y: 100), time: 1))
        XCTAssertTrue(t.moved(to: CGPoint(x: 104, y: 103)), "手指抖一點點還是點")
        XCTAssertFalse(t.moved(to: CGPoint(x: 120, y: 100)), "移開了是在寫字、捲動")
        XCTAssertTrue(t.ended(at: 1.1))
        XCTAssertFalse(t.ended(at: 1.6), "按太久是手靠在螢幕上")
        XCTAssertTrue(t.began(at: CGPoint(x: 112, y: 108), time: 1.3), "第二下在附近")
        XCTAssertFalse(t.began(at: CGPoint(x: 170, y: 100), time: 1.3), "離太遠是兩個不同的點")
    }

    // MARK: 2. 底色的預覽

    private func button(_ title: String, in v: UIView) -> UIButton? {
        if let b = v as? UIButton, b.accessibilityLabel == title { return b }
        for child in v.subviews {
            if let b = button(title, in: child) { return b }
        }
        return nil
    }

    private func assertSwatch(_ title: String, _ hex: String?, _ message: String, line: UInt = #line) {
        let shown = button(title, in: editor.subBarStack)?.configuration?.image?.pngData()
        XCTAssertEqual(shown, NotebookViewController.colorBox(hex).pngData(), message, line: line)
    }

    func testTheColorBoxesFollowTheSelectedCell() throws {
        let ref = try addTable()
        let blue = "#BBDEFBFF", red = "#E53935FF"
        editor.modifyTable(ref) {
            $0.setFill(CellRange((0, 1), (0, 1)), hex: blue)
            $0.setTextColor(CellRange((0, 1), (0, 1)), hex: red)
        }
        let colored = moved(center(ref), 0, -25), plain = moved(center(ref), -100, -25)
        editor.updateCellSelection(from: colored, to: colored)
        assertSwatch(L("底色"), blue, "選到有底色的格子")
        assertSwatch(L("字色"), red, "字色也一樣")
        editor.updateCellSelection(from: plain, to: plain)
        assertSwatch(L("底色"), nil, "換到沒有底色的格子")
        assertSwatch(L("字色"), TableData.defaultTextColor, "字色也換回來")
    }

    func testTheColorBoxFollowsUndo() throws {
        let ref = try addTable()
        let p = moved(center(ref), 0, -25)
        editor.updateCellSelection(from: p, to: p)
        spin(0.05)
        editor.modifyTable(ref) { $0.setFill(CellRange((0, 1), (0, 1)), hex: "#FFF59DFF") }
        assertSwatch(L("底色"), "#FFF59DFF", "改了底色")
        spin(0.05)
        editor.undoTapped()
        assertSwatch(L("底色"), nil, "上一步之後也要跟著")
    }

    // MARK: 3. 放開時筆跡不跳

    /// 表格上面寫 count 筆，都在內容座標 x 150…350、y 190…210
    private func tableWithWriting(_ count: Int) throws -> (ElementRef, PageInkView) {
        let ref = try addTable()
        let strokes = (0..<count).map { i -> InkStroke in
            let y = 190 + CGFloat(i * 2 % 21)
            return InkStroke(colorHex: "#000000FF",
                             points: [InkPoint(CGPoint(x: 150, y: y), width: 5), InkPoint(CGPoint(x: 350, y: y), width: 5)])
        }
        editor.updatePage(0, undoable: false) { $0.ink = strokes }
        let v = try XCTUnwrap(editor.pageViews[editor.pages[0].id]).inkView
        waitUntilBuilt(v)
        XCTAssertGreaterThan(alpha(v.layer.contents, v, y: 200), 100, "測試的前提：字畫出來了")
        return (ref, v)
    }

    private func waitUntilBuilt(_ v: PageInkView) {
        let deadline = Date().addingTimeInterval(3)
        repeat { spin(0.01) } while v.isBuilding && Date() < deadline
    }

    /// 內容座標 (250, y) 的墨水
    private func alpha(_ contents: Any?, _ v: PageInkView, y: CGFloat) -> UInt8 {
        guard let contents else { return 0 }
        let cg = contents as! CGImage
        let o = editor.contentOrigin(0), page = editor.pageFrames[0].origin
        let x = Int((250 + o.x - page.x) * v.renderScale), row = Int((y + o.y - page.y) * v.renderScale)
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: row - cg.height + 1, width: cg.width, height: cg.height))
        return px[3]
    }

    /// 往下拖 300：放開之後換上的每一張筆跡圖都不能有舊位置的字；新位置的字在同一個畫面更新裡就要有
    private func checkRelease(_ v: PageInkView, from start: CGPoint, handle: (TouchPan) -> Void) {
        let g = TouchPan()
        g.point = start
        g.fake = .began
        handle(g)
        XCTAssertEqual(alpha(v.layer.contents, v, y: 200), 0, "一開始拖，原本位置的字就要藏起來（不能和預覽重疊成兩份）")
        waitUntilBuilt(v)
        g.point = moved(start, 0, 300)
        g.moved = CGPoint(x: 0, y: 300)
        g.fake = .changed
        handle(g)
        var atOldPlace: [Bool] = []
        let watch = v.layer.observe(\.contents) { [unowned self] layer, _ in
            atOldPlace.append(self.alpha(layer.contents, v, y: 200) > 0)
        }
        g.fake = .ended
        handle(g)
        XCTAssertGreaterThan(alpha(v.layer.contents, v, y: 500), 100, "放開的同一個畫面更新，字就在新的位置")
        waitUntilBuilt(v)
        watch.invalidate()
        print("JUMPDIAG contents updates at old place: \(atOldPlace)")
        XCTAssertFalse(atOldPlace.isEmpty, "測試的前提：有看到換圖")
        XCTAssertFalse(atOldPlace.contains(true), "放開後畫過一張字在舊位置的圖：\(atOldPlace)")
        XCTAssertGreaterThan(alpha(v.layer.contents, v, y: 500), 100)
        XCTAssertEqual(alpha(v.layer.contents, v, y: 200), 0)
    }

    private func selectTableAndWriting(_ ref: ElementRef) {
        editor.setTool(.lasso)
        let page = editor.pages[0], a = doc(100, 150)
        editor.lassoSel = LassoSelection(strokeIndices: [], elements: [ref], highlights: [],
                                         bounds: CGRect(x: a.x, y: a.y, width: 300, height: 100),
                                         ink: page.ink.map { InkRef(pageID: page.id, id: $0.id) })
    }

    private func checkLassoRelease(strokes count: Int) throws {
        let (ref, v) = try tableWithWriting(count)
        selectTableAndWriting(ref)
        let start = doc(250, 200)
        checkRelease(v, from: start) { editor.handleLassoPan($0, $0.point) }
        XCTAssertEqual(center(ref).y, start.y + 300, accuracy: 1, "表格也一起到新的位置")
    }

    func testLassoMovingATableWithAFewStrokesDoesNotJumpBack() throws { try checkLassoRelease(strokes: 10) }

    func testLassoMovingATableWithManyStrokesDoesNotJumpBack() throws { try checkLassoRelease(strokes: 150) }

    /// 拖表格本身（字跟著走）是同一種做法
    func testDraggingATableWithManyStrokesDoesNotJumpBack() throws {
        let (ref, v) = try tableWithWriting(150)
        editor.setTool(.select)
        editor.select(ref)
        let start = try XCTUnwrap(editor.tableMoveHandlePoint())
        checkRelease(v, from: start) { editor.handleElementPan($0, $0.point) }
    }

    func testCancellingALassoMoveShowsTheWritingAgainRightAway() throws {
        let (ref, v) = try tableWithWriting(150)
        selectTableAndWriting(ref)
        let g = TouchPan()
        g.point = doc(250, 200)
        g.fake = .began
        editor.handleLassoPan(g, g.point)
        waitUntilBuilt(v)
        g.fake = .cancelled
        editor.handleLassoPan(g, g.point)
        XCTAssertGreaterThan(alpha(v.layer.contents, v, y: 200), 100, "取消：字馬上回來")
    }
}
