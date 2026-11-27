import XCTest
@testable import PaperNote

/// 回報的問題（11/26）：自製筆刷的字很多的頁面（877 筆、3 萬 7 千點）放很大（一行約 12 個字）上下左右捲動很卡
final class ZoomedInkScrollTests: XCTestCase {
    func testScrollingAZoomedInPageFullOfInkKeepsTheVisibleAreaSharp() throws {
        let meta = LibraryStore.shared.createNotebook(title: "ZoomedInk", folder: nil, paper: .blank, landscape: false)
        defer { LibraryStore.shared.deleteNotebook(meta.id) }
        let session = try NotebookSession(id: meta.id)
        session.document.pages[0].ink = (0..<877).map { i in
            let left = 30 + CGFloat(i % 30) * 17, top = 40 + CGFloat(i / 30) * 26
            return InkStroke(colorHex: "#1E3A8AFF", points: (0..<42).map { k in
                InkPoint(CGPoint(x: left + CGFloat(k) * 0.3, y: top + sin(CGFloat(k) / 3) * 6), width: 1.6)
            })
        }
        session.save()
        let editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        let window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.view.layoutIfNeeded()
        let canvas = editor.canvas
        canvas.setZoomScale(canvas.maximumZoomScale, animated: false)
        let page = editor.pageFrames[0]
        canvas.setContentOffset(CGPoint(x: page.minX * canvas.zoomScale + 100, y: page.minY * canvas.zoomScale + 200), animated: false)
        let ink = try XCTUnwrap(editor.pageViews[editor.pages[0].id]).inkView
        func settle() {
            let deadline = Date().addingTimeInterval(5)
            repeat { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } while (ink.isBuilding || ink.detailRegion == nil) && Date() < deadline
        }
        settle()
        XCTAssertGreaterThan(ink.renderScale, 4, "測試的前提：放得夠大")

        // 一格一格往右下捲，量每一格主執行緒花多久
        var frames = FrameTimes()
        for _ in 0..<120 {
            let t = CACurrentMediaTime()
            canvas.contentOffset = CGPoint(x: canvas.contentOffset.x + 3, y: canvas.contentOffset.y + 5)
            frames.add(CACurrentMediaTime() - t)
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
        }
        print(String(format: "ZOOMSCROLL %@ scale=%.1f", frames.summary, ink.renderScale))
        assertFast(frames, under: 0.016, "捲動一格不超過一格畫面的時間")
        settle()
        let visible = editor.visibleDocRect().intersection(ink.frame).offsetBy(dx: -ink.frame.minX, dy: -ink.frame.minY)
        let r = try XCTUnwrap(ink.detailRegion, "放很大時有清晰範圍")
        XCTAssertTrue(r.insetBy(dx: -1, dy: -1).contains(visible), "停下來後清晰範圍蓋住看得到的地方：\(r) \(visible)")
        XCTAssertFalse(ink.layer.sublayers?.contains { $0 is CAShapeLayer } ?? false, "沒有向量層")
    }
}
