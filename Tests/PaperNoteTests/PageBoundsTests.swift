import XCTest
@testable import PaperNote

/// 回報的需求：
/// 1. 捲到最後一頁底下就停住；再往上拉出現＋，問要新增哪種頁面
/// 2. 圖片、筆跡都不能超出頁面
final class PageBoundsTests: XCTestCase {
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
        let meta = LibraryStore.shared.createNotebook(title: "PageBoundsTest", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        for _ in 0..<2 { session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid))) }
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

    private var canvas: UIScrollView { editor.canvas }

    private var maxOffsetY: CGFloat {
        max(canvas.contentSize.height + canvas.adjustedContentInset.bottom - canvas.bounds.height, -canvas.adjustedContentInset.top)
    }

    private func pull(by over: CGFloat) {
        canvas.contentOffset.y = maxOffsetY + over
        editor.scrollViewDidScroll(canvas)
    }

    private func release() {
        editor.scrollViewDidEndDragging(canvas, willDecelerate: false)
    }

    // MARK: 最後一頁

    func testScrollingStopsAtTheBottomOfTheLastPage() throws {
        canvas.contentOffset.y = maxOffsetY
        let last = try XCTUnwrap(editor.pageFrames.last)
        let bottom = editor.visibleDocRect().maxY
        XCTAssertLessThanOrEqual(bottom - last.maxY, editor.docPadding + 1, "最後一頁底下不能再有一大段空白")
    }

    func testPullingPastTheEndOffersPageTemplates() throws {
        editor.pendingMenu = nil
        pull(by: NotebookViewController.addPagePullThreshold + 20)
        XCTAssertFalse(editor.addPagePull.isHidden, "拉過頭要出現＋")
        XCTAssertTrue(editor.addPagePull.armed)
        release()
        let menu = try XCTUnwrap(editor.pendingMenu, "放開要問新增哪種頁面")
        XCTAssertEqual(menu.children.map(\.title), PaperStyle.allCases.map(\.title))
    }

    func testShortPullDoesNotAddAPage() {
        editor.pendingMenu = nil
        pull(by: 30)
        XCTAssertFalse(editor.addPagePull.isHidden, "拉一點點就看得到＋")
        XCTAssertFalse(editor.addPagePull.armed)
        release()
        XCTAssertNil(editor.pendingMenu, "沒拉夠不會跳選單")
    }

    func testAppendingAPageUsesTheChosenTemplate() {
        let n = editor.pages.count
        editor.appendPage(style: .dotted)
        XCTAssertEqual(editor.pages.count, n + 1)
        XCTAssertEqual(editor.pages.last?.background, .paper(width: 595, height: 842, style: .dotted))
    }

    // MARK: 不超出頁面

    func testDraggedImageStaysOnThePage() throws {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 150)).image { _ in
            UIColor.red.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 200, height: 150))
        }
        editor.insertImage(img, jpeg: true, at: CGPoint(x: editor.pageFrames[0].midX, y: editor.pageFrames[0].midY))
        let ref = try XCTUnwrap(editor.selected)
        let start = try XCTUnwrap(editor.pages[0].elements.first).frame
        let o = editor.contentOrigin(0)
        let grab = CGPoint(x: start.midX + o.x, y: start.midY + o.y)
        let g = FakePan(target: nil, action: nil)
        // 往左上拖到頁面外很遠的地方
        for (i, d) in [CGFloat(0), -300, -900].enumerated() {
            g.fake = i == 0 ? .began : (i == 2 ? .ended : .changed)
            editor.handleElementPan(g, CGPoint(x: grab.x + d, y: grab.y + d))
        }
        guard case let (pi, ei)? = editor.locate(ref) else { return XCTFail("圖片不見了") }
        let frame = editor.pages[pi].elements[ei].frame.offsetBy(dx: editor.contentOrigin(pi).x, dy: editor.contentOrigin(pi).y)
        XCTAssertTrue(editor.pageFrames[pi].insetBy(dx: -0.5, dy: -0.5).contains(frame), "圖片要留在頁面裡：\(frame) 頁面 \(editor.pageFrames[pi])")
    }

    func testLassoMovedInkStaysOnThePage() throws {
        editor.updatePage(0) {
            $0.ink = [InkStroke(colorHex: "#1A1A1AFF", points: (0...10).map { InkPoint(CGPoint(x: 100 + CGFloat($0) * 10, y: 300), width: 2) })]
        }
        editor.setTool(.lasso)
        let o = editor.contentOrigin(0)
        func doc(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x, y: o.y + y) }
        func drag(_ pts: [CGPoint]) {
            let g = FakePan(target: nil, action: nil)
            for (i, p) in pts.enumerated() {
                g.fake = i == 0 ? .began : (i == pts.count - 1 ? .ended : .changed)
                editor.handleLassoPan(g, p)
            }
        }
        drag([doc(80, 280), doc(220, 280), doc(220, 320), doc(80, 320), doc(80, 282), doc(81, 281)])
        XCTAssertNotNil(editor.lassoSel)
        // 往右拖到頁面外
        drag([doc(150, 300), doc(900, 300), doc(2000, 300)])
        let s = try XCTUnwrap(editor.pages.flatMap(\.ink).first)
        let pi = try XCTUnwrap(editor.pages.firstIndex { !$0.ink.isEmpty })
        let b = InkGeometry.bounds(of: s).offsetBy(dx: editor.contentOrigin(pi).x, dy: editor.contentOrigin(pi).y)
        XCTAssertLessThanOrEqual(b.maxX, editor.pageFrames[pi].maxX + 3, "套索移動的筆跡不能超出頁面")
    }

    func testInkIsClippedToThePage() throws {
        let v = try XCTUnwrap(editor.pageViews[editor.pages[0].id])
        XCTAssertTrue(v.inkView.clipsToBounds, "頁面外的筆跡不畫")
        // 寫的時候也只畫在起點那一頁
        let start = CGPoint(x: editor.pageFrames[0].maxX - 10, y: editor.pageFrames[0].midY)
        editor.setTool(.pen)
        editor.inkBegan(.init(point: start, force: 0.5))
        let expected = editor.pagesContainer.convert(editor.pageFrames[0], to: editor.liveInkView)
        let clip = try XCTUnwrap(editor.liveInkView.clip)
        XCTAssertEqual(clip.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(clip.maxX, expected.maxX, accuracy: 0.5)
        editor.inkEnded(cancelled: true)
    }
}
