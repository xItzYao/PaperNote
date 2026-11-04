import XCTest
import PencilKit
@testable import PaperNote

/// 回報的需求：選取工具可以選筆跡（不只物件），選起來的筆跡可以等比例縮放（套索圈的也可以）
final class SelectInkTests: XCTestCase {
    private final class FakeTap: UITapGestureRecognizer {
        let point: CGPoint
        init(_ p: CGPoint) {
            point = p
            super.init(target: nil, action: nil)
        }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private final class FakeLongPress: UILongPressGestureRecognizer {
        let point: CGPoint
        init(_ p: CGPoint) {
            point = p
            super.init(target: nil, action: nil)
        }
        override var state: UIGestureRecognizer.State {
            get { .began }
            set {}
        }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var inkID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "SelectInkTest", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // 自製筆刷一筆（頁面內容座標 100…200, 300，粗 2），PencilKit 一筆（100…200, 500）
        let ink = InkStroke(colorHex: "#1A1A1AFF", points: (0...10).map { InkPoint(CGPoint(x: 100 + CGFloat($0) * 10, y: 300), width: 2) })
        inkID = ink.id
        editor.updatePage(0, undoable: false) { $0.ink = [ink] }
        let pk = ShapeRecognizer.makeStroke(points: ShapeRecognizer.segment(doc(100, 500), doc(200, 500)),
                                            preset: BrushPreset(style: .monoline, colorHex: "#000000FF", width: 3))
        editor.setDrawing(PKDrawing(strokes: [pk]))
        editor.setTool(.select)
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func doc(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    private func tap(_ p: CGPoint) { editor.handleTap(FakeTap(p)) }

    /// 選取工具拖一次（從 start 拖到 end）
    private func drag(_ start: CGPoint, _ end: CGPoint) {
        TouchPan().drag(from: start, to: end) { editor.handleToolPan($0) }
    }

    private var ink: InkStroke? { editor.pages[0].ink.first { $0.id == inkID } }

    // MARK: 選筆跡

    func testTappingInkSelectsIt() throws {
        tap(doc(150, 302))
        let sel = try XCTUnwrap(editor.lassoSel, "點在筆跡上要選起來")
        XCTAssertEqual(sel.ink.map(\.id), [inkID])
        XCTAssertTrue(sel.strokeIndices.isEmpty, "只選點到的那一筆")
        XCTAssertNil(editor.selected)
        XCTAssertNil(editor.pendingMenu, "選起來不馬上跳選單（才能直接拖）")
    }

    func testTappingAPencilKitStrokeSelectsIt() throws {
        tap(doc(150, 503))
        let sel = try XCTUnwrap(editor.lassoSel, "PencilKit 的筆跡也能選")
        XCTAssertEqual(sel.strokeIndices, [0])
        XCTAssertTrue(sel.ink.isEmpty)
    }

    func testTappingEmptySpaceClearsTheSelection() {
        tap(doc(150, 302))
        XCTAssertNotNil(editor.lassoSel)
        tap(doc(400, 700))
        XCTAssertNil(editor.lassoSel, "點空白處取消")
    }

    func testTappingTheSelectedInkOpensTheMenu() {
        tap(doc(150, 302))
        tap(doc(150, 302))
        XCTAssertNotNil(editor.pendingMenu, "再點一下打開選單（拷貝、刪除、改顏色…）")
    }

    /// 回報的問題：選取工具點下去大約 0.5 秒才選到（一直在等「點兩下」）
    func testTappingInkOrEmptySpaceDoesNotWaitForADoubleTap() throws {
        XCTAssertFalse(editor.tapWaitsForDoubleTap(at: doc(150, 302)), "點筆跡馬上選")
        XCTAssertFalse(editor.tapWaitsForDoubleTap(at: doc(400, 700)), "點空白處馬上取消")
        let ref = try XCTUnwrap(editor.insertElement(.circuit(CircuitData()), size: CGSize(width: 200, height: 150), at: doc(300, 850)))
        let info = try XCTUnwrap(editor.circuitInfo(ref))
        let center = editor.docFrame(of: info.element, pageIndex: info.pi).center
        XCTAssertTrue(editor.tapWaitsForDoubleTap(at: center), "物件上點兩下有用（編輯電路圖、文字），要等")
    }

    /// 回報的問題：電路圖右下角的縮放把手拉了沒反應
    func testASelectedCircuitHasNoResizeHandle() throws {
        let ref = try XCTUnwrap(editor.insertElement(.circuit(CircuitData()), size: CGSize(width: 200, height: 150), at: doc(300, 850)))
        editor.setTool(.select)
        editor.select(ref)
        XCTAssertEqual(editor.selected, ref)
        XCTAssertTrue(editor.overlay.resizeHandleImage.isHidden, "電路圖不能拉角落縮放，不顯示把手")
        let info = try XCTUnwrap(editor.circuitInfo(ref))
        let r = editor.docFrame(of: info.element, pageIndex: info.pi)
        if case .resize? = editor.dragTarget(at: CGPoint(x: r.maxX, y: r.maxY))?.1 { XCTFail("角落不是縮放") }
    }

    func testLongPressOnInkSelectsItAndOpensTheMenu() {
        editor.handleLongPress(FakeLongPress(doc(150, 302)))
        XCTAssertEqual(editor.lassoSel?.ink.map(\.id), [inkID])
        XCTAssertNotNil(editor.pendingMenu)
    }

    func testDraggingMovesTheSelectedInk() throws {
        tap(doc(150, 302))
        drag(doc(150, 300), doc(150, 400))
        let moved = try XCTUnwrap(ink)
        XCTAssertEqual(moved.points[0].point.y, 400, accuracy: 0.01, "拖曳移動")
        XCTAssertEqual(moved.points[0].width, 2, accuracy: 0.01, "移動不改粗細")
        XCTAssertNotNil(editor.lassoSel, "移動完還是選著")
    }

    // MARK: 等比例縮放

    func testDraggingTheCornerScalesInkProportionally() throws {
        tap(doc(150, 302))
        let b = try XCTUnwrap(editor.lassoSel).bounds
        let handle = try XCTUnwrap(editor.lassoScaleHandle(b), "只選到筆跡：右下角有縮放把手")
        drag(handle, CGPoint(x: handle.x + b.width, y: handle.y + b.height))
        let s = try XCTUnwrap(ink)
        let first = s.points[0].point, last = s.points[s.points.count - 1].point
        XCTAssertEqual(last.x - first.x, 200, accuracy: 0.1, "放大兩倍")
        XCTAssertEqual(last.y - first.y, 0, accuracy: 0.1, "等比例：水平線還是水平線")
        XCTAssertEqual(s.points[0].width, 4, accuracy: 0.01, "線也跟著變粗")
        // 以左上角為基準：左上角不動
        let a = b.origin - editor.contentOrigin(0)
        XCTAssertEqual(first.x, a.x + (100 - a.x) * 2, accuracy: 0.1)
        XCTAssertEqual(first.y, a.y + (300 - a.y) * 2, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(editor.lassoSel).bounds.width, b.width * 2, accuracy: 0.1, "選取框跟著變大")
    }

    /// 回報的問題：拉大筆跡時，要放開才清楚，拖的時候很糊（預覽圖被拉大）
    func testScalingRedrawsThePreviewAtTheNewSize() throws {
        tap(doc(150, 302))
        let b = try XCTUnwrap(editor.lassoSel).bounds
        let handle = try XCTUnwrap(editor.lassoScaleHandle(b))
        let pan = TouchPan()
        pan.point = handle
        pan.fake = .began
        editor.handleToolPan(pan)
        let before = try XCTUnwrap(editor.overlay.lassoPreviewLayer.contents.map { $0 as! CGImage })
        pan.moved = CGPoint(x: b.width * 2, y: b.height * 2)
        pan.point = CGPoint(x: handle.x + pan.moved.x, y: handle.y + pan.moved.y)
        pan.fake = .changed
        editor.handleToolPan(pan)
        let during = try XCTUnwrap(editor.overlay.lassoPreviewLayer.contents.map { $0 as! CGImage })
        XCTAssertEqual(Double(during.width), Double(before.width) * 3, accuracy: Double(before.width) * 0.1,
                       "放大三倍時預覽圖也是三倍大，不是把原本的圖拉大")
        XCTAssertEqual(editor.overlay.lassoPreviewLayer.frame.width, b.width * 3, accuracy: 0.5)
        pan.fake = .ended
        editor.handleToolPan(pan)
        XCTAssertTrue(editor.overlay.lassoPreviewLayer.isHidden)
    }

    func testScalingAPencilKitStroke() throws {
        tap(doc(150, 503))
        let b = try XCTUnwrap(editor.lassoSel).bounds
        let handle = try XCTUnwrap(editor.lassoScaleHandle(b))
        drag(handle, CGPoint(x: handle.x + b.width, y: handle.y + b.height))
        let s = try XCTUnwrap(editor.canvas.drawing.strokes.last)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(s.transform.a, 2, accuracy: 0.01)
        XCTAssertEqual(s.transform.d, 2, accuracy: 0.01)
        XCTAssertEqual(s.renderBounds.minX, b.minX, accuracy: 1, "左上角不動")
        XCTAssertEqual(editor.lassoSel?.strokeIndices, [0], "縮放完還是選著")
    }

    func testScalingIsOneUndoStep() throws {
        let before = try XCTUnwrap(ink)
        tap(doc(150, 302))
        let b = try XCTUnwrap(editor.lassoSel).bounds
        let handle = try XCTUnwrap(editor.lassoScaleHandle(b))
        drag(handle, CGPoint(x: handle.x + b.width, y: handle.y + b.height))
        XCTAssertNotEqual(ink, before)
        editor.undoTapped()
        XCTAssertEqual(ink, before, "按一次復原回到原本的大小")
    }

    func testScalingStaysOnThePage() throws {
        tap(doc(150, 302))
        let b = try XCTUnwrap(editor.lassoSel).bounds
        let handle = try XCTUnwrap(editor.lassoScaleHandle(b))
        drag(handle, CGPoint(x: handle.x + 5000, y: handle.y + 5000))
        let page = editor.pageFrames[0]
        XCTAssertLessThanOrEqual(try XCTUnwrap(editor.lassoSel).bounds.maxX, page.maxX + 0.5, "放大到頁面邊緣為止")
        drag(editor.lassoScaleHandle(try XCTUnwrap(editor.lassoSel).bounds)!, CGPoint(x: b.minX - 5000, y: b.minY - 5000))
        XCTAssertGreaterThan(try XCTUnwrap(editor.lassoSel).bounds.width, 10, "縮小也不會縮到看不見")
    }

    func testCircledInkScalesWithTheLassoToo() throws {
        editor.setTool(.lasso)
        let pts = [doc(80, 280), doc(220, 280), doc(220, 320), doc(80, 320), doc(80, 282), doc(81, 281)]
        let g = TouchPan()
        for (i, p) in pts.enumerated() {
            g.fake = i == 0 ? .began : (i == pts.count - 1 ? .ended : .changed)
            editor.handleLassoPan(g, p)
        }
        let b = try XCTUnwrap(editor.lassoSel, "要圈到那一筆").bounds
        let handle = try XCTUnwrap(editor.lassoScaleHandle(b))
        XCTAssertEqual(editor.lassoGrab(at: handle), .scale)
        XCTAssertEqual(editor.lassoGrab(at: CGPoint(x: b.midX, y: b.midY)), .move)
        drag(handle, CGPoint(x: handle.x + b.width / 2, y: handle.y + b.height / 2))
        XCTAssertEqual(try XCTUnwrap(ink).points[0].width, 3, accuracy: 0.01, "放大 1.5 倍")
    }

    func testObjectsInTheSelectionCannotBeScaled() {
        let ref = ElementRef(pageID: UUID(), elementID: UUID())
        let withObject = LassoSelection(strokeIndices: [0], elements: [ref], highlights: [], bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertFalse(withObject.canScale, "物件有自己的大小：圈到物件時只能移動")
        let inkOnly = LassoSelection(strokeIndices: [0], elements: [], highlights: [], bounds: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertTrue(inkOnly.canScale)
    }

    func testTouchingAStrokeNeedsToBeOnIt() {
        let line = ShapeRecognizer.makeStroke(points: ShapeRecognizer.segment(CGPoint(x: 0, y: 50), CGPoint(x: 400, y: 50)),
                                              preset: BrushPreset(style: .monoline, colorHex: "#000000FF", width: 3))
        XCTAssertTrue(LassoGeometry.touches(line, at: CGPoint(x: 200, y: 54), radius: 4))
        XCTAssertFalse(LassoGeometry.touches(line, at: CGPoint(x: 200, y: 70), radius: 4))
    }
}

/// 回報的問題：切到別的 App 再切回來，頁面跳到那一頁的最上面，不是原本看的位置。
/// App 切到背景時系統會用另一個方向排版截圖（畫面寬度變了又變回來）
final class ResumePositionTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "ResumePositionTest", folder: nil, paper: .ruled, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        for _ in 0..<3 { session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .ruled))) }
        session.save()
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

    private func resize(_ size: CGSize) {
        window.frame = CGRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        editor.view.frame = window.bounds
        editor.view.layoutIfNeeded()
    }

    func testLayingOutAtAnotherWidthAndBackKeepsThePosition() {
        let canvas = editor.canvas
        // 捲到第二頁的中間
        canvas.contentOffset.y = (editor.pageFrames[1].minY + 400) * canvas.zoomScale
        let before = editor.visibleDocRect().minY
        let offset = canvas.contentOffset.y
        let size = window.bounds.size
        resize(CGSize(width: size.height, height: size.width))
        XCTAssertNotEqual(canvas.bounds.width, size.width, accuracy: 1, "真的換了寬度")
        XCTAssertEqual(editor.visibleDocRect().minY, before, accuracy: 1, "換方向：畫面最上面還是同一個位置")
        resize(size)
        XCTAssertEqual(editor.visibleDocRect().minY, before, accuracy: 1, "換回來：回到原本看的地方，不是那一頁的最上面")
        XCTAssertEqual(canvas.contentOffset.y, offset, accuracy: 1)
    }
}
