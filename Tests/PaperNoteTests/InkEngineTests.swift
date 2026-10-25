import XCTest
import PencilKit
@testable import PaperNote

/// 自製筆刷：存檔格式、畫得出來、橡皮擦、套索判斷
final class InkEngineTests: XCTestCase {
    private func stroke(_ pts: [(CGFloat, CGFloat)], width: CGFloat = 2, color: String = "#000000FF") -> InkStroke {
        InkStroke(colorHex: color, points: pts.map { InkPoint(CGPoint(x: $0.0, y: $0.1), width: width) })
    }

    /// (x, y) 像素的 alpha（0...255）
    private func alpha(_ img: UIImage, _ x: Int, _ y: Int) -> UInt8 {
        guard let cg = img.cgImage else { return 0 }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        return px[3]
    }

    private func render(_ strokes: [InkStroke], size: CGSize = CGSize(width: 100, height: 100)) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { rc in InkRenderer.draw(strokes, in: rc.cgContext) }
    }

    func testRendersAlongThePointsAndNothingElse() {
        let img = render([stroke([(10, 50), (90, 50)], width: 4)])
        XCTAssertGreaterThan(alpha(img, 50, 50), 200, "線上要有墨水")
        XCTAssertEqual(alpha(img, 50, 20), 0, "線外不能有墨水")
    }

    func testSinglePointDrawsADot() {
        let img = render([stroke([(50, 50)], width: 6)])
        XCTAssertGreaterThan(alpha(img, 50, 50), 200)
    }

    func testThinLineIsStillVisible() {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: fmt).image { rc in
            InkRenderer.draw([self.stroke([(10, 50.25), (90, 50.25)], width: 0.5)], in: rc.cgContext)
        }
        XCTAssertGreaterThan(alpha(img, 100, 100), 0, "0.5pt 的線也要看得到")
    }

    func testHiddenStrokesAreSkipped() {
        let s = stroke([(10, 50), (90, 50)], width: 4)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        let img = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: fmt).image { rc in
            InkRenderer.draw([s], in: rc.cgContext, hidden: [s.id])
        }
        XCTAssertEqual(alpha(img, 50, 50), 0)
    }

    func testKeepsEveryPointExactly() {
        // 不做圓滑：存進去什麼點，就畫什麼點
        let zigzag = stroke([(0, 0), (10, 10), (20, 0), (30, 10)])
        let data = try! JSONEncoder.app.encode(zigzag)
        let back = try! JSONDecoder.app.decode(InkStroke.self, from: data)
        XCTAssertEqual(back, zigzag)
        XCTAssertEqual(back.points.map(\.point), [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 10)])
    }

    func testPageRoundTripsInkAndOldFilesStillOpen() throws {
        var page = Page(background: .paper(width: 595, height: 842, style: .blank))
        page.ink = [stroke([(1, 2), (3, 4)])]
        let data = try JSONEncoder.app.encode(page)
        XCTAssertEqual(try JSONDecoder.app.decode(Page.self, from: data), page)

        // 舊版存檔沒有 ink 欄位
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "ink")
        let old = try JSONDecoder.app.decode(Page.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.ink.isEmpty)
        XCTAssertEqual(old.id, page.id)
    }

    func testHitTestUsesLineWidth() {
        let s = stroke([(0, 0), (100, 0)], width: 10)
        XCTAssertTrue(InkGeometry.hits(s, at: CGPoint(x: 50, y: 7), radius: 3))
        XCTAssertFalse(InkGeometry.hits(s, at: CGPoint(x: 50, y: 12), radius: 3))
        XCTAssertFalse(InkGeometry.hits(s, at: CGPoint(x: 120, y: 0), radius: 3))
    }

    func testStrokeEraserRemovesWholeStroke() {
        let a = stroke([(0, 0), (100, 0)]), b = stroke([(0, 50), (100, 50)])
        let out = InkGeometry.erase([a, b], at: CGPoint(x: 50, y: 0), radius: 4, partial: false)
        XCTAssertEqual(out, [b])
        XCTAssertNil(InkGeometry.erase([a, b], at: CGPoint(x: 50, y: 25), radius: 4, partial: false), "沒擦到不算變化")
    }

    func testPixelEraserSplitsStroke() {
        let line = stroke((0...20).map { (CGFloat($0) * 5, 0) })
        let out = InkGeometry.erase([line], at: CGPoint(x: 50, y: 0), radius: 6, partial: true)!
        XCTAssertEqual(out.count, 2, "從中間擦斷變成兩段")
        XCTAssertTrue(out.allSatisfy { $0.colorHex == line.colorHex })
        XCTAssertTrue(out[0].points.allSatisfy { $0.point.x < 45 })
        XCTAssertTrue(out[1].points.allSatisfy { $0.point.x > 55 })
    }

    func testLassoCirclesStrokeWhenAnyPointIsInside() {
        let s = stroke([(0, 0), (200, 0)])
        let path = UIBezierPath(rect: CGRect(x: 180, y: -10, width: 40, height: 20))
        XCTAssertTrue(InkGeometry.circled(s, offset: .zero, path: path))
        XCTAssertFalse(InkGeometry.circled(s, offset: CGPoint(x: 0, y: 100), path: path))
    }

    func testOffsetMovesEveryPoint() {
        let s = stroke([(0, 0), (10, 5)])
        let moved = InkGeometry.offset(s, by: CGPoint(x: 3, y: -2))
        XCTAssertEqual(moved.id, s.id)
        XCTAssertEqual(moved.points.map(\.point), [CGPoint(x: 3, y: -2), CGPoint(x: 13, y: 3)])
    }
}

/// 在真的筆記本裡用自製筆刷寫一筆：存進頁面、PencilKit 不受影響、可以復原、可以擦掉
final class InkEngineFlowTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var customInkBefore = false

    override func setUpWithError() throws {
        customInkBefore = EditorSettings.shared.customInk
        EditorSettings.shared.customInk = true
        let meta = LibraryStore.shared.createNotebook(title: "InkEngineTest", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        editor = NotebookViewController(session: session, initialPageID: nil, onClose: {})
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        editor.setTool(.pen)
    }

    override func tearDown() {
        EditorSettings.shared.customInk = customInkBefore
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func docPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    private func write(from a: CGPoint, to b: CGPoint) {
        editor.inkBegan(.init(point: a, force: 0.5))
        let samples = (1...20).map { i -> InkCaptureRecognizer.Sample in
            let t = CGFloat(i) / 20
            return .init(point: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), force: 0.5)
        }
        editor.inkMoved(samples, predicted: [])
        editor.inkEnded(cancelled: false)
        spin()
    }

    /// 讓 run loop 跑一下：真的使用時每一筆都是分開的觸控事件，上一步也分開登記
    private func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testPencilKitIsOffAndInkRecognizerOn() {
        XCTAssertTrue(editor.customInkActive)
        XCTAssertFalse(editor.canvas.drawingGestureRecognizer.isEnabled, "自製筆刷時 PencilKit 不能同時寫")
        XCTAssertTrue(editor.inkRecognizer.isEnabled)
        editor.setTool(.highlighter)
        XCTAssertTrue(editor.canvas.drawingGestureRecognizer.isEnabled, "螢光筆照樣用 PencilKit")
        XCTAssertFalse(editor.inkRecognizer.isEnabled)
    }

    func testStrokeIsSavedInPageContentCoordinates() {
        let pkBefore = editor.canvas.drawing.strokes.count
        write(from: docPoint(100, 200), to: docPoint(300, 200))
        XCTAssertEqual(editor.pages[0].ink.count, 1)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, pkBefore, "PencilKit 的筆跡不能多")
        let s = editor.pages[0].ink[0]
        XCTAssertEqual(s.points.first!.point.x, 100, accuracy: 0.01)
        XCTAssertEqual(s.points.last!.point.x, 300, accuracy: 0.01)
        XCTAssertEqual(s.points.count, 21, "每個取樣點都要留著")
    }

    func testUndoRemovesStroke() {
        write(from: docPoint(100, 200), to: docPoint(300, 200))
        XCTAssertEqual(editor.pages[0].ink.count, 1)
        editor.undoTapped()
        XCTAssertTrue(editor.pages[0].ink.isEmpty)
        spin()
        editor.redoTapped()
        XCTAssertEqual(editor.pages[0].ink.count, 1)
    }

    func testEraserRemovesStrokeWithOneUndo() {
        write(from: docPoint(100, 200), to: docPoint(300, 200))
        write(from: docPoint(100, 300), to: docPoint(300, 300))
        let pixelBefore = EditorSettings.shared.pixelEraser
        EditorSettings.shared.pixelEraser = false
        defer { EditorSettings.shared.pixelEraser = pixelBefore }
        editor.setTool(.eraser)
        editor.inkEraseUndoRegistered = []
        editor.eraseInk(at: docPoint(150, 200))
        spin()
        editor.eraseInk(at: docPoint(150, 300))
        XCTAssertTrue(editor.pages[0].ink.isEmpty)
        spin()
        editor.undoTapped()
        XCTAssertEqual(editor.pages[0].ink.count, 2, "一次擦除一次復原")
    }

    func testFullPageRenderIncludesInk() {
        write(from: docPoint(100, 200), to: docPoint(300, 200))
        let page = editor.pages[0]
        let size = editor.session.fullSize(of: page)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { rc in
            PageRenderer.drawFullPage(page, session: self.editor.session, in: rc.cgContext, inkScale: 1)
        }
        guard let cg = img.cgImage else { return XCTFail() }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = Int(page.insets.left + 200), y = Int(page.insets.top + 200)
        ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
        XCTAssertLessThan(Int(min(px[0], px[1], px[2])), 200, "匯出／縮圖要畫出筆跡（白紙上應該不是白色）")
    }
}
