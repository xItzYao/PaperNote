import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題：「全部頁面」捲動時會卡。縮圖不能在主執行緒畫，捲動的每一格都要很快
final class PageOverviewTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "OverviewTest", folder: nil, paper: .ruled, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        // 60 頁、每頁寫滿 300 筆
        var pages = [session.document.pages[0]]
        for _ in 1..<60 { pages.append(Page(background: .paper(width: 595, height: 842, style: .ruled))) }
        session.document.pages = pages
        for (k, page) in pages.enumerated() {
            var strokes: [PKStroke] = []
            for i in 0..<300 {
                let y = CGFloat(40 + (i / 6) * 15), x = CGFloat(40 + (i % 6) * 85)
                var pts: [CGPoint] = []
                for j in 0..<30 { pts.append(CGPoint(x: x + CGFloat(j) * 2.5, y: y + sin(CGFloat(j + k) / 2) * 5)) }
                strokes.append(ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current))
            }
            session.drawings[page.id] = PKDrawing(strokes: strokes)
        }
        editor = NotebookViewController(session: session, initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
    }

    override func tearDown() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func collectionView(in v: UIView) -> UICollectionView? {
        if let c = v as? UICollectionView { return c }
        for s in v.subviews { if let c = collectionView(in: s) { return c } }
        return nil
    }

    func testScrollingDoesNotBlockTheScreen() throws {
        let overview = PageOverviewController(editor: editor)
        editor.present(UINavigationController(rootViewController: overview), animated: false)
        spin(0.5)
        let collection = try XCTUnwrap(collectionView(in: overview.view))
        collection.setContentOffset(.zero, animated: false)
        spin(1.0)
        // 一格一格往下捲：每一格（含這一格要做的事）都不能卡住畫面
        var worst = 0.0
        let frame = 1.0 / 60
        var y: CGFloat = 0
        let maxY = collection.contentSize.height - collection.bounds.height
        XCTAssertGreaterThan(maxY, 1000, "測試前提：要捲得夠長")
        while y < maxY {
            y = min(y + 200, maxY)
            let t = CACurrentMediaTime()
            collection.contentOffset.y = y
            collection.layoutIfNeeded()
            spin(frame)
            worst = max(worst, CACurrentMediaTime() - t - frame)
        }
        XCTAssertLessThan(worst, 0.05, "捲動時有一格卡了 \(Int(worst * 1000))ms")
        // 停下來之後縮圖還是要出來
        spin(3)
        let cells = collection.visibleCells.compactMap { $0 as? PageThumbCell }
        XCTAssertFalse(cells.isEmpty)
        XCTAssertTrue(cells.allSatisfy { $0.thumbnail != nil }, "畫面上的縮圖都要畫好")
    }
}
