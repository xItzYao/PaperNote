import XCTest
@testable import PaperNote

/// 回報的問題：套索圈好之後選單馬上蓋在選取範圍上，沒辦法拖曳移動。
/// 圈選、移動、貼上後都不跳選單；點一下選取範圍才打開
final class LassoMenuTests: XCTestCase {
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

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "LassoMenuTest", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // 頁面上有一筆字（頁面內容座標 100…200, 300）
        editor.updatePage(0) {
            $0.ink = [InkStroke(colorHex: "#1A1A1AFF", points: (0...10).map { InkPoint(CGPoint(x: 100 + CGFloat($0) * 10, y: 300), width: 2) })]
        }
        editor.setTool(.lasso)
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

    /// 用 Pencil 拖一次：points 依序是按下、移動…、放開
    private func drag(_ points: [CGPoint]) {
        let g = FakePan(target: nil, action: nil)
        for (i, p) in points.enumerated() {
            g.fake = i == 0 ? .began : (i == points.count - 1 ? .ended : .changed)
            editor.handleLassoPan(g, p)
        }
    }

    private func circleTheStroke() {
        drag([doc(80, 280), doc(220, 280), doc(220, 320), doc(80, 320), doc(80, 282), doc(81, 281)])
    }

    func testSelectingDoesNotPopUpTheMenu() {
        circleTheStroke()
        XCTAssertNotNil(editor.lassoSel, "要圈到那一筆")
        XCTAssertNil(editor.pendingMenu, "圈好之後不能馬上跳選單（會蓋住要拖的東西）")
    }

    func testMovingDoesNotPopUpTheMenu() throws {
        circleTheStroke()
        drag([doc(150, 300), doc(170, 330), doc(190, 360)])
        XCTAssertNil(editor.pendingMenu, "移動完也不跳選單，才能接著再拖")
        let moved = try XCTUnwrap(editor.pages[0].ink.first)
        XCTAssertEqual(moved.points[0].point.y, 360, accuracy: 0.01, "真的移動了")
    }

    func testPastingDoesNotPopUpTheMenu() {
        let stroke = InkStroke(colorHex: "#1A1A1AFF", points: [InkPoint(doc(0, 0), width: 2), InkPoint(doc(50, 0), width: 2)])
        let clip = LassoClipboard(strokes: [], elements: [], highlights: [], bounds: CGRect(origin: doc(0, 0), size: CGSize(width: 50, height: 2)),
                                  changeCount: 0, ink: [stroke])
        editor.pasteLasso(clip, center: doc(300, 500))
        XCTAssertNotNil(editor.lassoSel)
        XCTAssertNil(editor.pendingMenu, "貼上後也不跳選單，可以直接拖到想要的位置")
    }

    func testTapInsideSelectionOpensTheMenu() {
        circleTheStroke()
        editor.handleTap(FakeTap(doc(150, 300)))
        XCTAssertNotNil(editor.pendingMenu, "點一下選取範圍要打開選單")
    }
}
