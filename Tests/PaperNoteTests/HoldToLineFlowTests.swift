import XCTest
import PencilKit
@testable import PaperNote

/// 在真的筆記本裡跑一次「手繪一筆 → 停住 → 放開」，確認頁面上真的留下一條直線
final class HoldToLineFlowTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "HoldToLineTest", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        editor = NotebookViewController(session: session, initialPageID: nil, onClose: {})
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        spin(0.3)
        editor.setTool(.pen)
        var p = BrushStore.shared.current
        p.dashed = false
        BrushStore.shared.update(p)
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 頁面上第一頁內容區裡的點（文件座標）
    private func docPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    private func handStroke(_ pts: [CGPoint]) -> PKStroke {
        ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current)
    }

    /// 模擬一次停住變直線；pencilKitEndsFirst 決定 PencilKit 收尾和筆離開哪個先發生
    private func drawHoldLine(pencilKitEndsFirst: Bool) -> (before: Int, after: [PKStroke]) {
        let before = editor.canvas.drawing.strokes.count
        editor.canvasViewDidBeginUsingTool(editor.canvas)
        let wobbly = (0...40).map { docPoint(100 + CGFloat($0) * 5, 200 + sin(CGFloat($0)) * 3) }
        editor.holdToShape.hold(wobbly)
        editor.holdToShape.move(docPoint(300, 202))
        // PencilKit 把手繪那一筆放進筆跡
        var d = editor.canvas.drawing
        d.strokes.append(handStroke(wobbly + [docPoint(300, 202)]))
        editor.canvas.drawing = d
        if pencilKitEndsFirst {
            editor.canvasViewDidEndUsingTool(editor.canvas)
            editor.holdToShape.end(docPoint(300, 202), cancelled: false)
        } else {
            editor.holdToShape.end(docPoint(300, 202), cancelled: false)
            editor.canvasViewDidEndUsingTool(editor.canvas)
        }
        spin(2.0)
        return (before, editor.canvas.drawing.strokes)
    }

    private func assertStraightLineReplacedHand(_ result: (before: Int, after: [PKStroke]), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.after.count, result.before + 1, "應該只多一條線（手繪那一筆要被換掉）", file: file, line: line)
        guard let last = result.after.last else { return XCTFail("沒有筆跡", file: file, line: line) }
        let ys = last.path.map { $0.location.applying(last.transform).y }
        XCTAssertLessThan((ys.max() ?? 0) - (ys.min() ?? 0), 1, "換上去的應該是水平直線", file: file, line: line)
        // 真的畫得出來
        let image = PKDrawing(strokes: [last]).image(from: last.renderBounds.insetBy(dx: -4, dy: -4), scale: 1)
        XCTAssertNotNil(image.cgImage, file: file, line: line)
        XCTAssertGreaterThan(last.renderBounds.width, 150, file: file, line: line)
    }

    func testLineIsPlacedWhenPenLiftsBeforePencilKitFinishes() {
        assertStraightLineReplacedHand(drawHoldLine(pencilKitEndsFirst: false))
    }

    func testLineIsPlacedWhenPencilKitFinishesFirst() {
        assertStraightLineReplacedHand(drawHoldLine(pencilKitEndsFirst: true))
    }

    func testUndoRemovesTheLine() {
        let result = drawHoldLine(pencilKitEndsFirst: false)
        editor.undoTapped()
        spin(0.3)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, result.before)
    }

    func testPrintPencilKitWidthRanges() {
        for t: PKInk.InkType in [.pen, .monoline, .fountainPen, .pencil, .marker, .crayon, .watercolor] {
            print("WIDTHRANGE \(t.rawValue) \(t.validWidthRange)")
        }
    }
}
