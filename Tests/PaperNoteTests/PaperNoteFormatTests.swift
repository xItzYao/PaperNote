import XCTest
import PencilKit
@testable import PaperNote

/// 匯出成 PaperNote 檔再匯入：內容一模一樣、筆跡可以繼續編輯
final class PaperNoteFormatTests: XCTestCase {
    private let store = LibraryStore.shared
    private var created: [UUID] = []
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("pn-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for id in created { store.deleteNotebook(id) }
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    /// 一本有 PDF 頁、紙張頁、PencilKit 筆跡、自製筆刷筆跡、圖片、螢光標示的筆記本
    private func richNotebook() throws -> NotebookSession {
        let pdfURL = work.appendingPathComponent("講義.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            ctx.beginPage()
            ("電子學 講義" as NSString).draw(at: CGPoint(x: 50, y: 50), withAttributes: nil)
        }.write(to: pdfURL)
        let meta = try store.importPDF(from: pdfURL, folder: nil)
        created.append(meta.id)
        let session = try NotebookSession(id: meta.id)
        session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid)))
        let p0 = session.document.pages[0].id
        session.document.pages[0].ink = [InkStroke(colorHex: "#1A1A1AFF", points: [InkPoint(CGPoint(x: 10, y: 10), width: 1),
                                                                                    InkPoint(CGPoint(x: 90, y: 40), width: 1)])]
        session.document.pages[0].highlights = [TextHighlight(rects: [CGRect(x: 40, y: 40, width: 100, height: 14)], colorHex: "#FFE600FF")]
        let img = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        let file = try XCTUnwrap(session.saveImage(img))
        session.document.pages[1].elements = [PageElement(frame: CGRect(x: 100, y: 100, width: 50, height: 50), content: .image(ImageData(file: file)))]
        let pts = (0..<20).map { CGPoint(x: 30 + CGFloat($0) * 4, y: 200 + CGFloat($0)) }
        session.drawings[p0] = PKDrawing(strokes: [ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current)])
        session.save()
        return session
    }

    func testRoundTripKeepsEverythingEditable() throws {
        let original = try richNotebook()
        let file = try NotebookExporter.exportPaperNote(session: original)
        XCTAssertEqual(file.pathExtension, "papernote")
        let meta = try store.importPaperNote(from: file, folder: nil)
        created.append(meta.id)

        XCTAssertNotEqual(meta.id, original.id, "匯入是一本新的筆記本")
        XCTAssertEqual(meta.title, original.title)
        XCTAssertEqual(meta.coverHex, store.notebook(original.id)?.coverHex)
        XCTAssertEqual(meta.pageCount, 2)
        let copy = try NotebookSession(id: meta.id)
        XCTAssertEqual(copy.document.pages, original.document.pages, "頁面、自製筆刷筆跡、物件、螢光標示都一樣")
        let p0 = original.document.pages[0].id
        XCTAssertEqual(copy.drawings[p0]?.dataRepresentation(), original.drawings[p0]?.dataRepresentation(), "PencilKit 筆跡可以繼續編輯")
        XCTAssertNotNil(copy.pdfPage(for: copy.document.pages[0]), "PDF 背景也帶過去")
        if case let .image(d) = copy.document.pages[1].elements.first?.content {
            XCTAssertNotNil(copy.image(named: d.file), "圖片也帶過去")
        } else {
            XCTFail("圖片物件不見了")
        }
    }

    func testRejectsFilesThatAreNotPaperNote() throws {
        let plain = work.appendingPathComponent("plain.papernote")
        var z = ZipWriter()
        try z.add("a.pdf", Data("x".utf8))
        try z.finish().write(to: plain)
        XCTAssertThrowsError(try store.importPaperNote(from: plain, folder: nil))

        let junk = work.appendingPathComponent("junk.papernote")
        try Data("hello".utf8).write(to: junk)
        XCTAssertThrowsError(try store.importPaperNote(from: junk, folder: nil))
    }

    /// 檔案裡的路徑不能跑到筆記本資料夾外面
    func testRejectsPathsOutsideTheNotebook() throws {
        let evil = work.appendingPathComponent("evil.papernote")
        var z = ZipWriter()
        try z.add("papernote.json", JSONEncoder.app.encode(PaperNoteManifest(title: "evil", coverHex: "#000000FF")))
        try z.add("notebook/../../evil.txt", Data("x".utf8))
        try z.finish().write(to: evil)
        let before = store.visibleNotebooks.count
        XCTAssertThrowsError(try store.importPaperNote(from: evil, folder: nil))
        XCTAssertEqual(store.visibleNotebooks.count, before, "失敗不能留下半本筆記本")
    }

    func testNewerFormatAsksToUpdate() throws {
        let newer = work.appendingPathComponent("newer.papernote")
        var m = PaperNoteManifest(title: "未來", coverHex: "#000000FF")
        m.format = PaperNoteManifest.currentFormat + 1
        var z = ZipWriter()
        try z.add("papernote.json", JSONEncoder.app.encode(m))
        try z.finish().write(to: newer)
        XCTAssertThrowsError(try store.importPaperNote(from: newer, folder: nil)) { error in
            XCTAssertEqual(error.localizedDescription, LibraryError.newerPaperNote.localizedDescription)
        }
    }

    func testZipWriterOutputIsReadable() throws {
        var z = ZipWriter()
        try z.add("資料夾/筆記.txt", Data("內容".utf8))
        let url = work.appendingPathComponent("w.zip")
        try z.finish().write(to: url)
        let archive = try ZipArchive(url: url)
        XCTAssertEqual(archive.entries.map(\.path), ["資料夾/筆記.txt"])
        XCTAssertEqual(try archive.contents(of: archive.entries[0]), Data("內容".utf8))
    }
}

/// 長按工具列的筆記本名稱改名
final class NotebookRenameTests: XCTestCase {
    func testRenameUpdatesLibraryLabelAndTabs() throws {
        let meta = LibraryStore.shared.createNotebook(title: "舊名稱", folder: nil, paper: .blank, landscape: false)
        defer { LibraryStore.shared.deleteNotebook(meta.id) }
        let editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        editor.loadViewIfNeeded()
        XCTAssertEqual(editor.notebookTitleLabel?.text, "舊名稱")
        let renamed = expectation(forNotification: .notebookRenamed, object: nil)
        editor.renameNotebook(to: "  電子學（二）期中  ")
        wait(for: [renamed], timeout: 1)
        XCTAssertEqual(LibraryStore.shared.notebook(meta.id)?.title, "電子學（二）期中")
        XCTAssertEqual(editor.notebookTitleLabel?.text, "電子學（二）期中")
        editor.renameNotebook(to: "   ")
        XCTAssertEqual(LibraryStore.shared.notebook(meta.id)?.title, "電子學（二）期中", "空白名稱不改")
    }
}
