import XCTest
import UIKit
@testable import PaperNote

/// 回報的問題（11/23）：
/// 1. 筆記本第一次打開時往下捲了一截，沒有停在最上面
/// 2. 點旁邊的空白處要能取消選取（手指點也可以，但不能因此選到、放上、貼上別的東西）
final class EditorRequestsNov23Tests: XCTestCase {
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

    override func setUpWithError() throws {
        savedFingerDrawing = EditorSettings.shared.fingerDrawing
        EditorSettings.shared.fingerDrawing = false
        let meta = LibraryStore.shared.createNotebook(title: "Nov23", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        for _ in 0..<4 { session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .blank))) }
        session.save()
        window = try TestWindow.make()
        show(session, page: nil)
    }

    override func tearDown() {
        editor.endTextEditing()
        EditorSettings.shared.fingerDrawing = savedFingerDrawing
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func show(_ session: NotebookSession, page: UUID?) {
        editor = NotebookViewController(session: session, initialPageID: page, onClose: {})
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        spin(0.3)
    }

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private func doc(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    /// 離所有東西都很遠的空白處
    private var blank: CGPoint { doc(500, 780) }

    /// 3 欄 2 列、每格 100×50：x 100…400、y 150…250
    private func addTable() throws -> ElementRef {
        let t = TableData.make(rows: 2, cols: 3, cellWidth: 100, cellHeight: 50)
        return try XCTUnwrap(editor.insertElement(.table(t), size: t.size, at: doc(250, 200)))
    }

    private func selectTable() throws -> ElementRef {
        let ref = try addTable()
        editor.setTool(.select)
        editor.select(ref)
        return ref
    }

    /// 手指點一下：手勢不收的話什麼都不會發生
    @discardableResult
    private func fingerTap(_ p: CGPoint) throws -> Bool {
        let g = try XCTUnwrap(editor.tapGesture)
        guard editor.gestureRecognizer(g, shouldReceive: FakeTouch(type: .direct, location: p)) else { return false }
        editor.handleTap(FakeTap(p))
        return true
    }

    // MARK: 1. 打開時停在最上面

    func testANotebookOpensAtTheTop() {
        XCTAssertEqual(editor.canvas.contentOffset.y, 0, accuracy: 1, "打開時要停在最上面")
        XCTAssertEqual(editor.visibleDocRect().minX, 0, accuracy: 1, "左右也要對齊")
    }

    func testANotebookStillOpensOnTheRememberedPage() throws {
        let session = try NotebookSession(id: notebookID)
        show(session, page: session.document.pages[2].id)
        XCTAssertEqual(editor.currentPageIndex, 2, "記住的那一頁照樣要回去")
        XCTAssertGreaterThan(editor.canvas.contentOffset.y, 100)
    }

    // MARK: 2. 點空白處取消選取

    func testAFingerTapOnBlankPaperClearsTheSelectedObject() throws {
        _ = try selectTable()
        try fingerTap(blank)
        XCTAssertNil(editor.selected)
    }

    func testAFingerTapRightBesideTheObjectClearsItWithoutPickingTheInkThere() throws {
        _ = try selectTable()
        let ink = InkStroke(colorHex: "#1A1A1AFF", points: (0...8).map { InkPoint(CGPoint(x: 110 + CGFloat($0) * 10, y: 276), width: 2) })
        editor.updatePage(0, undoable: false) { $0.ink = [ink] }
        try fingerTap(doc(150, 276))
        XCTAssertNil(editor.selected, "表格取消選取")
        XCTAssertNil(editor.lassoSel, "手指不能順便選到旁邊的筆跡")
    }

    func testOneBlankTapFinishesTypingAndClears() throws {
        let ref = try selectTable()
        editor.beginTextEditing(ref, cell: (row: 0, col: 0))
        try fingerTap(blank)
        XCTAssertNil(editor.editingTextView, "結束打字")
        XCTAssertNil(editor.selected, "同一下就取消選取")
    }

    func testOnePencilTapFinishesTypingAndClears() throws {
        let ref = try selectTable()
        editor.beginTextEditing(ref, cell: (row: 0, col: 0))
        editor.handleTap(FakeTap(blank))
        XCTAssertNil(editor.editingTextView, "結束打字")
        XCTAssertNil(editor.selected, "同一下就取消選取")
    }

    func testAFingerTapOnBlankPaperClearsTheLassoSelection() throws {
        let ref = try addTable()
        editor.setTool(.lasso)
        let o = editor.contentOrigin(0)
        editor.lassoSel = LassoSelection(strokeIndices: [], elements: [ref], highlights: [],
                                         bounds: CGRect(x: o.x + 100, y: o.y + 150, width: 300, height: 100))
        try fingerTap(blank)
        XCTAssertNil(editor.lassoSel)
    }

    func testAFingerTapOnBlankPaperClearsInTheImageTool() throws {
        let ref = try addTable()
        editor.setTool(.image)
        editor.select(ref)
        try fingerTap(blank)
        XCTAssertNil(editor.selected)
    }

    func testAFingerTapOnBlankPaperClearsTheCircuitWithoutPlacingAPart() throws {
        var d = CircuitData()
        let part = CircuitComponent(part: .resistor, position: CGPoint(x: 120, y: 100))
        d.components = [part]
        let ref = try XCTUnwrap(editor.insertElement(.circuit(d), size: CGSize(width: 240, height: 200), at: doc(250, 420)))
        editor.setTool(.circuit)
        editor.selectCircuitMode(.place(.capacitor))
        editor.circuitTarget = ref
        editor.circuitSel = .component(part.id)
        try fingerTap(blank)
        XCTAssertNil(editor.circuitSel, "元件取消選取")
        XCTAssertNil(editor.circuitTarget, "電路圖的外框也不再亮著")
        XCTAssertEqual(editor.pages[0].elements.count, 1, "手指不能放上新的元件")
        XCTAssertEqual(editor.circuitInfo(ref)?.data.components.count, 1, "手指不能放上新的元件")
    }

    // MARK: 不能多做的事

    func testAFingerTapOnAnotherObjectKeepsTheSelection() throws {
        let ref = try selectTable()
        let t = TableData.make(rows: 2, cols: 2)
        _ = try XCTUnwrap(editor.insertElement(.table(t), size: CGSize(width: 200, height: 80), at: doc(250, 600)))
        editor.select(ref)
        XCTAssertFalse(try fingerTap(doc(220, 590)), "點在別的物件上：手指不選，也不算空白處")
        XCTAssertEqual(editor.selected, ref)
    }

    func testARestingHandRightAfterWritingKeepsTheSelection() throws {
        let ref = try selectTable()
        editor.lastPencilTime = CACurrentMediaTime()
        try fingerTap(blank)
        XCTAssertEqual(editor.selected, ref, "筆尖剛離開時碰到螢幕的是手")
        editor.lastPencilTime = 0
    }

    func testAFingerOnBlankPaperStillScrolls() throws {
        _ = try selectTable()
        let finger = FakeTouch(type: .direct, location: blank)
        XCTAssertFalse(editor.gestureRecognizer(try XCTUnwrap(editor.toolPan), shouldReceive: finger), "拖的是捲動頁面")
        editor.select(nil)
        XCTAssertFalse(try fingerTap(blank), "沒選著東西：手指點一下什麼都不做")
    }
}
