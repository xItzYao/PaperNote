import XCTest
import PencilKit
@testable import PaperNote

/// 除錯量測本身要可靠：PencilKit 的筆跡在哪裡就量得到，空白的地方量不到
final class RedrawProbeTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "RedrawProbe", folder: nil, paper: .blank, landscape: false)
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

    func testProbeSeesPencilKitStrokesOnlyWhereTheyAre() {
        let o = editor.contentOrigin(0)
        let pts = (0...40).map { CGPoint(x: o.x + 100 + CGFloat($0) * 5, y: o.y + 300 + sin(CGFloat($0) / 3) * 10) }
        var d = editor.canvas.drawing
        d.strokes.append(ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current))
        editor.setDrawing(d)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let on = editor.pencilKitInkOnScreen(CGRect(x: o.x + 90, y: o.y + 280, width: 230, height: 40))
        let off = editor.pencilKitInkOnScreen(CGRect(x: o.x + 90, y: o.y + 600, width: 230, height: 40))
        print("PROBE on=\(on) off=\(off)")
        XCTAssertGreaterThan(on, 50, "筆跡的位置量得到墨水")
        XCTAssertEqual(off, 0, "空白的地方量不到")
    }
}
