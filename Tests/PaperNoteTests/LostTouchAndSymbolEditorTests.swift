import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題：螢光筆畫不出來。除錯紀錄：工具列的選單開著時下筆，PencilKit 開始寫了，
/// 這一筆的「結束」卻沒送到追蹤筆尖的辨識器；之後每一筆 Pencil 都被當成「上一筆還沒放開」而忽略，
/// 卡住的 PencilKit 書寫手勢也就一直沒有重設（自製筆刷有自己的辨識器，還寫得出來）
final class LostPencilTouchTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "LostPencilTouch", folder: nil, paper: .blank, landscape: false)
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

    func testAPencilTouchWhoseEndNeverArrivedDoesNotBlockTheNextStroke() throws {
        editor.setTool(.highlighter)
        let tracker = try XCTUnwrap(editor.pencilPointTracker)
        let lost = FakeTouch(type: .pencil, location: CGPoint(x: 200, y: 300))
        tracker.touchesBegan([lost], with: UIEvent())
        XCTAssertTrue(editor.pencilDown)
        // 選單開著時下筆：PencilKit 開始寫了（之後沒收到結束），筆放開了但辨識器沒收到
        editor.pkUsingSince = CACurrentMediaTime() - 5
        lost.fakePhase = .ended

        editor.pencilDown = false
        let next = FakeTouch(type: .pencil, location: CGPoint(x: 220, y: 320))
        tracker.touchesBegan([next], with: UIEvent())
        XCTAssertTrue(editor.pencilDown, "下一筆要收到")
        XCTAssertNil(editor.pkUsingSince, "卡在書寫中的 PencilKit 手勢重設了，螢光筆才畫得出來")
        XCTAssertTrue(editor.canvas.drawingGestureRecognizer.isEnabled)
    }

    func testAStrokeStillInProgressKeepsItsTouch() throws {
        let tracker = try XCTUnwrap(editor.pencilPointTracker)
        var began = 0
        let saved = tracker.onBegan
        defer { tracker.onBegan = saved }
        tracker.onBegan = { _ in began += 1 }
        let first = FakeTouch(type: .pencil)
        tracker.touchesBegan([first], with: UIEvent())
        first.fakePhase = .moved
        tracker.touchesBegan([FakeTouch(type: .pencil)], with: UIEvent())
        XCTAssertEqual(began, 1, "還沒放開的那一筆不會被換掉")
        tracker.touchesEnded([first], with: UIEvent())
    }
}

/// 回報的問題：畫元件的筆刷有點延遲（拖曳手勢要先移動一小段才開始）；橡皮擦想要局部擦除
final class SymbolEditorStrokeTests: XCTestCase {
    private var savedPartial = false

    override func setUp() {
        savedPartial = EditorSettings.shared.symbolPartialErase
    }

    override func tearDown() {
        EditorSettings.shared.symbolPartialErase = savedPartial
        super.tearDown()
    }

    private func editorVC() -> CircuitSymbolEditorViewController {
        let vc = CircuitSymbolEditorViewController(name: "", symbol: nil) { _, _ in }
        vc.loadViewIfNeeded()
        vc.canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        vc.canvas.layoutIfNeeded()
        return vc
    }

    /// 畫面座標（canvas）對到的元件座標
    private func view(_ vc: CircuitSymbolEditorViewController, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: vc.canvas.bounds.midX + x * vc.canvas.scale, y: vc.canvas.bounds.midY + y * vc.canvas.scale)
    }

    func testTheBrushStartsDrawingOnTouchDown() {
        let vc = editorVC()
        vc.setTool(.brush)
        XCTAssertTrue(vc.strokeTouch.isEnabled)
        XCTAssertFalse(vc.panGesture.isEnabled, "筆刷不用拖曳手勢（要先移動一小段才開始）")
        let t = FakeTouch(type: .pencil, location: view(vc, 10, 20))
        vc.strokeTouch.touchesBegan([t], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.count, 1, "一碰到就開始畫")
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.count, 1)
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.first?.x ?? .nan, 10, accuracy: 0.01)
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.first?.y ?? .nan, 20, accuracy: 0.01)
        t.point = view(vc, 30, 20)
        vc.strokeTouch.touchesMoved([t], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.count, 2)
        XCTAssertFalse(vc.canvas.strokeLayer.path?.isEmpty ?? true, "畫的時候線條圖層跟著更新")
        t.fakePhase = .ended
        vc.strokeTouch.touchesEnded([t], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.first?.points.last?.x ?? .nan, 30, accuracy: 0.01)

        vc.setTool(.line)
        XCTAssertFalse(vc.strokeTouch.isEnabled)
        XCTAssertTrue(vc.panGesture.isEnabled, "線條照舊用拖曳（兩端吸到格點）")
    }

    func testPartialEraseCutsOnlyThePartItTouches() {
        var d = CircuitSymbolDraft()
        d.beginLine(at: CGPoint(x: -40, y: 0))
        d.endLine(at: CGPoint(x: 40, y: 0))
        d.beginErase()
        XCTAssertTrue(d.erase(at: .zero, tolerance: 5, partial: true))
        XCTAssertTrue(d.erase(at: CGPoint(x: 20, y: 0), tolerance: 5, partial: true))
        XCTAssertFalse(d.erase(at: CGPoint(x: 0, y: 20), tolerance: 5, partial: true), "沒碰到不算")
        d.endErase()
        let xs = d.symbol.strokes.map { $0.points.map(\.x) }
        XCTAssertEqual(xs.count, 3, "擦掉兩段，剩三條")
        let expected: [[CGFloat]] = [[-40, -5], [5, 15], [25, 40]]
        for (got, want) in zip(xs, expected) {
            XCTAssertEqual(got.first ?? .nan, want[0], accuracy: 0.01)
            XCTAssertEqual(got.last ?? .nan, want[1], accuracy: 0.01)
        }
        d.undo()
        XCTAssertEqual(d.symbol.strokes.map(\.points), [[CGPoint(x: -40, y: 0), CGPoint(x: 40, y: 0)]], "一路擦算一步")

        var f = CircuitSymbolDraft()
        f.beginBrush(at: CGPoint(x: 0, y: 0))
        for i in 1...10 { f.continueBrush(to: CGPoint(x: CGFloat(i) * 5, y: CGFloat(i % 2) * 3)) }
        f.endBrush()
        XCTAssertTrue(f.erase(at: CGPoint(x: 25, y: 1.5), tolerance: 4, partial: true))
        XCTAssertEqual(f.symbol.strokes.count, 2)
        XCTAssertTrue(f.symbol.strokes.allSatisfy(\.freehand), "筆刷畫的切開還是筆刷線")
        XCTAssertTrue(f.erase(at: CGPoint(x: 0, y: 0), tolerance: 100, partial: true))
        XCTAssertTrue(f.symbol.strokes.isEmpty, "整條都在圓裡就整條擦掉")
    }

    func testErasingInTheEditorIsOneStepPerTouch() {
        let vc = editorVC()
        vc.setTool(.line)
        vc.handlePan(.began, at: CGPoint(x: -40, y: 0))
        vc.handlePan(.ended, at: CGPoint(x: 40, y: 0))
        vc.handlePan(.began, at: CGPoint(x: -40, y: 20))
        vc.handlePan(.ended, at: CGPoint(x: 40, y: 20))
        XCTAssertEqual(vc.draft.symbol.strokes.count, 2)

        vc.setTool(.eraser)
        XCTAssertFalse(vc.eraseKind.isHidden, "橡皮擦可以選整條或局部")
        XCTAssertTrue(vc.strokeTouch.isEnabled, "橡皮擦也是一碰到就擦")
        EditorSettings.shared.symbolPartialErase = true
        let t = FakeTouch(type: .pencil, location: view(vc, 0, -5))
        vc.strokeTouch.touchesBegan([t], with: UIEvent())
        for y in stride(from: 0, through: 25, by: 5) {
            t.point = view(vc, 0, CGFloat(y))
            vc.strokeTouch.touchesMoved([t], with: UIEvent())
        }
        t.fakePhase = .ended
        vc.strokeTouch.touchesEnded([t], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.count, 4, "兩條線都從中間切開")
        vc.undoTapped()
        XCTAssertEqual(vc.draft.symbol.strokes.count, 2, "劃過一次算一步")

        EditorSettings.shared.symbolPartialErase = false
        let tap = FakeTouch(type: .pencil, location: view(vc, 0, 0))
        vc.strokeTouch.touchesBegan([tap], with: UIEvent())
        tap.fakePhase = .ended
        vc.strokeTouch.touchesEnded([tap], with: UIEvent())
        XCTAssertEqual(vc.draft.symbol.strokes.count, 1, "整條擦除：點一下擦掉一整條")
    }
}
