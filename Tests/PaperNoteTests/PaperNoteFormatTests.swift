import XCTest
import PencilKit
import PDFKit
@testable import PaperNote

/// 匯出成 PaperNote 檔再匯入：內容一模一樣、筆跡可以繼續編輯
final class PaperNoteFormatTests: XCTestCase {
    private let store = LibraryStore.shared
    private var created: [UUID] = []
    private var folders: [UUID] = []
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("pn-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for id in created { store.deleteNotebook(id) }
        for id in folders { store.deleteFolder(id) }
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
        // 匯入到另一個資料夾（同一層有同名的會加上 (1)，見 testImportingANameThatIsTakenAddsANumber）
        let meta = try store.importPaperNote(from: file, folder: newFolder())
        created.append(meta.id)

        XCTAssertNotEqual(meta.id, original.id, "匯入是一本新的筆記本")
        XCTAssertEqual(meta.title, original.title)
        XCTAssertEqual(meta.coverHex, store.notebook(original.id)?.coverHex)
        XCTAssertEqual(meta.pageCount, 2)
        let copy = try NotebookSession(id: meta.id)
        XCTAssertEqual(copy.document.pages, original.document.pages, "頁面、自製筆刷筆跡、物件、螢光標示都一樣")
        let p0 = original.document.pages[0].id
        // 存在檔案裡的筆跡原封不動帶過去，讀出來是同樣的筆畫（可以繼續擦、移動）
        let file0 = "drawings/\(p0.uuidString).drawing"
        XCTAssertEqual(try Data(contentsOf: copy.directory.appendingPathComponent(file0)),
                       try Data(contentsOf: original.directory.appendingPathComponent(file0)))
        let a = try XCTUnwrap(original.drawings[p0]), b = try XCTUnwrap(copy.drawings[p0])
        XCTAssertEqual(b.strokes.count, a.strokes.count)
        XCTAssertEqual(b.strokes.first?.path.map(\.location), a.strokes.first?.path.map(\.location), "PencilKit 筆跡可以繼續編輯")
        XCTAssertNotNil(copy.pdfPage(for: copy.document.pages[0]), "PDF 背景也帶過去")
        if case let .image(d) = copy.document.pages[1].elements.first?.content {
            XCTAssertNotNil(copy.image(named: d.file), "圖片也帶過去")
        } else {
            XCTFail("圖片物件不見了")
        }
    }

    private func newFolder() -> UUID {
        let f = store.createFolder(name: "PaperNoteFormatTests \(UUID().uuidString.prefix(6))", parent: nil)
        folders.append(f.id)
        return f.id
    }

    /// 回報的需求：匯入時這個資料夾裡已經有同名的筆記本（UUID 不同，但使用者是看名稱的），後面加 (1)、(2)…
    func testImportingANameThatIsTakenAddsANumber() throws {
        let folder = newFolder()
        let pdfURL = work.appendingPathComponent("期中考.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { $0.beginPage() }.write(to: pdfURL)
        var titles: [String] = []
        for _ in 0..<3 {
            let m = try store.importPDF(from: pdfURL, folder: folder)
            created.append(m.id)
            titles.append(m.title)
        }
        XCTAssertEqual(titles, ["期中考", "期中考 (1)", "期中考 (2)"])

        let file = try NotebookExporter.exportPaperNote(session: try NotebookSession(id: created[0]))
        let again = try store.importPaperNote(from: file, folder: folder)
        created.append(again.id)
        XCTAssertEqual(again.title, "期中考 (3)", "PaperNote 檔也一樣")

        let elsewhere = try store.importPDF(from: pdfURL, folder: newFolder())
        created.append(elsewhere.id)
        XCTAssertEqual(elsewhere.title, "期中考", "只看同一個資料夾裡的名稱")
    }

    /// 回報的需求：匯出時選頁面，例如 7~10 或 1 3 5 6 7 這種不連續的
    func testPageSelection() throws {
        XCTAssertEqual(try PageSelection.parse("7-10", pageCount: 12), [6, 7, 8, 9])
        XCTAssertEqual(try PageSelection.parse("7~10", pageCount: 12), [6, 7, 8, 9])
        XCTAssertEqual(try PageSelection.parse("7～10", pageCount: 12), [6, 7, 8, 9], "全形的～")
        XCTAssertEqual(try PageSelection.parse("1 3 5 6 7", pageCount: 12), [0, 2, 4, 5, 6])
        XCTAssertEqual(try PageSelection.parse("１，３、5 - 6", pageCount: 12), [0, 2, 4, 5], "全形數字、逗號、頓號、空格")
        XCTAssertEqual(try PageSelection.parse("10-7 8 8", pageCount: 12), [6, 7, 8, 9], "倒過來、重複都可以")
        XCTAssertEqual(try PageSelection.parse("  ", pageCount: 3), [0, 1, 2], "空白＝全部")
        XCTAssertThrowsError(try PageSelection.parse("13", pageCount: 12), "超過頁數")
        XCTAssertThrowsError(try PageSelection.parse("0-2", pageCount: 12))
        XCTAssertThrowsError(try PageSelection.parse("a", pageCount: 12))
        XCTAssertThrowsError(try PageSelection.parse("1-2-3", pageCount: 12))
    }

    /// 只匯出選的頁面：PDF 只有這幾頁；PaperNote 檔匯入後也只有這幾頁，沒選的頁的筆跡不在檔案裡
    func testExportingChosenPages() throws {
        let meta = store.createNotebook(title: "選頁匯出", folder: newFolder(), paper: .blank, landscape: false)
        created.append(meta.id)
        let session = try NotebookSession(id: meta.id)
        while session.document.pages.count < 5 {
            session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid)))
        }
        for (i, p) in session.document.pages.enumerated() {
            let pts = (0..<10).map { CGPoint(x: 30 + CGFloat($0) * 4, y: 100 + CGFloat(i * 20)) }
            session.drawings[p.id] = PKDrawing(strokes: [ShapeRecognizer.makeStroke(points: pts, preset: BrushStore.shared.current)])
        }
        session.save()
        let ids = session.document.pages.map(\.id)
        let chosen = try PageSelection.parse("2 4-5", pageCount: 5)

        let pdfURL = try NotebookExporter.exportPDF(session: session, pages: chosen)
        XCTAssertEqual(PDFDocument(url: pdfURL)?.pageCount, 3, "PDF 只有選的三頁")

        let file = try NotebookExporter.exportPaperNote(session: session, pages: chosen)
        let entries = try ZipArchive(url: file).entries.map(\.path)
        XCTAssertFalse(entries.contains("notebook/drawings/\(ids[0].uuidString).drawing"), "沒選的頁的筆跡不帶")
        XCTAssertTrue(entries.contains("notebook/drawings/\(ids[1].uuidString).drawing"))
        let copy = try store.importPaperNote(from: file, folder: newFolder())
        created.append(copy.id)
        XCTAssertEqual(copy.pageCount, 3)
        let s = try NotebookSession(id: copy.id)
        XCTAssertEqual(s.document.pages.map(\.id), [ids[1], ids[3], ids[4]], "照順序只有選的頁")
        XCTAssertEqual(s.drawings[ids[3]]?.strokes.count, 1, "選的頁筆跡還在、可以編輯")

        let whole = try NotebookExporter.exportPDF(session: session, pages: try PageSelection.parse("", pageCount: 5))
        XCTAssertEqual(PDFDocument(url: whole)?.pageCount, 5, "沒填＝全部")
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
