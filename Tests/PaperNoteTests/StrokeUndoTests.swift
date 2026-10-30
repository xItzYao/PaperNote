import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題：螢光筆有些筆跡按上一步回不去、有些可以。
/// 畫完被程式換掉的那一筆（接近直線自動拉直、超出頁面遮掉）PencilKit 自己的上一步找不到，要自己登記
final class StrokeUndoTests: XCTestCase {
    /// 這裡測的是 PencilKit 的筆（App 預設用自製筆刷）
    override func invokeTest() { withPencilKitPen { super.invokeTest() } }
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "StrokeUndo", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        spin(0.3)
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

    /// 模擬 PencilKit 畫完一筆：開始用工具 → 筆跡加進去 → 結束用工具
    private func draw(_ pts: [CGPoint]) -> Int {
        let before = editor.canvas.drawing.strokes.count
        editor.canvasViewDidBeginUsingTool(editor.canvas)
        var d = editor.canvas.drawing
        d.strokes.append(ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current))
        editor.canvas.drawing = d
        editor.canvasViewDidEndUsingTool(editor.canvas)
        spin(0.3)
        return before
    }

    func testStraightenedHighlighterStrokeCanBeUndone() throws {
        editor.setTool(.highlighter)
        let o = editor.contentOrigin(0)
        let pts = (0...40).map { CGPoint(x: o.x + 100 + CGFloat($0) * 5, y: o.y + 200 + sin(CGFloat($0)) * 1.5) }
        let before = draw(pts)
        let last = try XCTUnwrap(editor.canvas.drawing.strokes.last)
        let ys = last.path.map { $0.location.applying(last.transform).y }
        XCTAssertLessThan((ys.max() ?? 0) - (ys.min() ?? 0), 0.5, "接近直線的螢光筆被拉直了")
        editor.undoTapped()
        spin(0.2)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, before, "按一次上一步就拿掉被拉直的那一筆")
        editor.redoTapped()
        spin(0.2)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, before + 1, "下一步再放回來")
    }

    func testStrokeCrossingThePageEdgeCanBeUndone() throws {
        editor.setTool(.pen)
        var p = BrushStore.shared.current
        p.dashed = false
        BrushStore.shared.update(p)
        let f = editor.pageFrames[0]
        // 從頁面裡畫到頁面右邊外面，彎彎的不會被拉直
        let pts = (0...40).map { CGPoint(x: f.maxX - 100 + CGFloat($0) * 5, y: f.minY + 200 + sin(CGFloat($0) / 3) * 20) }
        let before = draw(pts)
        XCTAssertNotNil(editor.canvas.drawing.strokes.last?.mask, "超出頁面的部分被遮掉了")
        editor.undoTapped()
        spin(0.2)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, before, "按一次上一步就拿掉被遮掉的那一筆")
    }
}
