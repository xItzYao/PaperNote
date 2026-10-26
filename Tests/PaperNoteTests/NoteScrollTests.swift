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
    private func scrollThrough() -> (worst: Double, average: Double) {
        let canvas = editor.canvas
        let frame = 1.0 / 60
        var worst = 0.0, total = 0.0, steps = 0
        var y: CGFloat = 0
        let maxY = canvas.contentSize.height - canvas.bounds.height
        while y < maxY {
            y = min(y + 120, maxY)
            let t = CACurrentMediaTime()
            canvas.contentOffset.y = y
            canvas.layoutIfNeeded()
            spin(frame)
            let cost = max(0, CACurrentMediaTime() - t - frame)
            worst = max(worst, cost)
            total += cost
            steps += 1
        }
        return (worst, total / Double(max(steps, 1)))
    }

    func testScrollingPagesFullOfCustomInk() throws {
        try openNotebook(customInk: true, strokes: 1600)
        let r = scrollThrough()
        print("SCROLLDIAG customInk worst=\(Int(r.worst * 1000))ms avg=\(String(format: "%.1f", r.average * 1000))ms")
        XCTAssertLessThan(r.worst, 0.05, "自製筆刷：捲動時有一格卡了 \(Int(r.worst * 1000))ms")
    }

    func testScrollingPagesFullOfPencilKitInk() throws {
        try openNotebook(customInk: false, strokes: 400)
        let r = scrollThrough()
        print("SCROLLDIAG pencilKit worst=\(Int(r.worst * 1000))ms avg=\(String(format: "%.1f", r.average * 1000))ms")
        XCTAssertLessThan(r.worst, 0.05, "PencilKit：捲動時有一格卡了 \(Int(r.worst * 1000))ms")
    }
}
