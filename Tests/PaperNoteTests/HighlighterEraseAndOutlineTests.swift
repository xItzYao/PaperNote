import XCTest
import PencilKit
import PDFKit
@testable import PaperNote

/// 回報的需求：螢光筆是中心一條軌跡加上很粗的線寬畫出來的，橡皮擦只要碰到畫出來的範圍就擦掉那段的軌跡中心，比較容易擦掉
final class HighlighterEraseTests: XCTestCase {
    /// 一條橫的螢光筆（App 的螢光筆：半透明的 monoline）：y = 100，x 從 0 到 200。
    /// size 12 畫出來寬 2·12 − 4 = 20（上下各 10）
    private func highlighter(y: CGFloat = 100, ink: PKInk = PKInk(.monoline, color: UIColor.systemYellow.withAlphaComponent(0.4)),
                             size: CGFloat = 12) -> PKStroke {
        let pts = stride(from: CGFloat(0), through: 200, by: 10).enumerated().map { i, x in
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: size, height: size),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    func testTheReachMatchesWhatPencilKitDraws() {
        let s = highlighter()
        XCTAssertTrue(NotebookViewController.isHighlighterStroke(s))
        XCTAssertEqual(s.renderBounds.height, 20, accuracy: 3, "測試前提：畫出來寬 20")
        XCTAssertEqual(StrokeEraser.drawnHalfWidth(s.ink, CGSize(width: 12, height: 12)), 10)
    }

    func testOldMarkerHighlightsAreErasedByTheirLongSide() throws {
        // 舊筆記的 marker：斜的筆頭，長的那邊約 1.1·size
        let s = highlighter(ink: PKInk(.marker, color: .yellow), size: 20)
        XCTAssertNotNil(StrokeEraser.erase([s], along: [CGPoint(x: 100, y: 112)], radius: 4, partial: false))
    }

    private func pen(y: CGFloat = 100) -> PKStroke {
        let pts = stride(from: CGFloat(0), through: 200, by: 10).enumerated().map { i, x in
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: 2, height: 2),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    func testTouchingTheEdgeOfAHighlighterErasesIt() throws {
        // 橡皮擦（半徑 4）碰到螢光筆的下緣（離中心 12，線寬一半 10 + 半徑 4 = 14 以內），沒有碰到中心
        let result = try XCTUnwrap(StrokeEraser.erase([highlighter()], along: [CGPoint(x: 100, y: 112)], radius: 4, partial: false),
                                   "碰到畫出來的範圍就擦到")
        XCTAssertTrue(result.isEmpty, "整筆擦除：拿掉整筆")
    }

    func testMissingTheHighlighterLeavesIt() {
        XCTAssertNil(StrokeEraser.erase([highlighter()], along: [CGPoint(x: 100, y: 116)], radius: 4, partial: false),
                     "離畫出來的範圍還有一點距離：不擦")
    }

    /// 看得到的部分（擦掉的螢光筆是同一筆、那段透明）：每 1pt 的中心點
    private func visibleCenters(_ strokes: [PKStroke]) -> [CGPoint] {
        strokes.flatMap { s in
            s.path.interpolatedPoints(by: .distance(1)).filter { $0.opacity > StrokeEraser.erasedOpacity }.map { $0.location.applying(s.transform) }
        }
    }

    func testPartialErasingCutsTheCentreLineWhereTheCircleTouched() throws {
        let result = try XCTUnwrap(StrokeEraser.erase([highlighter()], along: [CGPoint(x: 100, y: 108)], radius: 4, partial: true))
        XCTAssertEqual(result.count, 1, "螢光筆還是同一筆（切成好幾筆的話，交錯的地方會疊成兩層）")
        let xs = visibleCenters(result).map(\.x)
        let left = xs.filter { $0 < 100 }, right = xs.filter { $0 > 100 }
        XCTAssertLessThan(try XCTUnwrap(left.max()), 100 - 4, "碰到的那段中心拿掉了")
        XCTAssertGreaterThan(try XCTUnwrap(right.min()), 100 + 4)
        XCTAssertLessThan(try XCTUnwrap(left.max()), 100 - 4 - 4, "連圓圈只碰到筆畫邊緣的那段中心也拿掉")
        XCTAssertGreaterThan(try XCTUnwrap(left.max()), 70, "其他地方留著")
        XCTAssertTrue(result.allSatisfy { NotebookViewController.isHighlighterStroke($0) }, "還是螢光筆")
    }

    /// 回報的需求（更正）：刪除圓心後連同整個圓都刪掉，螢光筆比橡皮擦粗，也只要擦一條線就擦斷
    func testAThinEraserLineAcrossAThickHighlighterRemovesItsWholeWidthThere() throws {
        // 螢光筆寬 20，橡皮擦半徑 2（細很多），從上面劃到下面一條線
        let line = [CGPoint(x: 100, y: 80), CGPoint(x: 100, y: 120)]
        let result = try XCTUnwrap(StrokeEraser.erase([highlighter()], along: line, radius: 2, partial: true))
        let xs = visibleCenters(result).map(\.x)
        XCTAssertTrue(xs.contains { $0 < 80 } && xs.contains { $0 > 120 }, "擦斷成左右兩邊")
        // 留下來的每個圓都碰不到橡皮擦劃過的那條線：那裡整個寬度都不見了，上下沒有殘留
        let half = StrokeEraser.drawnHalfWidth(result[0].ink, CGSize(width: 12, height: 12))
        for x in xs {
            XCTAssertGreaterThan(abs(x - 100), half, "x=\(x) 的圓還蓋到擦過的線")
        }
        // 只擦到上緣一點點也一樣：碰到的那幾個圓整個拿掉
        let edge = try XCTUnwrap(StrokeEraser.erase([highlighter()], along: [CGPoint(x: 150, y: 89)], radius: 2, partial: true))
        let ex = visibleCenters(edge).map(\.x)
        XCTAssertFalse(ex.contains { abs($0 - 150) < 3 }, "碰到邊緣也擦斷，不是只擦掉邊緣")
        XCTAssertTrue(ex.contains { $0 < 140 } && ex.contains { $0 > 160 })
    }

    func testAnEraserPathSweepingAcrossCountsEveryPoint() throws {
        // 橡皮擦從上面劃過到下面：中間經過的點都算
        let path = [CGPoint(x: 60, y: 60), CGPoint(x: 60, y: 140)]
        let result = try XCTUnwrap(StrokeEraser.erase([highlighter()], along: path, radius: 4, partial: true))
        XCTAssertFalse(visibleCenters(result).contains { abs($0.x - 60) < 10 }, "經過的地方都擦掉")
    }

    func testPenStrokesAreErasedWithinWhatTheyDraw() {
        // 橡皮擦是 App 自己擦：一般的筆也一樣，碰到畫出來的範圍就擦到
        XCTAssertEqual(StrokeEraser.erase([pen()], along: [CGPoint(x: 100, y: 103)], radius: 4, partial: false)?.count, 0)
        XCTAssertNil(StrokeEraser.erase([pen()], along: [CGPoint(x: 100, y: 106)], radius: 4, partial: false), "沒碰到")
    }

    func testStrokesFarAwayAreKeptAsTheyAre() throws {
        var far = highlighter(y: 400)
        far.transform = CGAffineTransform(translationX: 3, y: 0)
        let result = try XCTUnwrap(StrokeEraser.erase([highlighter(), far], along: [CGPoint(x: 100, y: 100)], radius: 4, partial: false))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].transform, far.transform, "沒碰到的那筆原樣留著")
    }

    /// 回報的問題：螢光筆要等筆尖離開螢幕才變成正確的擦除 → 擦的時候就跟著消失
    func testTheEditorErasesWhileTheEraserIsStillDownAndItIsOneUndoStep() throws {
        let meta = LibraryStore.shared.createNotebook(title: "HighlighterErase", folder: nil, paper: .blank, landscape: false)
        defer { LibraryStore.shared.deleteNotebook(meta.id) }
        let editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        let window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.view.layoutIfNeeded()
        let savedPixel = EditorSettings.shared.pixelEraser
        let savedReturn = EditorSettings.shared.eraserAutoReturn
        EditorSettings.shared.pixelEraser = false
        EditorSettings.shared.eraserAutoReturn = false
        defer {
            EditorSettings.shared.pixelEraser = savedPixel
            EditorSettings.shared.eraserAutoReturn = savedReturn
        }

        let o = editor.contentOrigin(0)
        var stroke = highlighter(y: 0)
        stroke.transform = CGAffineTransform(translationX: o.x + 100, y: o.y + 200)
        var line = pen(y: 0)
        line.transform = CGAffineTransform(translationX: o.x + 100, y: o.y + 400)
        editor.setDrawing(PKDrawing(strokes: [stroke, line]))
        editor.setTool(.eraser)
        XCTAssertFalse(editor.canvas.drawingGestureRecognizer.isEnabled, "PencilKit 不擦，App 自己擦")
        // 筆尖碰到螢光筆的上緣：還沒放開就擦掉了
        editor.eraserBegan(at: CGPoint(x: o.x + 200, y: o.y + 200 - 11))
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 1, "擦的時候就消失")
        XCTAssertTrue(editor.canvas.drawing.strokes[0].ink.inkType == .pen)
        // 繼續往下擦到另一筆
        editor.eraserMoved([CGPoint(x: o.x + 200, y: o.y + 300), CGPoint(x: o.x + 200, y: o.y + 402)])
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 0)
        editor.eraserEnded()
        editor.undoTapped()
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 2, "一次擦除是一步，一次復原全部回來")
    }

    func testTheEraserCatchesThePencilBeforePencilKitAndThePageScroll() throws {
        let meta = LibraryStore.shared.createNotebook(title: "EraserGesture", folder: nil, paper: .blank, landscape: false)
        defer { LibraryStore.shared.deleteNotebook(meta.id) }
        let editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        let window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.view.layoutIfNeeded()
        let savedFinger = EditorSettings.shared.fingerDrawing
        EditorSettings.shared.fingerDrawing = false
        defer { EditorSettings.shared.fingerDrawing = savedFinger }

        editor.setTool(.eraser)
        XCTAssertTrue(editor.eraserCapture.isEnabled)
        XCTAssertTrue(editor.gestureRecognizer(editor.eraserCapture, shouldBeRequiredToFailBy: editor.canvas.panGestureRecognizer),
                      "擦的時候頁面不會跟著捲動")
        XCTAssertTrue(editor.gestureRecognizer(editor.eraserCapture, shouldBeRequiredToFailBy: editor.canvas.drawingGestureRecognizer))
        XCTAssertTrue(editor.gestureRecognizer(editor.eraserCapture, shouldReceive: FakeTouch(type: .pencil)))
        XCTAssertFalse(editor.gestureRecognizer(editor.eraserCapture, shouldReceive: FakeTouch(type: .direct)), "手指拿來捲動")
        editor.setTool(.highlighter)
        XCTAssertFalse(editor.eraserCapture.isEnabled)
        XCTAssertTrue(editor.canvas.drawingGestureRecognizer.isEnabled, "換回螢光筆：PencilKit 照常書寫")
    }

    /// 回報的問題（11/20）：擦螢光筆時，自己交錯的那一筆被切斷後，交錯的地方畫成兩層，顏色變深
    func testErasingAHighlighterThatCrossesItselfKeepsTheCrossingOneLayer() throws {
        // 一筆螢光筆：往右走，往下、往左，再往上穿過橫的那段（交錯在 (100, 100)）
        let corners = [CGPoint(x: 20, y: 100), CGPoint(x: 180, y: 100), CGPoint(x: 180, y: 180), CGPoint(x: 100, y: 180), CGPoint(x: 100, y: 20)]
        var locs: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let n = Int(hypot(b.x - a.x, b.y - a.y) / 5)
            for i in 0..<n {
                let f = CGFloat(i) / CGFloat(n)
                locs.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
        }
        locs.append(corners[corners.count - 1])
        let pts = locs.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: 12, height: 12),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.monoline, color: UIColor.systemYellow.withAlphaComponent(0.4)),
                              path: PKStrokePath(controlPoints: pts, creationDate: Date()))
        /// 畫出來那一點的不透明度
        func alpha(_ strokes: [PKStroke], at p: CGPoint) -> CGFloat {
            let img = PKDrawing(strokes: strokes).image(from: CGRect(x: 0, y: 0, width: 200, height: 200), scale: 1)
            guard let cg = img.cgImage else { return 0 }
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: -p.x, y: -(CGFloat(cg.height) - 1 - p.y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
            return CGFloat(px[3]) / 255
        }
        let single = alpha([stroke], at: CGPoint(x: 50, y: 100))
        XCTAssertGreaterThan(single, 0.2, "測試的前提：畫得出來")
        XCTAssertEqual(alpha([stroke], at: CGPoint(x: 100, y: 100)), single, accuracy: 0.05, "測試的前提：同一筆交錯的地方只有一層")
        // 擦斷右邊直的那段
        let after = try XCTUnwrap(StrokeEraser.erase([stroke], along: [CGPoint(x: 180, y: 140)], radius: 4, partial: true))
        XCTAssertLessThan(alpha(after, at: CGPoint(x: 180, y: 140)), 0.02, "擦掉的地方沒了")
        XCTAssertLessThan(alpha(after, at: CGPoint(x: 188, y: 140)), 0.02, "整個寬度都擦掉")
        XCTAssertEqual(alpha(after, at: CGPoint(x: 100, y: 100)), single, accuracy: 0.05, "交錯的地方還是一層，顏色沒變深")
        XCTAssertEqual(alpha(after, at: CGPoint(x: 50, y: 100)), single, accuracy: 0.05)
        XCTAssertEqual(alpha(after, at: CGPoint(x: 180, y: 110)), single, accuracy: 0.05, "擦的地方旁邊留著")
        // 再擦一次擦過的地方：沒有變化；擦到別的地方：還是同一筆
        XCTAssertNil(StrokeEraser.erase(after, along: [CGPoint(x: 180, y: 140)], radius: 4, partial: true), "擦掉的部分不會再被擦到")
        let again = try XCTUnwrap(StrokeEraser.erase(after, along: [CGPoint(x: 140, y: 180)], radius: 4, partial: true))
        XCTAssertEqual(again.count, 1)
        XCTAssertLessThan(alpha(again, at: CGPoint(x: 180, y: 140)), 0.02, "之前擦掉的地方沒有回來")
        XCTAssertEqual(alpha(again, at: CGPoint(x: 100, y: 100)), single, accuracy: 0.05)
    }

    /// 回報的問題（11/20）：PencilKit 的筆、螢光筆用局部擦除，彎的地方會慢慢變平滑、越擦越直，不只擦到的地方
    func testPartialErasingDoesNotStraightenTheRestOfTheStroke() throws {
        // 彎來彎去的一筆：控制點在 y = 100、110 之間來回
        let pts = stride(from: CGFloat(0), through: 200, by: 5).enumerated().map { i, x in
            PKStrokePoint(location: CGPoint(x: x, y: i % 2 == 0 ? 100 : 110), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let original = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
        func curve(_ strokes: [PKStroke]) -> [CGPoint] {
            strokes.flatMap { s in s.path.interpolatedPoints(by: .distance(1)).map { $0.location.applying(s.transform) } }
        }
        let before = curve([original]).filter { $0.x > 120 && $0.x < 180 }
        // 從左邊一點一點擦過去（擦的時候每移動一下就擦一次）
        var strokes = [original]
        var passes = 0
        for k in 0..<30 {
            if let r = StrokeEraser.erase(strokes, along: [CGPoint(x: CGFloat(k) * 2, y: 105)], radius: 4, partial: true) {
                strokes = r
                passes += 1
            }
        }
        XCTAssertGreaterThan(passes, 10, "測試的前提：擦了很多次")
        XCTAssertFalse(strokes.isEmpty)
        let after = curve(strokes)
        // 離擦的地方很遠的線：形狀和原本一樣
        var worst: CGFloat = 0
        for p in before {
            worst = max(worst, after.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? .infinity)
        }
        XCTAssertLessThan(worst, 0.3, "沒擦到的地方被拉直了 \(worst)pt")
        let ys = after.filter { $0.x > 120 && $0.x < 180 }.map(\.y), ys0 = before.map(\.y)
        XCTAssertEqual(try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min()), try XCTUnwrap(ys0.max()) - XCTUnwrap(ys0.min()), accuracy: 0.3,
                       "彎的高度還在")
    }
}

/// 回報的需求：PDF 大綱模式，在「全部頁面」「我的最愛」旁邊加一個「大綱」
final class PDFOutlineTests: XCTestCase {
    /// 三頁的 PDF，大綱：第一章 → 第 1 頁（底下 1.1 → 第 3 頁）、第二章 → 第 2 頁
    private func outlinedPDF() throws -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { ctx in
            for _ in 0..<3 { ctx.beginPage() }
        }
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let root = PDFOutline()
        func item(_ title: String, page: Int) throws -> PDFOutline {
            let o = PDFOutline()
            o.label = title
            o.destination = PDFDestination(page: try XCTUnwrap(doc.page(at: page)), at: .zero)
            return o
        }
        let one = try item("第一章", page: 0)
        root.insertChild(one, at: 0)
        one.insertChild(try item("1.1", page: 2), at: 0)
        root.insertChild(try item("第二章", page: 1), at: 1)
        doc.outlineRoot = root
        return doc
    }

    func testTheOutlinePointsAtTheNotebooksPages() throws {
        let doc = try outlinedPDF()
        // 筆記本：PDF 第 1 頁、一張空白紙、PDF 第 3 頁（PDF 第 2 頁刪掉了）
        let pages = [Page(background: .pdf(file: "a.pdf", index: 0)),
                     Page(background: .paper(width: 595, height: 842, style: .ruled)),
                     Page(background: .pdf(file: "a.pdf", index: 2))]
        let entries = PDFOutlineList.entries(pages: pages) { $0 == "a.pdf" ? doc : nil }
        XCTAssertEqual(entries, [
            PDFOutlineEntry(title: "第一章", depth: 0, pageIndex: 0),
            PDFOutlineEntry(title: "1.1", depth: 1, pageIndex: 2),
            PDFOutlineEntry(title: "第二章", depth: 0, pageIndex: nil),
        ], "子項目縮排；對到筆記本的頁碼；刪掉的頁面沒有頁碼")
    }

    func testAPDFWithoutAnOutlineHasNoEntries() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { $0.beginPage() }
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(PDFOutlineList.entries(pages: [Page(background: .pdf(file: "a.pdf", index: 0))]) { _ in doc }.isEmpty)
    }

    func testThePageOverviewHasAnOutlineTab() throws {
        let meta = LibraryStore.shared.createNotebook(title: "OutlineTab", folder: nil, paper: .blank, landscape: false)
        defer { LibraryStore.shared.deleteNotebook(meta.id) }
        let editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        let overview = PageOverviewController(editor: editor)
        let nav = UINavigationController(rootViewController: overview)
        nav.loadViewIfNeeded()
        overview.loadViewIfNeeded()
        XCTAssertEqual((0..<overview.filter.numberOfSegments).map { overview.filter.titleForSegment(at: $0) },
                       ["全部頁面", "我的最愛", "大綱"], "「全部頁面」「我的最愛」旁邊是「大綱」")
        overview.filter.selectedSegmentIndex = PageOverviewController.outlineSegment
        overview.filter.sendActions(for: .valueChanged)
        XCTAssertTrue(overview.showingOutline)
        XCTAssertFalse(overview.outlineTable.isHidden, "顯示大綱")
        XCTAssertEqual(overview.outline, [])
        XCTAssertEqual((overview.outlineTable.backgroundView as? UILabel)?.text,
                       "還沒有大綱。長按「全部頁面」裡的頁面，或在頁碼的選單選「將該頁加入大綱」。")
        XCTAssertNil(overview.navigationItem.rightBarButtonItem, "大綱不能選取頁面")
        overview.filter.selectedSegmentIndex = 0
        overview.filter.sendActions(for: .valueChanged)
        XCTAssertTrue(overview.outlineTable.isHidden, "切回全部頁面")
        XCTAssertNotNil(overview.navigationItem.rightBarButtonItem)
    }
}
