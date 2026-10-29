import XCTest
import PencilKit
@testable import PaperNote

/// 上一步／下一步改成編輯器自己的堆疊（最多 40 步）：
/// - 每個動作只登記一步，按一次就回到動作之前
/// - PencilKit 自己登記的上一步不會被執行（換掉筆跡後那些紀錄會失效）
/// - 系統的上一步手勢（三指滑動）走同一個堆疊；打字中的上一步留在文字框裡
final class EditHistoryTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "EditHistory", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
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

    private func spin(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func docPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    /// 模擬用 PencilKit 畫一筆（彎彎的，不會被拉直）
    private func drawStroke(y: CGFloat) {
        editor.canvasViewDidBeginUsingTool(editor.canvas)
        var d = editor.canvas.drawing
        let pts = (0...30).map { docPoint(100 + CGFloat($0) * 6, y + sin(CGFloat($0) / 2) * 15) }
        d.strokes.append(ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current))
        editor.canvas.drawing = d
        editor.canvasViewDidEndUsingTool(editor.canvas)
        spin(0.2)
    }

    private var strokeCount: Int { editor.canvas.drawing.strokes.count }

    // MARK: 堆疊本身

    func testHistoryKeepsAtMost40Steps() {
        let h = EditHistory()
        for i in 0..<45 {
            h.record(.init(drawing: PKDrawing(strokes: []), pages: [:]))
            h.endGroup()
            XCTAssertEqual(h.undoCount, min(i + 1, 40))
        }
        XCTAssertEqual(EditHistory.limit, 40)
    }

    func testRecordsInOneEventBecomeOneStep() {
        let h = EditHistory()
        let first = PKDrawing(strokes: [ShapeRecognizer.makeStroke(points: [.zero, CGPoint(x: 50, y: 0)], preset: BrushStore.shared.current)])
        h.record(.init(drawing: first, pages: [:]))
        h.record(.init(drawing: PKDrawing(strokes: []), pages: [:]))
        XCTAssertEqual(h.undoCount, 1, "同一個事件裡的紀錄併成一步")
        var restored: EditHistory.State?
        XCTAssertTrue(h.undo(capture: { $0 }, apply: { restored = $0 }))
        XCTAssertEqual(restored?.drawing?.strokes.count, 1, "回到最早記下的狀態")
        h.record(.init(drawing: nil, pages: [:]))
        XCTAssertFalse(h.canRedo, "做了新的動作就不能再下一步")
    }

    // MARK: 編輯器

    func testEachStrokeIsOneUndoStepAndRedoBringsItBack() {
        drawStroke(y: 200)
        drawStroke(y: 300)
        XCTAssertEqual(strokeCount, 2)
        editor.undoTapped()
        XCTAssertEqual(strokeCount, 1)
        editor.undoTapped()
        XCTAssertEqual(strokeCount, 0)
        editor.redoTapped()
        editor.redoTapped()
        XCTAssertEqual(strokeCount, 2)
    }

    func testOnlyTheLast40StrokesCanBeUndone() {
        for i in 0..<45 { drawStroke(y: 100 + CGFloat(i % 9) * 60) }
        XCTAssertEqual(strokeCount, 45)
        while editor.history.canUndo { editor.undoTapped() }
        XCTAssertEqual(strokeCount, 5, "最多 40 步")
    }

    func testErasingSeveralStrokesInOneGestureIsOneStep() {
        drawStroke(y: 200)
        drawStroke(y: 300)
        drawStroke(y: 400)
        editor.setTool(.eraser)
        // PencilKit 的橡皮擦一次擦掉一筆，每擦一筆通知一次
        editor.canvasViewDidBeginUsingTool(editor.canvas)
        var d = editor.canvas.drawing
        d.strokes.removeLast()
        editor.canvas.drawing = d
        spin(0.05)
        d.strokes.removeLast()
        editor.canvas.drawing = d
        editor.canvasViewDidEndUsingTool(editor.canvas)
        spin(0.2)
        XCTAssertEqual(strokeCount, 1)
        editor.undoTapped()
        XCTAssertEqual(strokeCount, 3, "一次擦除，一次上一步全部回來")
    }

    func testPencilKitsOwnUndoEntriesAreNeverRun() throws {
        drawStroke(y: 200)
        // PencilKit 往畫布的 UndoManager 登記它自己的上一步
        var pencilKitUndoRan = false
        let pk = NSObject()
        editor.canvas.undoManager?.registerUndo(withTarget: pk) { _ in pencilKitUndoRan = true }
        editor.undoTapped()
        XCTAssertEqual(strokeCount, 0)
        XCTAssertFalse(pencilKitUndoRan, "PencilKit 自己的紀錄不執行")
    }

    func testSystemUndoGestureUsesTheSameStack() throws {
        drawStroke(y: 200)
        let um = try XCTUnwrap(editor.canvas.undoManager)
        XCTAssertTrue(um === editor.undoManager, "畫布和編輯畫面用同一個")
        XCTAssertTrue(um.canUndo)
        um.undo()   // 三指往左滑
        XCTAssertEqual(strokeCount, 0)
        XCTAssertFalse(um.canUndo)
        XCTAssertTrue(um.canRedo)
        um.redo()
        XCTAssertEqual(strokeCount, 1)
    }

    func testTypingUndoStaysInsideTheTextBox() throws {
        let ref = try XCTUnwrap(editor.insertElement(.text(TextBoxData(text: "a")), size: CGSize(width: 200, height: 60), at: docPoint(200, 200)))
        editor.beginTextEditing(ref, cell: nil)
        let tv = try XCTUnwrap(editor.editingTextView)
        XCTAssertFalse(tv.undoManager === editor.canvas.undoManager, "打字的上一步是文字框自己的")
        editor.endTextEditing()
    }

    func testElementsAndStrokesUndoInOrder() throws {
        drawStroke(y: 200)
        _ = editor.insertElement(.text(TextBoxData(text: "hello")), size: CGSize(width: 200, height: 60), at: docPoint(200, 400))
        spin()
        let o = editor.contentOrigin(0)
        editor.setTool(.circuit)
        editor.placeComponent(.resistor, at: CGPoint(x: o.x + 300, y: o.y + 600))
        spin()
        XCTAssertEqual(editor.pages[0].elements.count, 2)
        editor.undoTapped()
        XCTAssertEqual(editor.pages[0].elements.count, 1, "先拿掉電路")
        editor.undoTapped()
        XCTAssertEqual(editor.pages[0].elements.count, 0, "再拿掉文字框")
        XCTAssertEqual(strokeCount, 1, "筆跡還在")
        editor.undoTapped()
        XCTAssertEqual(strokeCount, 0)
        editor.redoTapped()
        editor.redoTapped()
        editor.redoTapped()
        XCTAssertEqual(strokeCount, 1)
        XCTAssertEqual(editor.pages[0].elements.count, 2)
    }

    func testStrayStrokeFromANonDrawingToolLeavesNoStep() {
        drawStroke(y: 200)
        editor.setTool(.select)
        // 不該畫出筆跡的工具卻被 PencilKit 畫了一筆 → 刪掉，不留下按了沒反應的一步
        editor.canvasViewDidBeginUsingTool(editor.canvas)
        var d = editor.canvas.drawing
        d.strokes.append(ShapeRecognizer.makeStroke(points: [docPoint(100, 500), docPoint(200, 520)], preset: BrushStore.shared.current))
        editor.canvas.drawing = d
        editor.canvasViewDidEndUsingTool(editor.canvas)
        spin(0.2)
        XCTAssertEqual(strokeCount, 1)
        editor.undoTapped()
        XCTAssertEqual(strokeCount, 0, "上一步直接拿掉前一筆")
    }
}
