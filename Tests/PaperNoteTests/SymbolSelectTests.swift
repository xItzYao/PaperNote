import XCTest
@testable import PaperNote

/// 回報的需求：電路圖自訂元件加入選取工具；選到的字要有藍框，還可以調整大小
final class SymbolSelectTests: XCTestCase {
    private func editorVC(_ symbol: CircuitSymbol) -> CircuitSymbolEditorViewController {
        let vc = CircuitSymbolEditorViewController(name: "", symbol: symbol) { _, _ in }
        vc.loadViewIfNeeded()
        vc.canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        vc.canvas.layoutIfNeeded()
        return vc
    }

    private var sample: CircuitSymbol {
        CircuitSymbol(strokes: [.init(points: [CGPoint(x: -30, y: 0), CGPoint(x: 30, y: 0)]),
                                .init(points: (0...20).map { CGPoint(x: CGFloat($0) * 2 - 20, y: 20 + sin(CGFloat($0)) * 2) }, freehand: true)],
                      texts: [.init(text: "A", center: CGPoint(x: 0, y: -20), size: 12)],
                      pins: [CGPoint(x: -30, y: 0)])
    }

    func testPickingTextAndStrokes() {
        let d = CircuitSymbolDraft(sample)
        XCTAssertEqual(d.item(at: CGPoint(x: 0, y: -20), tolerance: 4), .text(0), "點到字")
        XCTAssertEqual(d.item(at: CGPoint(x: 10, y: 1), tolerance: 4), .stroke(0), "點到直線")
        XCTAssertEqual(d.item(at: CGPoint(x: 0, y: 20), tolerance: 4), .stroke(1), "點到筆刷線")
        XCTAssertNil(d.item(at: CGPoint(x: 0, y: 50), tolerance: 4), "空白的地方")
    }

    func testMovingAndResizing() {
        var d = CircuitSymbolDraft(sample)
        var original = d.beginTransform()
        d.move(.text(0), in: original, by: CGPoint(x: 7, y: 3))
        d.move(.text(0), in: original, by: CGPoint(x: 9, y: 4))
        XCTAssertEqual(d.symbol.texts[0].center, CGPoint(x: 9, y: -16), "從拖之前的位置算，不會越拖越遠")
        d.endTransform(from: original)

        original = d.beginTransform()
        d.move(.stroke(0), in: original, by: CGPoint(x: 13, y: 4))
        XCTAssertEqual(d.symbol.strokes[0].points, [CGPoint(x: -20, y: 0), CGPoint(x: 20, y: 0)], "直線照格點移動")
        d.move(.stroke(1), in: original, by: CGPoint(x: 1.5, y: 0))
        XCTAssertEqual(d.symbol.strokes[1].points.first?.x ?? .nan, -18.5, accuracy: 0.001, "筆刷線照拖的移動")
        d.endTransform(from: original)

        original = d.beginTransform()
        d.resizeText(0, to: 100)
        XCTAssertEqual(d.symbol.texts[0].size, CircuitSymbol.Label.sizeRange.upperBound, "字有最大的大小")
        d.endTransform(from: original)

        d.undo()
        XCTAssertEqual(d.symbol.texts[0].size, 12, "縮放算一步")
        d.undo()
        XCTAssertEqual(d.symbol.strokes[0].points, sample.strokes[0].points, "移動算一步")

        // 沒有改到就不算一步
        let steps = d
        original = d.beginTransform()
        d.endTransform(from: original)
        d.undo()
        XCTAssertNotEqual(d.symbol, steps.symbol, "復原的是上一個移動，不是沒動的那一次")
    }

    func testTheEditorShowsABlueBoxAndATextHandle() throws {
        let vc = editorVC(sample)
        XCTAssertEqual(CircuitSymbolTool.allCases.first, .select, "工具最左邊是選取")
        vc.setTool(.select)
        XCTAssertTrue(vc.tapGesture.isEnabled)
        XCTAssertTrue(vc.panGesture.isEnabled)
        XCTAssertFalse(vc.strokeTouch.isEnabled)

        vc.handleTap(at: CGPoint(x: 0, y: -20))
        XCTAssertEqual(vc.selection, .text(0))
        XCTAssertNotNil(vc.canvas.selectionLayer.path, "選到的字有藍框")
        XCTAssertEqual(vc.canvas.selectionLayer.strokeColor, UIColor.systemBlue.cgColor)
        XCTAssertFalse(vc.canvas.selectionHandle.isHidden, "字有縮放把手")
        let box = try XCTUnwrap(vc.canvas.selectionLayer.path?.boundingBox)
        let label = vc.draft.symbol.texts[0].bounds
        let a = vc.canvas.viewPoint(CGPoint(x: label.minX, y: label.minY))
        XCTAssertTrue(box.contains(a), "藍框圍住字")

        // 拉右下角的把手：字變大
        let handle = try XCTUnwrap(vc.canvas.handlePoint)
        let start = vc.canvas.symbolPoint(handle)
        let center = vc.draft.symbol.texts[0].center
        let far = CGPoint(x: center.x + (start.x - center.x) * 1.5, y: center.y + (start.y - center.y) * 1.5)
        vc.handlePan(.began, at: start)
        vc.handlePan(.changed, at: far)
        vc.handlePan(.ended, at: far)
        XCTAssertEqual(vc.draft.symbol.texts[0].size, 18, accuracy: 0.01, "字跟著把手放大")
        XCTAssertEqual(vc.draft.symbol.texts[0].center, center, "字的中心不動")

        // 按在字上拖：移動
        vc.handlePan(.began, at: center)
        vc.handlePan(.ended, at: CGPoint(x: center.x + 5, y: center.y))
        XCTAssertEqual(vc.draft.symbol.texts[0].center.x, center.x + 5, accuracy: 0.01)

        // 線條：有藍框、沒有縮放把手
        vc.handleTap(at: CGPoint(x: 10, y: 0))
        XCTAssertEqual(vc.selection, .stroke(0))
        XCTAssertNotNil(vc.canvas.selectionLayer.path)
        XCTAssertTrue(vc.canvas.selectionHandle.isHidden)

        vc.handleTap(at: CGPoint(x: 0, y: 60))
        XCTAssertNil(vc.selection, "點空白取消選取")
        XCTAssertNil(vc.canvas.selectionLayer.path)

        vc.handleTap(at: CGPoint(x: 10, y: 0))
        vc.setTool(.line)
        XCTAssertNil(vc.selection, "換工具就不選")
        XCTAssertNil(vc.canvas.selectionLayer.path)
    }
}
