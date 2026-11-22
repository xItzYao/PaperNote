import XCTest
import PencilKit
@testable import PaperNote

/// 在真的筆記本裡跑一次「手繪一筆 → 停住 → 放開」，確認頁面上真的留下一條直線
final class HoldToLineFlowTests: XCTestCase {
    /// 這裡測的是 PencilKit 的筆（App 預設用自製筆刷）
    override func invokeTest() { withPencilKitPen { super.invokeTest() } }
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var originalPreset: BrushPreset!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "HoldToLineTest", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        editor = NotebookViewController(session: session, initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        spin(0.3)
        editor.setTool(.pen)
        originalPreset = BrushStore.shared.current
        var p = BrushStore.shared.current
        p.dashed = false
        BrushStore.shared.update(p)
    }

    override func tearDown() {
        BrushStore.shared.update(originalPreset)
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

    /// PencilKit 的筆停住也和自製筆刷一樣認：S 形修成平滑的曲線，筆不放開繼續移動終點跟著走
    func testPencilKitPenHoldMakesACurve() throws {
        let wave = (0...80).map { i -> CGPoint in
            let t = CGFloat(i) / 80
            return docPoint(100 + t * 300, 300 + sin(t * 2 * .pi) * 60 + sin(CGFloat(i) * 1.7) * 2)
        }
        editor.holdToShape.hold(wave)
        let live = try XCTUnwrap(editor.holdToShape.live)
        XCTAssertEqual(live.shape?.kind, .curve)
        XCTAssertEqual(live.points, live.shape?.points, "預覽、放開後留下的都是這條曲線")
        editor.holdToShape.move(docPoint(500, 300))
        let moved = try XCTUnwrap(editor.holdToShape.live?.points.last)
        XCTAssertEqual(moved.x, docPoint(500, 300).x, accuracy: 3, "終點跟著筆尖")
    }

    // MARK: 圖形（回報的問題：PencilKit 筆刷停住變完美圖形會消失）

    /// 圓角、有點抖的手畫矩形（每 3pt 一點），頭尾接起來
    private func roughRectangle(_ r: CGRect) -> [CGPoint] {
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
        var pts: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let n = max(2, Int(a.distance(to: b) / 3))
            for i in 0..<n {
                let t = CGFloat(i) / CGFloat(n)
                pts.append(CGPoint(x: a.x + (b.x - a.x) * t + sin(CGFloat(pts.count)) * 1.5,
                                   y: a.y + (b.y - a.y) * t + cos(CGFloat(pts.count) * 1.3) * 1.5))
            }
        }
        pts.append(CGPoint(x: r.minX + 4, y: r.minY + 2))
        return pts
    }

    private func roughCircle(center c: CGPoint, radius r: CGFloat) -> [CGPoint] {
        (0...120).map { i in
            let a = CGFloat(i) / 120 * 2 * .pi * 1.02
            let rr = r + sin(CGFloat(i) * 0.9) * 2
            return CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
        }
    }

    /// 這一筆畫在頁面上實際有幾個不透明的點
    private func inkedPixels(_ s: PKStroke) -> Int {
        let bounds = s.renderBounds.insetBy(dx: -4, dy: -4)
        guard bounds.width > 0, bounds.height > 0, bounds.width < 4000, bounds.height < 4000,
              let cg = PKDrawing(strokes: [s]).image(from: bounds, scale: 1).cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 3, to: data.count, by: 4).filter { data[$0] > 40 }.count
    }

    /// 換成這種筆型畫一個圖形：手畫 → 停住 → （拖一段）→ 放開，PencilKit 照它自己的時間把手繪那一筆放進筆跡
    private func drawHoldShape(_ hand: [CGPoint], style: InkStyle, dragTo: CGPoint?, pencilKitEndsFirst: Bool,
                               file: StaticString = #filePath, line: UInt = #line) -> (before: Int, after: [PKStroke], live: LiveShape?) {
        var p = BrushStore.shared.current
        p.style = style
        p.dashed = false
        BrushStore.shared.update(p)
        editor.setTool(.pen)
        XCTAssertFalse(editor.customInkActive, "\(style) 是 PencilKit 畫的", file: file, line: line)
        let before = editor.canvas.drawing.strokes.count
        editor.canvasViewDidBeginUsingTool(editor.canvas)
        editor.holdToShape.hold(hand)
        var path = hand
        if let q = dragTo {
            let last = hand.last!
            for i in 1...10 {
                let t = CGFloat(i) / 10
                let m = CGPoint(x: last.x + (q.x - last.x) * t, y: last.y + (q.y - last.y) * t)
                editor.holdToShape.move(m)
                path.append(m)
            }
        }
        let live = editor.holdToShape.live
        var d = editor.canvas.drawing
        d.strokes.append(ShapeRecognizer.makeStroke(points: path, preset: BrushStore.shared.current))
        editor.canvas.drawing = d
        if pencilKitEndsFirst {
            editor.canvasViewDidEndUsingTool(editor.canvas)
            editor.holdToShape.end(path.last!, cancelled: false)
        } else {
            editor.holdToShape.end(path.last!, cancelled: false)
            editor.canvasViewDidEndUsingTool(editor.canvas)
        }
        spin(2.0)
        return (before, editor.canvas.drawing.strokes, live)
    }

    private func assertShapeStays(_ r: (before: Int, after: [PKStroke], live: LiveShape?), _ name: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let live = r.live, let shape = live.shape else { return XCTFail("\(name)：停住要認出圖形", file: file, line: line) }
        XCTAssertEqual(r.after.count, r.before + 1, "\(name)：手繪那一筆換成一個圖形", file: file, line: line)
        guard let last = r.after.last else { return XCTFail("\(name)：圖形不見了", file: file, line: line) }
        let want = InkShapes.bounds(shape.points)
        let got = last.renderBounds
        XCTAssertEqual(got.midX, want.midX, accuracy: 6, "\(name)：留下的是預覽的那個圖形", file: file, line: line)
        XCTAssertEqual(got.midY, want.midY, accuracy: 6, "\(name)：留下的是預覽的那個圖形", file: file, line: line)
        XCTAssertEqual(got.width, want.width, accuracy: 20, "\(name)：大小和預覽一樣", file: file, line: line)
        XCTAssertGreaterThan(inkedPixels(last), Int(want.width + want.height), "\(name)：真的畫得出來", file: file, line: line)
    }

    func testPencilKitShapesStayAfterLifting() {
        let rect = roughRectangle(CGRect(origin: docPoint(80, 120), size: CGSize(width: 220, height: 140)))
        let circle = roughCircle(center: docPoint(250, 450), radius: 80)
        for style in [InkStyle.pen, .pencil, .fountainPen] {
            for first in [false, true] {
                assertShapeStays(drawHoldShape(rect, style: style, dragTo: nil, pencilKitEndsFirst: first), "\(style) 矩形 pkFirst=\(first)")
                assertShapeStays(drawHoldShape(rect, style: style, dragTo: docPoint(60, 90), pencilKitEndsFirst: first), "\(style) 矩形拖大 pkFirst=\(first)")
                assertShapeStays(drawHoldShape(circle, style: style, dragTo: docPoint(150, 340), pencilKitEndsFirst: first), "\(style) 圓拖大 pkFirst=\(first)")
            }
        }
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
