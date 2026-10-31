import XCTest
@testable import PaperNote

/// 回報的問題：
/// 1. 選單蓋在選到的東西中間（套索、PDF 文字）
/// 2. 「PDF文字」工具作用不大，筆就可以選字（「選取」後來加回工具列）
/// 3. 選字範圍不對時每次都要重選，希望像 Android 一樣拖兩端的控制點調整
final class TextSelectionTests: XCTestCase {
    private final class FakePan: UIPanGestureRecognizer {
        var fake: UIGestureRecognizer.State = .possible
        var point: CGPoint = .zero
        override var state: UIGestureRecognizer.State {
            get { fake }
            set { fake = newValue }
        }
        override func location(in view: UIView?) -> CGPoint { point }
        override func translation(in view: UIView?) -> CGPoint { .zero }
    }

    private final class FakeTap: UITapGestureRecognizer {
        let point: CGPoint
        init(_ p: CGPoint) {
            point = p
            super.init(target: nil, action: nil)
        }
        override func location(in view: UIView?) -> CGPoint { point }
    }

    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var work: URL!

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let pdfURL = work.appendingPathComponent("講義.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            ctx.beginPage()
            ("Hello world this is a test sentence" as NSString)
                .draw(at: CGPoint(x: 50, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }.write(to: pdfURL)
        let meta = try LibraryStore.shared.importPDF(from: pdfURL, folder: nil)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        editor.setTool(.pen)
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    private func doc(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    /// 長按選字（筆模式下手指長按 PDF 文字）
    private func selectWord(at p: CGPoint) throws -> TextSelectionState {
        editor.setTool(.textSelect)
        editor.tapText(at: p)
        return try XCTUnwrap(editor.textSelection, "要選到字")
    }

    /// 第 i 個字在畫面上的範圍（文件座標）
    private func charRect(_ i: Int) throws -> CGRect {
        let pdf = try XCTUnwrap(editor.session.pdfPage(for: editor.pages[0]))
        let o = editor.contentOrigin(0)
        return pdf.characterBounds(at: i).applying(NotebookSession.displayTransform(for: pdf)).offsetBy(dx: o.x, dy: o.y)
    }

    /// 把控制點的直線拖到 x（手指按在圓點上，往右移 x - 直線的位置）
    private func dragHandle(_ h: TextHandle, toX x: CGFloat) throws {
        let ts = try XCTUnwrap(editor.textSelection)
        let bar = try XCTUnwrap(editor.textHandles(ts).first { $0.handle == h }).bar.0.x
        try dragHandle(h, by: x - bar)
    }

    private func dragHandle(_ h: TextHandle, by dx: CGFloat) throws {
        let ts = try XCTUnwrap(editor.textSelection)
        let knob = try XCTUnwrap(editor.textHandles(ts).first { $0.handle == h }).knob
        XCTAssertEqual(editor.textHandle(at: knob), h, "按在圓點上要抓到這一端")
        let g = FakePan(target: nil, action: nil)
        for (i, x) in [0, dx / 2, dx].enumerated() {
            g.point = CGPoint(x: knob.x + x, y: knob.y)
            g.fake = i == 0 ? .began : (i == 2 ? .ended : .changed)
            editor.handleTextHandlePan(g)
        }
    }

    func testMenuSitsAboveOrBelowTheSelection() throws {
        let ts = try selectWord(at: doc(60, 61))
        let bounds = ts.docRects.reduce(CGRect.null) { $0.union($1) }
        let target = editor.editMenuInteraction(editor.editMenu, targetRectFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero))
        let expected = editor.pagesContainer.convert(bounds, to: editor.canvas)
        XCTAssertEqual(target.minY, expected.minY, accuracy: 0.5, "選單要避開整個選取範圍，擺在上面或下面")
        XCTAssertEqual(target.height, expected.height, accuracy: 0.5)
    }

    func testToolbarHasSelectButNoTextTool() {
        XCTAssertNotNil(editor.toolButtons[.select], "「選取」加回工具列")
        XCTAssertNil(editor.toolButtons[.textSelect], "工具列不放「PDF文字」")
        XCTAssertNotNil(editor.toolButtons[.pen])
    }

    func testSelectToolStaysAfterTappingEmptySpace() {
        editor.setTool(.select)
        editor.handleTap(FakeTap(doc(300, 600)))
        XCTAssertEqual(editor.tool, .select, "從工具列選的「選取」不會自己切走")
    }

    /// 回報的問題：拖控制點時，選取的頭尾比手指的位置偏右。頭尾要停在手指旁邊最近的字縫
    func testEndHandleStopsAtTheGapNearestTheFinger() throws {
        _ = try selectWord(at: doc(60, 61))
        // "Hello world"：第 7 個字是 "o"。手指在 "o" 的左邊 1/4：結尾停在 "o" 前面
        let o = try charRect(7)
        try dragHandle(.end, toX: o.minX + o.width / 4)
        let ts = try XCTUnwrap(editor.textSelection)
        XCTAssertEqual(ts.text, "Hello w", "手指在字的左半邊，那個字不選")
        XCTAssertEqual(try XCTUnwrap(ts.docRects.last).maxX, o.minX, accuracy: 1.5, "結尾的控制點要在手指的位置")
    }

    func testStartHandleStopsAtTheGapNearestTheFinger() throws {
        _ = try selectWord(at: doc(60, 61))
        // 手指在 "e" 的右邊 3/4：開頭停在 "e" 後面
        let e = try charRect(1)
        try dragHandle(.start, toX: e.minX + e.width * 3 / 4)
        let ts = try XCTUnwrap(editor.textSelection)
        XCTAssertEqual(ts.text, "llo", "手指在字的右半邊，那個字不選")
        XCTAssertEqual(try XCTUnwrap(ts.docRects.first).minX, e.maxX, accuracy: 1.5, "開頭的控制點要在手指的位置")
    }

    func testSelectedWordHasHandlesAtBothEnds() throws {
        let ts = try selectWord(at: doc(60, 61))
        XCTAssertEqual(ts.text.trimmingCharacters(in: .whitespaces), "Hello")
        XCTAssertNotNil(ts.charRange)
        XCTAssertEqual(editor.textHandles(ts).map(\.handle), [.start, .end])
    }

    func testDraggingTheEndHandleExtendsTheSelection() throws {
        _ = try selectWord(at: doc(60, 61))
        try dragHandle(.end, by: 80)
        let text = try XCTUnwrap(editor.textSelection?.text)
        XCTAssertTrue(text.hasPrefix("Hello world"), "拖結尾的控制點要選到後面的字，選到：\(text)")
        XCTAssertNotNil(editor.pendingMenu, "放開後選單再出現")
    }

    func testDraggingTheStartHandleShrinksTheSelection() throws {
        _ = try selectWord(at: doc(60, 61))
        try dragHandle(.end, by: 80)
        let before = try XCTUnwrap(editor.textSelection?.text)
        try dragHandle(.start, by: 55)
        let after = try XCTUnwrap(editor.textSelection?.text)
        XCTAssertFalse(after.hasPrefix("Hello"), "拖開頭的控制點往右，前面的字要不見：\(after)")
        XCTAssertLessThan(after.count, before.count)
    }

    // MARK: 拖曳選字

    private let sentence = "Hello world this is a test sentence"

    /// 用筆從 a 拖到 b 選字（拖曳要先移動 slop 才開始）
    private func dragSelect(from a: CGPoint, to b: CGPoint, slop: CGPoint = .zero) throws -> String {
        editor.setTool(.textSelect)
        TouchPan().drag(from: a, to: b, slop: slop) { editor.handleToolPan($0) }
        return try XCTUnwrap(editor.textSelection?.text, "要選到字").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 回報的問題：拖曳選字常常選不到最後幾個字。筆停在最後一個字的右半邊（還沒超過字的右邊）就要選到那個字
    func testDragEndingOnTheLastCharacterSelectsIt() throws {
        let first = try charRect(0), last = try charRect(sentence.count - 1)
        let text = try dragSelect(from: CGPoint(x: first.minX + 1, y: first.midY),
                                  to: CGPoint(x: last.minX + last.width * 3 / 4, y: last.midY))
        XCTAssertEqual(text, sentence)
    }

    func testDragFromTheEndBackwardsSelectsTheLastCharacter() throws {
        let first = try charRect(0), last = try charRect(sentence.count - 1)
        let text = try dragSelect(from: CGPoint(x: last.minX + last.width * 3 / 4, y: last.midY),
                                  to: CGPoint(x: first.minX + 1, y: first.midY))
        XCTAssertEqual(text, sentence)
    }

    /// 拖曳要移動一小段才開始：開頭要用筆剛碰到的位置，不然第一個字也會漏掉
    func testDragStartsWhereThePenTouchedDown() throws {
        let first = try charRect(0), last = try charRect(sentence.count - 1)
        let text = try dragSelect(from: CGPoint(x: first.minX + 1, y: first.midY),
                                  to: CGPoint(x: last.maxX + 4, y: last.midY), slop: CGPoint(x: 14, y: 0))
        XCTAssertEqual(text, sentence)
    }

    func testDragEndingOnTheLeftHalfStopsBeforeThatCharacter() throws {
        let first = try charRect(0), w = try charRect(6)
        let text = try dragSelect(from: CGPoint(x: first.minX + 1, y: first.midY),
                                  to: CGPoint(x: w.minX + w.width / 4, y: w.midY))
        XCTAssertEqual(text, "Hello", "和拖控制點一樣：停在最近的字縫（w 不選）")
    }

    func testTappingElsewhereEndsTextSelectionAndReturnsToThePen() throws {
        _ = try selectWord(at: doc(60, 61))
        editor.handleTap(FakeTap(doc(300, 600)))
        XCTAssertNil(editor.textSelection)
        XCTAssertEqual(editor.tool, .pen, "選字結束要切回原本的筆")
    }
}
