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
        XCTAssertEqual(HighlighterErase.drawnHalfWidth(s.ink, CGSize(width: 12, height: 12)), 10)
    }

    func testOldMarkerHighlightsAreErasedByTheirLongSide() throws {
        // 舊筆記的 marker：斜的筆頭，長的那邊約 1.1·size
        let s = highlighter(ink: PKInk(.marker, color: .yellow), size: 20)
        XCTAssertNotNil(HighlighterErase.erase([s], along: [CGPoint(x: 100, y: 112)], radius: 4, partial: false))
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
        let result = try XCTUnwrap(HighlighterErase.erase([highlighter()], along: [CGPoint(x: 100, y: 112)], radius: 4, partial: false),
                                   "碰到畫出來的範圍就擦到")
        XCTAssertTrue(result.isEmpty, "整筆擦除：拿掉整筆")
    }

    func testMissingTheHighlighterLeavesIt() {
        XCTAssertNil(HighlighterErase.erase([highlighter()], along: [CGPoint(x: 100, y: 116)], radius: 4, partial: false),
                     "離畫出來的範圍還有一點距離：不擦")
    }

    func testPartialErasingCutsTheCentreLineWhereTheCircleTouched() throws {
        let result = try XCTUnwrap(HighlighterErase.erase([highlighter()], along: [CGPoint(x: 100, y: 108)], radius: 4, partial: true))
        XCTAssertEqual(result.count, 2, "切成左右兩段")
        let xs = result.map { s in s.path.map { $0.location.applying(s.transform).x } }
        let left = try XCTUnwrap(xs.first { ($0.first ?? 0) < 50 })
        let right = try XCTUnwrap(xs.first { ($0.first ?? 0) > 50 })
        XCTAssertLessThan(try XCTUnwrap(left.max()), 100 - 4, "碰到的那段中心拿掉了")
        XCTAssertGreaterThan(try XCTUnwrap(right.min()), 100 + 4)
        XCTAssertLessThan(try XCTUnwrap(left.max()), 100 - 4 - 4, "連圓圈只碰到筆畫邊緣的那段中心也拿掉")
        XCTAssertGreaterThan(try XCTUnwrap(left.max()), 70, "其他地方留著")
        XCTAssertTrue(result.allSatisfy { NotebookViewController.isHighlighterStroke($0) }, "還是螢光筆")
    }

    func testAnEraserPathSweepingAcrossCountsEveryPoint() throws {
        // 橡皮擦從上面劃過到下面：中間經過的點都算
        let path = [CGPoint(x: 60, y: 60), CGPoint(x: 60, y: 140)]
        let result = try XCTUnwrap(HighlighterErase.erase([highlighter()], along: path, radius: 4, partial: true))
        XCTAssertEqual(result.count, 2)
    }

    func testPenStrokesAreLeftToTheNormalEraser() {
        XCTAssertNil(HighlighterErase.erase([pen()], along: [CGPoint(x: 100, y: 100)], radius: 4, partial: false),
                     "一般的筆照原本的橡皮擦（PencilKit）")
    }

    func testTheEditorErasesTheHighlighterWhenTheEraserLiftsAndItCanBeUndone() throws {
        let meta = LibraryStore.shared.createNotebook(title: "HighlighterErase", folder: nil, paper: .blank, landscape: false)
        defer { LibraryStore.shared.deleteNotebook(meta.id) }
        let editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        let window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.view.layoutIfNeeded()
        let savedPixel = EditorSettings.shared.pixelEraser
        EditorSettings.shared.pixelEraser = false
        defer { EditorSettings.shared.pixelEraser = savedPixel }

        let o = editor.contentOrigin(0)
        var stroke = highlighter(y: 0)
        stroke.transform = CGAffineTransform(translationX: o.x + 100, y: o.y + 200)
        editor.setDrawing(PKDrawing(strokes: [stroke]))
        editor.setTool(.eraser)
        let gesture = StrokeGesture(before: editor.canvas.drawing, mark: editor.history.recordCount)
        // 橡皮擦擦過螢光筆的上緣（PencilKit 沒擦到）
        let edge = CGPoint(x: o.x + 200, y: o.y + 200 - 11)
        editor.eraseHighlighterStrokes(along: [edge], gesture: gesture)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 0, "擦掉了")
        editor.undoTapped()
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 1, "可以復原")
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
        XCTAssertEqual((overview.outlineTable.backgroundView as? UILabel)?.text, "這本筆記本沒有 PDF")
        XCTAssertNil(overview.navigationItem.rightBarButtonItem, "大綱不能選取頁面")
        overview.filter.selectedSegmentIndex = 0
        overview.filter.sendActions(for: .valueChanged)
        XCTAssertTrue(overview.outlineTable.isHidden, "切回全部頁面")
        XCTAssertNotNil(overview.navigationItem.rightBarButtonItem)
    }
}
