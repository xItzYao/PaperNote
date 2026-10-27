import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題：筆記捲動時會卡，筆跡很多的更明顯。每一格捲動都不能卡住畫面
final class NoteScrollTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// 12 頁、每頁寫滿 strokes 筆（自製筆刷或 PencilKit）
    private func openNotebook(customInk: Bool, strokes: Int) throws {
        let meta = LibraryStore.shared.createNotebook(title: "ScrollTest", folder: nil, paper: .ruled, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        var pages = [session.document.pages[0]]
        for _ in 1..<12 { pages.append(Page(background: .paper(width: 595, height: 842, style: .ruled))) }
        for k in pages.indices {
            var ink: [InkStroke] = []
            var pk: [PKStroke] = []
            for i in 0..<strokes {
                let x = CGFloat(30 + (i % 40) * 13), y = CGFloat(40 + (i / 40) * 20)
                var pts: [CGPoint] = []
                for j in 0..<30 { pts.append(CGPoint(x: x + sin(CGFloat(j) / 3) * 5, y: y + CGFloat(j) * 0.5)) }
                if customInk {
                    ink.append(InkStroke(colorHex: "#1A1A1AFF", points: pts.map { InkPoint($0, width: 1.2) }))
                } else {
                    pk.append(ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current))
                }
            }
            pages[k].ink = ink
            if !pk.isEmpty { session.drawings[pages[k].id] = PKDrawing(strokes: pk) }
        }
        session.document.pages = pages
        session.save()
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        spin(0.5)
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        editor = nil
        if let notebookID { LibraryStore.shared.deleteNotebook(notebookID) }
        super.tearDown()
    }

    /// 從頭捲到尾，回傳最卡的一格（秒）與平均
    private func scrollThrough() -> (worst: Double, average: Double, worstScroll: Double) {
        let canvas = editor.canvas
        let frame = 1.0 / 60
        var worst = 0.0, total = 0.0, steps = 0, worstScroll = 0.0
        var y: CGFloat = 0
        let maxY = canvas.contentSize.height - canvas.bounds.height
        var worstAt = ""
        while y < maxY {
            y = min(y + 120, maxY)
            let t = CACurrentMediaTime()
            canvas.contentOffset.y = y
            let t1 = CACurrentMediaTime()
            worstScroll = max(worstScroll, t1 - t)
            canvas.layoutIfNeeded()
            let t2 = CACurrentMediaTime()
            spin(frame)
            let cost = max(0, CACurrentMediaTime() - t - frame)
            if cost > worst {
                worstAt = "step=\(steps) y=\(Int(y)) scroll=\(Int((t1 - t) * 1000))ms layout=\(Int((t2 - t1) * 1000))ms runloop=\(Int((CACurrentMediaTime() - t2) * 1000))ms"
            }
            worst = max(worst, cost)
            total += cost
            steps += 1
        }
        print("SCROLLDIAG worst \(worstAt)")
        return (worst, total / Double(max(steps, 1)), worstScroll)
    }

    func testScrollingPagesFullOfCustomInk() throws {
        try openNotebook(customInk: true, strokes: 1600)
        let r = scrollThrough()
        print("SCROLLDIAG customInk worst=\(Int(r.worst * 1000))ms avg=\(String(format: "%.1f", r.average * 1000))ms")
        XCTAssertLessThan(r.worst, 0.05, "自製筆刷：捲動時有一格卡了 \(Int(r.worst * 1000))ms")
        // 捲動那一格本身（新頁面進來時）不能做重活；之前整頁筆跡在這裡建，CI 上 20ms、iPad 上更久
        XCTAssertLessThan(r.worstScroll, 0.012, "自製筆刷：新頁面進來時捲動那一格花了 \(Int(r.worstScroll * 1000))ms")
    }

    func testScrollingPagesFullOfPencilKitInk() throws {
        try openNotebook(customInk: false, strokes: 400)
        // 第一次捲過去時模擬器的 PencilKit 在主執行緒畫每一塊（iPad 上是背景、GPU 畫），偶爾一格超過 50ms；
        // 量第二次（App 自己的捲動工作，不是 PencilKit 第一次畫圖）
        let first = scrollThrough()
        print("SCROLLDIAG pencilKit first pass worst=\(Int(first.worst * 1000))ms")
        editor.canvas.contentOffset.y = 0
        spin(0.3)
        let r = scrollThrough()
        print("SCROLLDIAG pencilKit worst=\(Int(r.worst * 1000))ms avg=\(String(format: "%.1f", r.average * 1000))ms")
        XCTAssertLessThan(r.worst, 0.05, "PencilKit：捲動時有一格卡了 \(Int(r.worst * 1000))ms")
    }

    /// 捲動時新進來、還在畫面外的頁面：筆跡在背景準備，捲到之前就畫好
    func testOffscreenPageBuildsInkInBackground() throws {
        try openNotebook(customInk: true, strokes: 1600)
        let canvas = editor.canvas
        var newPage: PageContainerView?
        var y: CGFloat = 0
        while newPage == nil, y < canvas.contentSize.height - canvas.bounds.height {
            let before = Set(editor.pageViews.keys)
            y += 120
            canvas.contentOffset.y = y
            if let id = Set(editor.pageViews.keys).subtracting(before).first { newPage = editor.pageViews[id] }
        }
        let page = try XCTUnwrap(newPage, "捲動時應該有新頁面進來")
        XCTAssertFalse(page.frame.intersects(editor.visibleDocRect()), "新進來的頁面應該還在畫面外")
        XCTAssertTrue(page.inkView.isBuilding, "畫面外的頁面不該在捲動那一格建筆跡")
        spin(0.5)
        XCTAssertFalse(page.inkView.isBuilding)
        XCTAssertTrue(page.inkView.showsBitmap, "背景畫好之後整頁是一張圖")
        for v in editor.pageViews.values {
            XCTAssertTrue(v.inkView.showsBitmap, "捲動時每一頁的筆跡都是一張圖，不是一堆向量層")
        }
    }
}
