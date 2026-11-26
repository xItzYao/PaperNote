import XCTest
import PencilKit
@testable import PaperNote

/// 回報的問題（11/26）：套索的虛線被筆跡蓋住。套索、選取框、橡皮擦的圓圈都畫在 overlay 上，要在所有筆跡上面
final class OverlayOnTopTests: XCTestCase {
    /// 畫面由下往上畫的順序（先畫的在下面）
    private func drawingOrder(_ v: UIView) -> [UIView] {
        [v] + v.subviews.flatMap(drawingOrder)
    }

    func testTheOverlayIsDrawnAboveAllInk() throws {
        let meta = LibraryStore.shared.createNotebook(title: "OverlayOnTop", folder: nil, paper: .blank, landscape: false)
        defer { LibraryStore.shared.deleteNotebook(meta.id) }
        let session = try NotebookSession(id: meta.id)
        session.document.pages[0].ink = [InkStroke(colorHex: "#000000FF", points: (0..<20).map {
            InkPoint(CGPoint(x: 100 + CGFloat($0) * 10, y: 200), width: 6)
        })]
        session.save()
        let editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        let window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.view.layoutIfNeeded()
        let o = editor.contentOrigin(0)
        let pen = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: (0..<10).map {
            PKStrokePoint(location: CGPoint(x: o.x + 100, y: o.y + 150 + CGFloat($0) * 10), timeOffset: Double($0) * 0.01,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date()))
        editor.setDrawing(PKDrawing(strokes: [pen]))
        // 放大、捲動之後也一樣（縮放時會把 PencilKit 之後加的 view 重新排）
        editor.canvas.setZoomScale(editor.canvas.zoomScale * 1.5, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let order = drawingOrder(editor.canvas)
        let overlayAt = try XCTUnwrap(order.firstIndex(of: editor.overlay))
        let inside = Set(drawingOrder(editor.overlay).map(ObjectIdentifier.init))
        // 系統的捲動軸不算（本來就在最上面）
        let below = order.enumerated().filter {
            $0.offset > overlayAt && !inside.contains(ObjectIdentifier($0.element))
                && !String(describing: type(of: $0.element)).contains("ScrollIndicator")
        }
        XCTAssertEqual(below.map { String(describing: type(of: $0.element)) }, [],
                       "overlay 之後（上面）不能再有別的 view：PencilKit 的筆跡、自製筆刷的字都要在它底下")
        let inkViews = editor.inkContainer.subviews.filter { $0 !== editor.overlay }
        XCTAssertFalse(inkViews.isEmpty, "測試的前提：有自製筆刷的字")
    }
}
