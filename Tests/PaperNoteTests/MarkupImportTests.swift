import XCTest
import PDFKit
import PencilKit
@testable import PaperNote

/// 和「註記」存的一樣：AKInkAnnotation2 的 keyed archive，有 drawing（PKDrawing 的資料）和 drawingSize（頁面大小）
@objc(PaperNoteTestMarkupInk)
private final class FakeInk: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let drawing: Data
    let size: CGSize
    init(drawing: Data, size: CGSize) {
        self.drawing = drawing
        self.size = size
    }
    init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        coder.encode(drawing as NSData, forKey: "drawing")
        coder.encode(size.dictionaryRepresentation as NSDictionary, forKey: "drawingSize")
    }
}

/// 回報的問題：iPad「檔案」的「註記」寫的字，匯入後很糊、不能編輯。
/// 「註記」把筆跡存成圖章：外觀是頁面 2 倍大的點陣圖，原本的 PencilKit 筆跡在 /AAPL:AKExtras 裡
final class MarkupImportTests: XCTestCase {
    private let store = LibraryStore.shared
    private var created: [UUID] = []
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("markup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for id in created { store.deleteNotebook(id) }
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    private let pageSize = CGSize(width: 595, height: 842)
    /// 從頁面左上角量的（和「註記」一樣）
    private let strokePoints = (0...30).map { CGPoint(x: 100 + CGFloat($0) * 6, y: 120 + sin(CGFloat($0) / 4) * 20) }

    private func markedUpPDF() throws -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { ctx in
            ctx.beginPage()
            ("電子學 講義" as NSString).draw(at: CGPoint(x: 50, y: 50), withAttributes: nil)
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let drawing = PKDrawing(strokes: [ShapeRecognizer.makeStroke(points: strokePoints, ink: PKInk(.pen, color: .systemRed), width: 3, sample: nil)])
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("AKInkAnnotation2", for: FakeInk.self)
        archiver.encode(FakeInk(drawing: drawing.dataRepresentation(), size: pageSize), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        // 圖章的範圍是 PDF 座標（左下角是原點）
        let b = drawing.bounds
        let stamp = PDFAnnotation(bounds: CGRect(x: b.minX, y: pageSize.height - b.maxY, width: b.width, height: b.height), forType: .stamp, withProperties: nil)
        _ = stamp.setValue(["/AAPL:AKAnnotationV2": archiver.encodedData.base64EncodedString()] as NSDictionary,
                       forAnnotationKey: PDFMarkupImport.markupExtrasKey)
        page.addAnnotation(stamp)
        return pdf
    }

    private func assertSameStroke(_ d: PKDrawing?, file: StaticString = #filePath, line: UInt = #line) {
        guard let s = d?.strokes.first, d?.strokes.count == 1 else { return XCTFail("要有一筆筆跡", file: file, line: line) }
        let pts = s.path.map { $0.location.applying(s.transform) }
        XCTAssertEqual(pts.first?.x ?? .nan, strokePoints[0].x, accuracy: 0.5, "位置和「註記」畫的一樣（頁面左上角量起）", file: file, line: line)
        XCTAssertEqual(pts.first?.y ?? .nan, strokePoints[0].y, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(pts.last?.x ?? .nan, strokePoints[strokePoints.count - 1].x, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(s.ink.inkType, .pen, "還是原本的筆", file: file, line: line)
    }

    func testMarkupInkBecomesEditableStrokes() throws {
        let pdf = try markedUpPDF()
        let result = PDFMarkupImport.extractInk(from: pdf)
        assertSameStroke(result.drawings[0])
        XCTAssertTrue(pdf.page(at: 0)?.annotations.isEmpty ?? false, "圖章（2 倍大的點陣圖）拿掉，不會畫進頁面")
        XCTAssertTrue(result.changed)
    }

    func testImportingAMarkedUpPDF() throws {
        let url = work.appendingPathComponent("註記.pdf")
        XCTAssertTrue(try markedUpPDF().write(to: url))
        XCTAssertNotNil(PDFDocument(url: url)?.page(at: 0)?.annotations.first?.value(forAnnotationKey: PDFMarkupImport.markupExtrasKey),
                        "（存檔後還讀得到註記的資料）")
        let meta = try store.importPDF(from: url, folder: nil)
        created.append(meta.id)
        let session = try NotebookSession(id: meta.id)
        let page = session.document.pages[0]
        assertSameStroke(session.drawings[page.id])
        let pdf = try XCTUnwrap(session.pdfPage(for: page))
        XCTAssertTrue(pdf.annotations.isEmpty, "頁面背景裡沒有糊掉的圖章")
    }
}
