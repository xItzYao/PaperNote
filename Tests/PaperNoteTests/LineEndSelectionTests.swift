import XCTest
import PDFKit
@testable import PaperNote

/// 回報的問題：用 macOS 列印出來的講義，拖曳選字選不到每一行最後的字（要拖到下一行才選得到）
final class LineEndSelectionTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let pdfURL = work.appendingPathComponent("printed.pdf")
        try PrintedPDF.data().write(to: pdfURL)
        let meta = try LibraryStore.shared.importPDF(from: pdfURL, folder: nil)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        editor.setTool(.textSelect)
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    /// 一行字頭、字尾在畫面上的範圍（文件座標）
    private func ends(of line: String) throws -> (first: CGRect, last: CGRect) {
        let pdf = try XCTUnwrap(editor.session.pdfPage(for: editor.pages[0]))
        let r = ((pdf.string ?? "") as NSString).range(of: line)
        XCTAssertNotEqual(r.location, NSNotFound, "PDF 的文字：\(pdf.string ?? "nil")")
        let o = editor.contentOrigin(0)
        func rect(_ i: Int) -> CGRect {
            pdf.characterBounds(at: i).applying(NotebookSession.displayTransform(for: pdf)).offsetBy(dx: o.x, dy: o.y)
        }
        return (rect(r.location), rect(r.location + r.length - 1))
    }

    private func drag(from a: CGPoint, to b: CGPoint) throws -> String {
        TouchPan().drag(from: a, to: b) { editor.handleToolPan($0) }
        return try XCTUnwrap(editor.textSelection?.text, "要選到字").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testLastCharacterOfEachLineHasItsOwnBox() throws {
        for line in PrintedPDF.lines {
            let e = try ends(of: line)
            XCTAssertGreaterThan(e.last.width, 1, "\(line) 最後一個字的範圍：\(e.last)")
        }
    }

    func testDragOntoTheLastCharacterSelectsIt() throws {
        for line in PrintedPDF.lines {
            let e = try ends(of: line)
            let text = try drag(from: CGPoint(x: e.first.minX + 1, y: e.first.midY),
                                to: CGPoint(x: e.last.minX + e.last.width * 3 / 4, y: e.last.midY))
            XCTAssertEqual(text, line, "筆停在最後一個字的右半邊")
        }
    }

    func testDragPastTheEndOfTheLineSelectsTheLastCharacter() throws {
        for line in PrintedPDF.lines {
            let e = try ends(of: line)
            let text = try drag(from: CGPoint(x: e.first.minX + 1, y: e.first.midY),
                                to: CGPoint(x: e.last.maxX + 15, y: e.last.midY))
            XCTAssertEqual(text, line, "筆拖過行尾")
        }
    }

    /// 拖結尾的控制點到行尾外面：最後一個字也要選到
    func testEndHandlePastTheLineEndTakesTheLastCharacter() throws {
        let line = PrintedPDF.lines[0]
        let e = try ends(of: line)
        _ = try drag(from: CGPoint(x: e.first.minX + 1, y: e.first.midY), to: CGPoint(x: e.first.maxX + 30, y: e.first.midY))
        let ts = try XCTUnwrap(editor.textSelection)
        let knob = try XCTUnwrap(editor.textHandles(ts).first { $0.handle == .end }).knob
        let g = TouchPan()
        g.drag(from: knob, to: CGPoint(x: e.last.maxX + 20, y: knob.y)) { _ in editor.handleTextHandlePan(g) }
        XCTAssertEqual(editor.textSelection?.text.trimmingCharacters(in: .whitespacesAndNewlines), line)
    }
}
