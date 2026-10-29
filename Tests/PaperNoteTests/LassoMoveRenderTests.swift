import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題：套索選的筆跡移動之後，上一個位置留下殘影（放大縮小後才消失，捲動不會）。
/// PencilKit 用每一筆的身分決定要重畫哪裡：同一筆只改位置放回去，舊的位置不會清掉。
/// 模擬器每次都整張重畫，看不到殘影，所以這裡直接檢查移動後放回去的是不是新的筆
final class LassoMoveRenderTests: XCTestCase {
    private final class FakePan: UIPanGestureRecognizer {
        var fake: UIGestureRecognizer.State = .possible
        override var state: UIGestureRecognizer.State {
            get { fake }
            set { fake = newValue }
        }
    }

    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "LassoMoveRender", folder: nil, paper: .blank, landscape: false)
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

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func doc(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    private func drag(_ points: [CGPoint]) {
        let g = FakePan(target: nil, action: nil)
        for (i, p) in points.enumerated() {
            g.fake = i == 0 ? .began : (i == points.count - 1 ? .ended : .changed)
            editor.handleLassoPan(g, p)
            spin()
        }
    }

    /// PencilKit 認的那一筆的身分
    private func identity(_ s: PKStroke) throws -> UUID {
        let o = s as AnyObject
        XCTAssertTrue(o.responds(to: NSSelectorFromString("_strokeUUID")), "讀不到 PKStroke 的身分")
        return try XCTUnwrap(o.value(forKey: "_strokeUUID") as? UUID)
    }

    private func identities() throws -> Set<UUID> {
        Set(try editor.canvas.drawing.strokes.map(identity))
    }

    /// 一行字（幾筆），頁面內容座標 x 100…280、y 290…310
    private func writeLine() {
        let preset = BrushStore.shared.current
        var d = editor.canvas.drawing
        for k in 0..<6 {
            let x0 = 100 + CGFloat(k) * 30
            d.strokes.append(ShapeRecognizer.makeStroke(points: (0...12).map { doc(x0 + CGFloat($0) * 2, 300 + sin(CGFloat($0)) * 10) },
                                                       preset: preset))
        }
        editor.setDrawing(d)
        spin(0.2)
    }

    func testLassoMovePutsBackNewStrokes() throws {
        writeLine()
        editor.setTool(.lasso)
        drag([doc(80, 270), doc(300, 270), doc(300, 330), doc(80, 330), doc(80, 272), doc(81, 271)])
        XCTAssertEqual(editor.lassoSel?.strokeIndices.count, 6, "圈到整行")

        // 回報的情形：連續拖好幾次，每次都在上一個位置留下一份
        for step in 1...2 {
            let before = try identities()
            let y = 300 + CGFloat(step - 1) * 250
            drag([doc(150, y), doc(150, y + 100), doc(150, y + 250)])
            XCTAssertEqual(editor.canvas.drawing.strokes.count, 6, "筆跡的數量不變")
            XCTAssertTrue(try identities().isDisjoint(with: before), "第 \(step) 次移動：放回去的要是新的筆，PencilKit 才會清掉舊的位置")
            let top = editor.canvas.drawing.strokes.map(\.renderBounds.minY).min() ?? 0
            XCTAssertEqual(top, doc(0, 290 + CGFloat(step) * 250).y, accuracy: 15, "移到拖到的位置")
        }
    }

    func testDuplicatedStrokesAreNewStrokes() throws {
        writeLine()
        editor.setTool(.lasso)
        drag([doc(80, 270), doc(300, 270), doc(300, 330), doc(80, 330), doc(80, 272), doc(81, 271)])
        let originals = try identities()
        let sel = try XCTUnwrap(editor.lassoSel)
        let clip = LassoClipboard(strokes: sel.strokeIndices.map { editor.canvas.drawing.strokes[$0] }, elements: [], highlights: [],
                                  bounds: sel.bounds, changeCount: 0)
        editor.pasteLasso(clip, center: doc(190, 600))
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 12)
        XCTAssertEqual(try identities().subtracting(originals).count, 6, "貼上的每一筆都是新的筆")
    }

    func testStrokesMovedWithAnElementAreNewStrokes() throws {
        writeLine()
        let before = try identities()
        editor.moveStrokes(inside: CGRect(origin: doc(80, 270), size: CGSize(width: 230, height: 60)), by: CGPoint(x: 0, y: 200))
        XCTAssertTrue(try identities().isDisjoint(with: before), "跟著物件移動的筆跡也要是新的筆")
    }

    /// 新的筆畫出來要和原本的一樣：墨水、路徑、筆觸紋理不變，只換位置
    func testMovedStrokeKeepsItsLook() {
        let s = ShapeRecognizer.makeStroke(points: (0...12).map { CGPoint(x: CGFloat($0) * 5, y: sin(CGFloat($0)) * 10) },
                                          preset: BrushStore.shared.current)
        let m = s.moved(by: CGAffineTransform(translationX: 30, y: 40))
        XCTAssertEqual(m.randomSeed, s.randomSeed)
        XCTAssertEqual(m.ink.color, s.ink.color)
        XCTAssertEqual(m.ink.inkType, s.ink.inkType)
        XCTAssertEqual(m.path.count, s.path.count)
        XCTAssertEqual(m.renderBounds.minX, s.renderBounds.minX + 30, accuracy: 0.01)
        XCTAssertEqual(m.renderBounds.minY, s.renderBounds.minY + 40, accuracy: 0.01)
    }
}
