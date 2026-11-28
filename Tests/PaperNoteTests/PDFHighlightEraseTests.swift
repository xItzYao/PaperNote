import XCTest
@testable import PaperNote

/// 回報的問題（11/29）：在 PDF 上擦螢光筆會卡，在自己建的筆記本不會。
/// PDF 上的螢光筆是對齊文字的螢光標示（page.highlights），之前和 PDF 畫在同一張背景圖裡：
/// 擦掉一塊就要把整頁 PDF 重畫一次（每一格都重新解析 PDF），擦的時候一直在重畫。
/// 自己建的筆記本上螢光筆是筆跡，擦掉不用動背景
final class PDFHighlightEraseTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var work: URL!

    /// PDF 上黑色的一塊（像一行字）：頁面內容座標
    private let ink = CGRect(x: 80, y: 100, width: 240, height: 24)
    private let yellow = "#FFEB3B"

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    /// 一頁有很多行字的 PDF（左上角有一塊黑色）
    private func pdfData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            ctx.beginPage()
            UIColor.black.setFill()
            UIRectFill(ink)
            let font = UIFont.systemFont(ofSize: 11)
            for row in 0..<60 {
                let line = String(repeating: "Signals and systems \(row) — Fourier transform, convolution. ", count: 2)
                (line as NSString).draw(at: CGPoint(x: 40, y: 160 + CGFloat(row) * 11), withAttributes: [.font: font, .foregroundColor: UIColor.black])
            }
        }
    }

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let url = work.appendingPathComponent("notes.pdf")
        try pdfData().write(to: url)
        notebookID = try LibraryStore.shared.importPDF(from: url, folder: nil).id
        editor = NotebookViewController(session: try NotebookSession(id: notebookID), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        spin(0.5)
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    /// 每一行字都畫了螢光筆（各自一個螢光標示）
    private func highlightEveryLine() {
        editor.updatePage(0) { page in
            page.highlights = (0..<60).map { row in
                TextHighlight(rects: [CGRect(x: 40, y: 160 + CGFloat(row) * 11, width: 480, height: 11)], colorHex: yellow)
            }
        }
    }

    func testErasingHighlightsOnAPDFDoesNotRedrawThePDF() throws {
        highlightEveryLine()
        spin(1.0)
        let before = PageBackgroundView.tilesDrawn
        editor.setTool(.eraser)
        let o = editor.contentOrigin(0)
        var steps = FrameTimes()
        // 從上往下擦過 30 行，每一下走 6pt（和實際擦的時候一樣，每一格畫面擦一次）
        var last = CGPoint(x: o.x + 300, y: o.y + 160)
        for k in 1...55 {
            let p = CGPoint(x: o.x + 300, y: o.y + 160 + CGFloat(k) * 6)
            let t = CACurrentMediaTime()
            editor.erase(along: [last, p])
            CATransaction.flush()
            steps.add(CACurrentMediaTime() - t)
            last = p
            spin(1.0 / 60)
        }
        spin(0.5)
        let drawn = PageBackgroundView.tilesDrawn - before
        let left = editor.pages[0].highlights.count
        print("PDFHLERASE tiles=\(drawn) left=\(left) steps \(steps.summary)")
        XCTAssertLessThan(left, 35, "擦到的那幾行螢光標示拿掉了")
        XCTAssertEqual(drawn, 0, "擦螢光標示不用重畫 PDF")
        assertFast(steps, under: 0.03, "擦 PDF 上的螢光標示")
    }

    func testAddingAHighlightOnAPDFDoesNotRedrawThePDF() throws {
        spin(1.0)
        let before = PageBackgroundView.tilesDrawn
        highlightEveryLine()
        spin(0.5)
        XCTAssertEqual(PageBackgroundView.tilesDrawn - before, 0, "畫螢光筆也不用重畫 PDF")
    }

    /// 螢光標示還是在字的底下：黑字不會被蓋淡，白紙的地方是黃色
    func testHighlightsStayUnderThePDFText() throws {
        editor.updatePage(0) { page in
            page.highlights = [TextHighlight(rects: [CGRect(x: ink.minX - 20, y: ink.minY - 4, width: 140, height: ink.height + 8)], colorHex: yellow)]
        }
        spin(0.8)
        let o = editor.contentOrigin(0)
        let underInk = pixel(CGPoint(x: o.x + ink.minX + 30, y: o.y + ink.midY))
        let underPaper = pixel(CGPoint(x: o.x + ink.minX - 10, y: o.y + ink.midY))
        let plainInk = pixel(CGPoint(x: o.x + ink.maxX - 20, y: o.y + ink.midY))
        let plainPaper = pixel(CGPoint(x: o.x + ink.maxX + 60, y: o.y + ink.midY))
        XCTAssertLessThan(max(underInk.r, underInk.g, underInk.b), 60, "螢光標示底下的黑字還是黑的：\(underInk)")
        XCTAssertGreaterThan(underPaper.r, 220, "白紙上是黃色：\(underPaper)")
        XCTAssertGreaterThan(underPaper.g, 200)
        XCTAssertLessThan(underPaper.b, 150)
        XCTAssertLessThan(max(plainInk.r, plainInk.g, plainInk.b), 60, "沒畫螢光筆的字：\(plainInk)")
        XCTAssertGreaterThan(min(plainPaper.r, plainPaper.g, plainPaper.b), 235, "沒畫螢光筆的白紙：\(plainPaper)")
    }

    /// 畫面上這一點（文件座標）的顏色
    private func pixel(_ p: CGPoint) -> (r: Int, g: Int, b: Int) {
        let q = editor.pagesContainer.convert(p, to: window)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: fmt).image { _ in
            window.drawHierarchy(in: CGRect(origin: CGPoint(x: -q.x, y: -q.y), size: window.bounds.size), afterScreenUpdates: true)
        }
        guard let cg = img.cgImage else { return (0, 0, 0) }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
}
