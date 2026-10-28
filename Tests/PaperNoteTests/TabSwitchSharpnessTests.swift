import XCTest
@testable import PaperNote

/// 回報的問題：切到別的分頁再切回來，電路圖（表格、文字框也一樣）變成不清楚的點陣圖，要滑一下才變回清楚的
final class TabSwitchSharpnessTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "TabSwitch", folder: nil, paper: .blank, landscape: false)
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

    private func drawnViews(_ v: UIView) -> [DrawnElementView] {
        ((v as? DrawnElementView).map { [$0] } ?? []) + v.subviews.flatMap(drawnViews)
    }

    func testZoomedElementsStaySharpAfterSwitchingTabs() throws {
        let t = TableData.make(rows: 2, cols: 2)
        let o = editor.contentOrigin(0)
        _ = editor.insertElement(.table(t), size: t.size, at: CGPoint(x: o.x + 200, y: o.y + 200))
        // 放大到 2 倍
        editor.canvas.zoomScale = editor.fitZoom * 2
        editor.scrollViewDidEndZooming(editor.canvas, with: nil, atScale: editor.canvas.zoomScale)
        let sharp = editor.elementContentScale
        let views = drawnViews(editor.view)
        XCTAssertFalse(views.isEmpty)
        for v in views { XCTAssertEqual(v.contentScaleFactor, sharp, accuracy: 0.01, "放大後用放大的解析度畫") }

        // 切到別的分頁再切回來（編輯器的畫面先離開視窗再放回去）
        window.rootViewController = UIViewController()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.rootViewController = editor
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        for v in drawnViews(editor.view) {
            XCTAssertEqual(v.contentScaleFactor, sharp, accuracy: 0.01, "切回來還是清楚的（不能退回螢幕預設的解析度）")
        }
    }
}
