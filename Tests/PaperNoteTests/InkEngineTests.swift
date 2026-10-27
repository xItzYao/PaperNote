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

    /// 每寫一筆整頁的筆跡路徑都會重建：一整頁密密麻麻的字也要夠快
    private func waitUntilBuilt(_ v: PageInkView) {
        let deadline = Date().addingTimeInterval(3)
        while v.isBuilding && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// 頁面上 (x, y)（點）的墨水
    private func inkAlpha(_ v: PageInkView, _ x: CGFloat, _ y: CGFloat) -> UInt8 {
        guard let contents = v.layer.contents else { return 0 }
        let cg = contents as! CGImage
        return alpha(UIImage(cgImage: cg), Int(x * v.renderScale), Int(y * v.renderScale))
    }

    private func fullPage() -> [InkStroke] {
        var strokes: [InkStroke] = []
        for i in 0..<1500 {
            let left = CGFloat(i % 30) * 20, top = CGFloat(i / 30) * 16
            var pts: [(CGFloat, CGFloat)] = []
            for k in 0..<40 {
                let t = CGFloat(k)
                pts.append((left + t * 0.5, top + sin(t / 3) * 4))
            }
            strokes.append(stroke(pts))
        }
        return strokes
    }

    /// 回報的問題：筆跡很多的頁面快速捲動會掉幀（每頁幾十層向量，捲動時一直重畫）。
    /// 整頁畫成一張圖、在背景畫，不佔主執行緒
    func testFullPageBecomesOneImageDrawnInTheBackground() {
        let v = PageInkView(frame: CGRect(x: 0, y: 0, width: 600, height: 850))
        let page = fullPage()
        let t = CACurrentMediaTime()
        v.set(strokes: page, offset: .zero)
        XCTAssertLessThan(CACurrentMediaTime() - t, 0.02, "整頁的筆跡要在背景畫")
        XCTAssertTrue(v.isBuilding)
        waitUntilBuilt(v)
        print("INKDIAG full page bitmap \(Int((CACurrentMediaTime() - t) * 1000))ms")
        XCTAssertLessThan(CACurrentMediaTime() - t, 1.5)
        XCTAssertTrue(v.showsBitmap, "整頁是一張圖")
        XCTAssertEqual(v.layer.sublayers?.count ?? 0, 0, "不能是一堆向量層")
        XCTAssertGreaterThan(inkAlpha(v, 20, 16), 0, "筆跡要畫在圖上")
    }

    /// 回報的問題：筆跡很多的頁面寫字會卡一下，剛寫的那筆才突然跳出來。寫一筆不能整頁重畫，而且馬上看得到
    func testAddingAStrokeDrawsItRightAwayWithoutRedrawingThePage() {
        let v = PageInkView(frame: CGRect(x: 0, y: 0, width: 600, height: 850))
        let many = fullPage()
        v.set(strokes: many, offset: .zero)
        waitUntilBuilt(v)
        let renders = v.fullRenders
        XCTAssertEqual(inkAlpha(v, 30, 830), 0)
        v.set(strokes: many + [stroke([(5, 830), (60, 830)], width: 3)], offset: .zero)
        XCTAssertFalse(v.isBuilding)
        XCTAssertEqual(v.fullRenders, renders, "寫一筆不能整頁重畫")
        XCTAssertGreaterThan(inkAlpha(v, 30, 830), 200, "新的那筆要馬上畫上去")
    }

    /// 擦掉一筆：只清掉那一塊，旁邊的筆跡還在
    func testRemovingAStrokeOnlyClearsItsArea() {
        let v = PageInkView(frame: CGRect(x: 0, y: 0, width: 600, height: 850))
        let a = stroke([(100, 100), (200, 100)], width: 4), b = stroke([(100, 110), (200, 110)], width: 4)
        v.set(strokes: [a, b], offset: .zero)
        waitUntilBuilt(v)
        let renders = v.fullRenders
        v.set(strokes: [b], offset: .zero)
        XCTAssertEqual(v.fullRenders, renders, "擦一筆不能整頁重畫")
        XCTAssertEqual(inkAlpha(v, 150, 100), 0, "擦掉的那筆要不見")
        XCTAssertGreaterThan(inkAlpha(v, 150, 110), 200, "旁邊那筆要留著")
        v.setHidden([b.id])
        XCTAssertEqual(inkAlpha(v, 150, 110), 0, "套索移動中藏起來的筆跡不畫")
    }

    /// 放大很多時點陣圖會太大：改用向量，放大也清楚
    func testZoomedFarInUsesVector() {
        let v = PageInkView(frame: CGRect(x: 0, y: 0, width: 600, height: 850))
        v.set(strokes: fullPage(), offset: .zero)
        v.setRenderScale(12, immediately: true)
        waitUntilBuilt(v)
        XCTAssertFalse(v.showsBitmap)
        XCTAssertGreaterThan(v.layer.sublayers?.count ?? 0, 0)
        XCTAssertLessThanOrEqual(v.layer.sublayers?.count ?? 0, 1500 / PageInkView.strokesPerLayer + 1, "連續寫的筆跡合成幾塊，不是一筆一層")
        v.setRenderScale(2, immediately: true)
        waitUntilBuilt(v)
        XCTAssertTrue(v.showsBitmap, "縮回來要換回點陣圖")
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

    func testPixelEraserCutsExactlyAtTheCircleEvenWithSparsePoints() {
        // 寫得快時取樣點很稀：只擦掉圓圈裡那一段，不能連整段線一起不見
        let line = stroke([(0, 0), (100, 0)], width: 1)
        let out = InkGeometry.erase([line], at: CGPoint(x: 50, y: 0), radius: 5, partial: true)!
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].points.first!.point.x, 0, accuracy: 0.01)
        XCTAssertEqual(out[0].points.last!.point.x, 45, accuracy: 0.01)
        XCTAssertEqual(out[1].points.first!.point.x, 55, accuracy: 0.01)
        XCTAssertEqual(out[1].points.last!.point.x, 100, accuracy: 0.01)
        XCTAssertNil(InkGeometry.erase([line], at: CGPoint(x: 50, y: 8), radius: 5, partial: true), "圓圈沒碰到線就不變")
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
    /// 回報的問題：細線寫的時候比較粗，放開後才變回原本的細度（寫的時候和頁面上畫法不同）
    func testLiveStrokeLooksLikeTheCommittedStroke() {
        let pts = (0...150).map { CGPoint(x: 10 + CGFloat($0), y: 50 + sin(CGFloat($0) / 9) * 20) }
        let width: CGFloat = 0.6
        let live = LiveInkView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        live.begin(pts[0], width: width, color: .black)
        live.add(pts.dropFirst().map { ($0, width) })
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        fmt.opaque = false
        let liveImg = UIGraphicsImageRenderer(size: live.bounds.size, format: fmt).image { _ in live.draw(live.bounds) }
        let pageImg = UIGraphicsImageRenderer(size: live.bounds.size, format: fmt).image { rc in
            InkRenderer.draw([InkStroke(colorHex: "#000000FF", points: pts.map { InkPoint($0, width: width) })], in: rc.cgContext)
        }
        let a = inkAmount(liveImg), b = inkAmount(pageImg)
        XCTAssertGreaterThan(b, 0)
        XCTAssertEqual(a / b, 1, accuracy: 0.1, "寫的時候的筆跡要和存進頁面後一樣粗")
    }

    /// 整張圖的墨水量（alpha 加總）
    private func inkAmount(_ img: UIImage) -> Double {
        guard let cg = img.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 3, to: px.count, by: 4).reduce(0.0) { $0 + Double(px[$1]) }
    }

    /// 回報的問題：橡皮擦擦掉的範圍比圓圈大很多。擦一次最多只能少掉圓圈直徑那麼長的線
    func testPixelEraserRemovesNoMoreThanTheCircle() {
        // 寫得快：點和點之間 30pt
        let line = stroke((0...10).map { (CGFloat($0) * 30, 0) }, width: 2)
        let r: CGFloat = 8
        let out = InkGeometry.erase([line], at: CGPoint(x: 150, y: 0), radius: r, partial: true)!
        func length(_ s: InkStroke) -> CGFloat {
            zip(s.points, s.points.dropFirst()).reduce(0) { $0 + hypot($1.1.point.x - $1.0.point.x, $1.1.point.y - $1.0.point.y) }
        }
        let removed = length(line) - out.reduce(0) { $0 + length($1) }
        XCTAssertEqual(removed, r * 2, accuracy: 0.01)
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
        window = try TestWindow.make()
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
        editor.inkMoved(samples)
        editor.inkEnded(cancelled: false)
        spin()
    }

    /// 讓 run loop 跑一下：真的使用時每一筆都是分開的觸控事件，上一步也分開登記
    private func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// 螢幕上這塊區域（文件座標）的墨水量：白紙上每個像素有多深
    /// 螢幕上這塊區域（文件座標）的墨水：白紙上每個像素有多深的總和，以及墨水的重心（螢幕像素）
    private func inkOnScreen(_ r: CGRect) -> (amount: Double, x: Double, y: Double) {
        let region = editor.pagesContainer.convert(r, to: window)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = window.screen.scale
        let img = UIGraphicsImageRenderer(size: region.size, format: fmt).image { rc in
            UIColor.white.setFill()
            rc.fill(CGRect(origin: .zero, size: region.size))
            window.drawHierarchy(in: CGRect(origin: CGPoint(x: -region.minX, y: -region.minY), size: window.bounds.size),
                                 afterScreenUpdates: true)
        }
        guard let cg = img.cgImage else { return (0, 0, 0) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, sx = 0.0, sy = 0.0
        for i in 0..<(w * h) {
            let d = Double(255 - min(px[i * 4], px[i * 4 + 1], px[i * 4 + 2]))
            guard d > 0 else { continue }
            sum += d
            sx += d * Double(i % w)
            sy += d * Double(i / w)
        }
        return sum > 0 ? (sum, sx / sum, sy / sum) : (0, 0, 0)
    }

    private func darkness(ofDocRect r: CGRect) -> Double { inkOnScreen(r).amount }

    /// 回報的問題：細線寫的時候正常，筆離開後突然變粗，過一下才變回來（寫的時候的筆跡和頁面上的筆跡疊在一起）
    func testThinStrokeKeepsItsLookAfterLift() {
        let saved = BrushStore.shared.current
        var p = saved
        p.style = .pen
        p.width = 0.4
        BrushStore.shared.update(p)
        defer { BrushStore.shared.update(saved) }

        let a = docPoint(100, 300), b = docPoint(400, 340)
        editor.inkBegan(.init(point: a, force: 0.5))
        editor.inkMoved((1...150).map { i -> InkCaptureRecognizer.Sample in
            let t = CGFloat(i) / 150
            return .init(point: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + sin(t * 25) * 10), force: 0.5)
        })
        spin(0.1)
        let area = CGRect(x: a.x, y: a.y - 20, width: b.x - a.x, height: b.y - a.y + 40).insetBy(dx: -10, dy: -10)
        let writing = darkness(ofDocRect: area)
        editor.inkEnded(cancelled: false)
        var afterLift: [Double] = []
        for _ in 0..<12 {
            spin(0.04)
            afterLift.append(darkness(ofDocRect: area))
        }
        spin(1.5)
        let settled = darkness(ofDocRect: area)
        XCTAssertGreaterThan(settled, 0, "筆跡要畫在頁面上")
        XCTAssertEqual(writing / settled, 1, accuracy: 0.12, "寫的時候和放開後要一樣粗")
        for (i, d) in afterLift.enumerated() {
            XCTAssertEqual(d / settled, 1, accuracy: 0.12, "放開後 \((i + 1) * 40)ms 粗細變了（變粗＝兩層疊在一起，變淡＝閃一下）")
        }
    }

    /// 回報的問題：寫完字後筆跡會稍微往右偏。放開前（寫的時候那層）和放開後（頁面那層）筆跡在螢幕上要在同一個位置
    func testStrokeStaysInPlaceAfterLift() {
        for zoom in [1.0, 2.0, 1.37] {
            editor.canvas.zoomScale = editor.fitZoom * CGFloat(zoom)
            spin(0.2)
            let a = docPoint(150, 250), b = docPoint(150, 330), c = docPoint(230, 330)
            editor.inkBegan(.init(point: a, force: 0.5))
            let pts = (1...40).map { i -> CGPoint in
                let t = CGFloat(i) / 40
                return t <= 0.5 ? CGPoint(x: a.x, y: a.y + (b.y - a.y) * t * 2) : CGPoint(x: b.x + (c.x - b.x) * (t - 0.5) * 2, y: b.y)
            }
            editor.inkMoved(pts.map { .init(point: $0, force: 0.5) })
            spin(0.1)
            let area = CGRect(x: a.x - 15, y: a.y - 15, width: c.x - a.x + 30, height: c.y - a.y + 30)
            let writing = inkOnScreen(area)
            editor.inkEnded(cancelled: false)
            spin(1.5)
            let settled = inkOnScreen(area)
            XCTAssertGreaterThan(settled.amount, 0)
            XCTAssertEqual(settled.x, writing.x, accuracy: 0.3, "放大 \(zoom) 倍：放開後筆跡左右移動了")
            XCTAssertEqual(settled.y, writing.y, accuracy: 0.3, "放大 \(zoom) 倍：放開後筆跡上下移動了")
            editor.undoTapped()
            spin(0.3)
        }
    }

    /// 回報的問題：局部擦除的範圍比橡皮擦的圓圈大。圓圈大小是螢幕上的大小，放大頁面時擦到的範圍要跟著變小
    func testPixelEraserMatchesItsOnScreenSize() {
        let pixelBefore = EditorSettings.shared.pixelEraser, widthBefore = EditorSettings.shared.eraserWidth
        EditorSettings.shared.pixelEraser = true
        EditorSettings.shared.eraserWidth = 16
        defer {
            EditorSettings.shared.pixelEraser = pixelBefore
            EditorSettings.shared.eraserWidth = widthBefore
        }
        write(from: docPoint(100, 200), to: docPoint(300, 200))
        editor.canvas.zoomScale = editor.fitZoom * 2
        spin(0.1)
        let z = editor.canvas.zoomScale
        editor.setTool(.eraser)
        editor.inkEraseUndoRegistered = []
        editor.eraseInk(at: docPoint(200, 200))
        func length(_ s: InkStroke) -> CGFloat {
            zip(s.points, s.points.dropFirst()).reduce(0) { $0 + hypot($1.1.point.x - $1.0.point.x, $1.1.point.y - $1.0.point.y) }
        }
        let left = editor.pages[0].ink.reduce(0) { $0 + length($1) }
        XCTAssertEqual(200 - left, 16 / z, accuracy: 0.05, "擦掉的長度＝螢幕上圓圈的直徑")
    }

    func testInkClaimsPencilWithoutTogglingPencilKit() {
        XCTAssertTrue(editor.customInkActive)
        XCTAssertTrue(editor.inkRecognizer.isEnabled)
        // PencilKit 的書寫手勢不開關（開關它會讓 PencilKit 卡住），改成等自製筆刷失敗才開始
        XCTAssertTrue(editor.canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(editor.gestureRecognizer(editor.inkRecognizer, shouldBeRequiredToFailBy: editor.canvas.drawingGestureRecognizer))
        XCTAssertTrue(editor.gestureRecognizer(editor.inkRecognizer, shouldBeRequiredToFailBy: editor.canvas.panGestureRecognizer))
        editor.setTool(.highlighter)
        XCTAssertFalse(editor.inkRecognizer.isEnabled, "螢光筆照樣用 PencilKit")
        XCTAssertFalse(editor.gestureRecognizer(editor.inkRecognizer, shouldBeRequiredToFailBy: editor.canvas.drawingGestureRecognizer))
        editor.setTool(.eraser)
        editor.setTool(.pen)
        XCTAssertTrue(editor.canvas.drawingGestureRecognizer.isEnabled)
    }

    func testPenWidthDoesNotThinWithPressure() {
        var p = BrushStore.shared.current
        let style = p.style
        p.style = .pen
        BrushStore.shared.update(p)
        editor.inkBegan(.init(point: docPoint(100, 200), force: 0.9))
        editor.inkMoved([.init(point: docPoint(120, 200), force: 0.5), .init(point: docPoint(140, 200), force: 0.05)])
        editor.inkEnded(cancelled: false)
        let ws = editor.pages[0].ink[0].points.map(\.width)
        XCTAssertEqual(Set(ws).count, 1, "筆照設定的粗細畫，放開前不會變細")
        p.style = style
        BrushStore.shared.update(p)
    }

    func testEstimatedSampleIsReplacedByTheAccurateOne() {
        let a = docPoint(100, 200)
        editor.inkBegan(.init(point: a, force: 0.5))
        editor.inkMoved([.init(point: docPoint(110, 200), force: 0.1, updateIndex: 7),
                         .init(point: docPoint(120, 200), force: 0.5)])
        // Pencil 補上第 7 號取樣點的準確位置
        editor.inkUpdated(.init(point: docPoint(110, 203), force: 0.5, updateIndex: 7))
        editor.inkEnded(cancelled: false)
        let pts = editor.pages[0].ink[0].points.map(\.point)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[1].y, 203, accuracy: 0.01, "要用補上的準確位置")
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

    /// 回報的問題：自製筆刷開著時手指不能捲動頁面（縮放可以）。手指的觸碰不能交給自製筆刷，否則捲動會一直等它
    func testFingerTouchGoesToScrollNotInk() {
        XCTAssertTrue(editor.customInkActive)
        let finger = FakeTouch(type: .direct), pencil = FakeTouch(type: .pencil)
        XCTAssertFalse(editor.gestureRecognizer(editor.inkRecognizer, shouldReceive: finger), "手指要拿來捲動")
        XCTAssertTrue(editor.gestureRecognizer(editor.inkRecognizer, shouldReceive: pencil))
        // 只有手指沒有交給自製筆刷時，捲動等它失敗這條規則才不會卡住
        XCTAssertTrue(editor.gestureRecognizer(editor.inkRecognizer, shouldBeRequiredToFailBy: editor.canvas.panGestureRecognizer))
    }
}

