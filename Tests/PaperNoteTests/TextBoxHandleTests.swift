import XCTest
@testable import PaperNote

/// 回報的需求：選到文字框，上下左右各一個把手拉大縮小框；右下角的把手是字和框一起等比例縮放
final class TextBoxHandleTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var ref: ElementRef!
    private let start = CGRect(x: 100, y: 120, width: 200, height: 60)

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "TextBoxHandleTests", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        let e = PageElement(frame: start, content: .text(TextBoxData(text: "電子學", fontSize: 18)))
        session.document.pages[0].elements = [e]
        session.save()
        ref = ElementRef(pageID: session.document.pages[0].id, elementID: e.id)
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        editor.setTool(.select)
        editor.select(ref)
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private var element: PageElement { editor.pages[0].elements[0] }
    private var box: TextBoxData? { if case let .text(t) = element.content { return t }; return nil }
    private var docRect: CGRect { editor.docFrame(of: element, pageIndex: 0) }

    private func drag(from p: CGPoint, by d: CGPoint) {
        TouchPan().drag(from: p, to: CGPoint(x: p.x + d.x, y: p.y + d.y)) { editor.handleElementPan($0, $0.location(in: nil)) }
    }

    func testTheFourEdgeHandlesShow() {
        let r = docRect
        let expected: [BoxEdge: CGPoint] = [.top: CGPoint(x: r.midX, y: r.minY), .bottom: CGPoint(x: r.midX, y: r.maxY),
                                            .left: CGPoint(x: r.minX, y: r.midY), .right: CGPoint(x: r.maxX, y: r.midY)]
        for (side, p) in expected {
            let l = editor.overlay.edgeHandles[side]!
            XCTAssertFalse(l.isHidden, "\(side) 有把手")
            XCTAssertEqual(l.frame.midX, p.x, accuracy: 0.5)
            XCTAssertEqual(l.frame.midY, p.y, accuracy: 0.5)
            guard case .edge(side)? = editor.dragTarget(at: p)?.1 else { return XCTFail("按在 \(side) 的把手上拉那一邊") }
        }
        XCTAssertFalse(editor.overlay.resizeHandleImage.isHidden, "右下角還是縮放")
        guard case .resize? = editor.dragTarget(at: CGPoint(x: r.maxX, y: r.maxY))?.1 else { return XCTFail("右下角是等比例縮放") }

        editor.select(nil)
        XCTAssertTrue(editor.overlay.edgeHandles.values.allSatisfy(\.isHidden), "沒選東西就不顯示")
    }

    func testEdgeHandlesResizeOnlyThatSide() {
        var r = docRect
        drag(from: CGPoint(x: r.maxX, y: r.midY), by: CGPoint(x: 50, y: 30))
        XCTAssertEqual(element.frame, CGRect(x: start.minX, y: start.minY, width: start.width + 50, height: start.height), "右邊：只變寬")

        r = docRect
        drag(from: CGPoint(x: r.minX, y: r.midY), by: CGPoint(x: -30, y: 0))
        XCTAssertEqual(element.frame.minX, start.minX - 30, accuracy: 0.01, "左邊：左緣跟著動")
        XCTAssertEqual(element.frame.maxX, start.maxX + 50, accuracy: 0.01, "右緣不動")

        r = docRect
        drag(from: CGPoint(x: r.midX, y: r.maxY), by: CGPoint(x: 20, y: 40))
        XCTAssertEqual(element.frame.height, start.height + 40, accuracy: 0.01, "下面：只變高")
        XCTAssertEqual(element.frame.minY, start.minY, accuracy: 0.01)

        r = docRect
        drag(from: CGPoint(x: r.midX, y: r.minY), by: CGPoint(x: 0, y: -20))
        XCTAssertEqual(element.frame.minY, start.minY - 20, accuracy: 0.01, "上面：上緣跟著動")
        XCTAssertEqual(element.frame.maxY, start.maxY + 40, accuracy: 0.01, "下緣不動")
        XCTAssertEqual(box?.fontSize, 18, "拉邊不改字的大小")

        r = docRect
        drag(from: CGPoint(x: r.midX, y: r.minY), by: CGPoint(x: 0, y: 500))
        XCTAssertGreaterThanOrEqual(element.frame.height, 28, "不會拉到沒有高度")
    }

    func testTheCornerScalesTextAndBoxTogether() throws {
        let r = docRect
        // 往右下拉對角線的一半：框和字都變成 1.5 倍
        drag(from: CGPoint(x: r.maxX, y: r.maxY), by: CGPoint(x: start.width / 2, y: start.height / 2))
        XCTAssertEqual(element.frame.width, start.width * 1.5, accuracy: 0.5)
        XCTAssertEqual(element.frame.height, start.height * 1.5, accuracy: 0.5)
        XCTAssertEqual(element.frame.origin, start.origin, "左上角不動")
        XCTAssertEqual(try XCTUnwrap(box).fontSize, 27, accuracy: 0.01, "字跟著框等比例放大")

        let r2 = docRect
        drag(from: CGPoint(x: r2.maxX, y: r2.maxY), by: CGPoint(x: -2000, y: -2000))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(box).fontSize, NotebookViewController.textSizeRange.lowerBound, "縮到最小字級為止")
        XCTAssertEqual(element.frame.width / element.frame.height, start.width / start.height, accuracy: 0.01, "還是同樣的比例")
    }
}
