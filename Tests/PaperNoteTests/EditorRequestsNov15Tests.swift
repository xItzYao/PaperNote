import XCTest
import PencilKit
@testable import PaperNote

/// 回報的需求：電路名稱打下標要切到符號鍵盤，鍵盤上面另外放一個「下標」鍵
final class SubscriptKeyTests: XCTestCase {
    func testTheKeyInsertsAnUnderscoreAtTheCursor() {
        let out = SubscriptKey.apply(to: "R", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(out.text, "R_")
        XCTAssertEqual(out.selection, NSRange(location: 2, length: 0), "接著打的字就是下標")
        let middle = SubscriptKey.apply(to: "V out", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(middle.text, "V_ out")
    }

    func testTheKeyTurnsTheSelectionIntoASubscript() {
        XCTAssertEqual(SubscriptKey.apply(to: "R1", selection: NSRange(location: 1, length: 1)).text, "R_1", "一個字不用大括號")
        let out = SubscriptKey.apply(to: "Vin", selection: NSRange(location: 1, length: 2))
        XCTAssertEqual(out.text, "V_{in}", "好幾個字包在大括號裡")
        XCTAssertEqual(out.selection.location, 6, "游標在下標後面")
        XCTAssertEqual(CircuitText.runs("V_{in}"), [CircuitText.Run(text: "V", script: .normal), CircuitText.Run(text: "in", script: .sub)], "畫出來是 V 加上下標 in")
    }

    func testTheKeySitsAboveTheKeyboard() throws {
        let field = UITextField()
        field.text = "R"
        SubscriptKey.install(on: field)
        let bar = try XCTUnwrap(field.inputAccessoryView, "鍵盤上面有一排按鍵")
        let key = try XCTUnwrap(bar.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == SubscriptKey.accessibilityID })
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(field.text?.filter { $0 == "_" }.count, 1, "按一下打出一個下標記號：\(field.text ?? "")")
    }
}

/// 回報的問題：電壓源旋轉後裡面的 − 變成 |。訊號源裡的記號、字位置跟著轉，形狀永遠是正的
final class CircuitUprightMarksTests: XCTestCase {
    /// 符號上的線段（電路圖座標）與所有路徑上的點
    private func geometry(_ c: CircuitComponent) -> (segments: [(CGPoint, CGPoint)], points: [CGPoint]) {
        let (s, _) = CircuitRenderer.symbol(c)
        let t = CircuitGeometry.transform(c)
        var segs: [(CGPoint, CGPoint)] = []
        var pts: [CGPoint] = []
        var cur = CGPoint.zero
        s.cgPath.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                cur = e.points[0].applying(t)
                pts.append(cur)
            case .addLineToPoint:
                let p = e.points[0].applying(t)
                segs.append((cur, p))
                cur = p
                pts.append(p)
            case .addQuadCurveToPoint:
                cur = e.points[1].applying(t)
                pts.append(cur)
            case .addCurveToPoint:
                cur = e.points[2].applying(t)
                pts.append(cur)
            default:
                break
            }
        }
        return (segs, pts)
    }

    private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { a.distance(to: b) < 0.01 }

    private func has(_ segs: [(CGPoint, CGPoint)], _ a: CGPoint, _ b: CGPoint) -> Bool {
        segs.contains { (near($0.0, a) && near($0.1, b)) || (near($0.0, b) && near($0.1, a)) }
    }

    private func component(_ part: CircuitPart, rotation: Int, flipH: Bool = false, flipV: Bool = false) -> CircuitComponent {
        var c = CircuitComponent(part: part, position: CGPoint(x: 100, y: 100))
        c.rotation = rotation
        c.flipH = flipH
        c.flipV = flipV
        return c
    }

    private func checkSigns(_ part: CircuitPart, plus: CGPoint, minus: CGPoint, r: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        for rotation in [0, 90, 180, 270] {
            for (fh, fv) in [(false, false), (true, false), (false, true)] {
                let c = component(part, rotation: rotation, flipH: fh, flipV: fv)
                let t = CircuitGeometry.transform(c)
                let g = geometry(c).segments
                let m = minus.applying(t), p = plus.applying(t)
                let name = "\(part) 轉 \(rotation)° 翻轉 \(fh)/\(fv)"
                XCTAssertTrue(has(g, CGPoint(x: m.x - r, y: m.y), CGPoint(x: m.x + r, y: m.y)), "\(name)：− 還是橫的", file: file, line: line)
                XCTAssertFalse(has(g, CGPoint(x: m.x, y: m.y - r), CGPoint(x: m.x, y: m.y + r)), "\(name)：− 不會變成 |", file: file, line: line)
                XCTAssertTrue(has(g, CGPoint(x: p.x - r, y: p.y), CGPoint(x: p.x + r, y: p.y)), "\(name)：+ 的橫", file: file, line: line)
                XCTAssertTrue(has(g, CGPoint(x: p.x, y: p.y - r), CGPoint(x: p.x, y: p.y + r)), "\(name)：+ 的直", file: file, line: line)
            }
        }
    }

    func testVoltageSourceSignsStayUpright() {
        checkSigns(.voltageSource, plus: CGPoint(x: -7, y: 0), minus: CGPoint(x: 7, y: 0), r: 4)
        checkSigns(.controlledVoltageSource, plus: CGPoint(x: -7, y: 0), minus: CGPoint(x: 7, y: 0), r: 4)
    }

    func testOpAmpSignsStayUpright() {
        checkSigns(.opAmp, plus: CGPoint(x: -17, y: 20), minus: CGPoint(x: -17, y: -20), r: 3)
    }

    func testWaveformsStayHorizontal() {
        for part in [CircuitPart.sineSource, .squareSource] {
            for rotation in [90, 270] {
                let pts = geometry(component(part, rotation: rotation)).points
                let ends = part == .sineSource ? [CGPoint(x: 91, y: 100), CGPoint(x: 109, y: 100)] : [CGPoint(x: 91, y: 105), CGPoint(x: 109, y: 105)]
                for e in ends {
                    XCTAssertTrue(pts.contains { near($0, e) }, "\(part) 轉 \(rotation)°：波形還是橫的，從左畫到右")
                }
            }
        }
    }

    func testThePolarityStillFollowsTheRotation() {
        // + 跟著元件轉到下面（轉 90°：本來左邊的 + 到了上面…位置跟著轉，形狀是正的）
        let c = component(.voltageSource, rotation: 90)
        let p = CGPoint(x: -7, y: 0).applying(CircuitGeometry.transform(c))
        XCTAssertEqual(p.x, 100, accuracy: 0.01)
        XCTAssertEqual(p.y, 93, accuracy: 0.01)
        XCTAssertTrue(has(geometry(c).segments, CGPoint(x: 100, y: 89), CGPoint(x: 100, y: 97)), "+ 在轉過去的位置")
    }
}

/// 回報的需求：狀態列不跳到第一頁、拿掉「選取」、套索照圈的形狀、貼紙
final class EditorRequestsNov15Tests: XCTestCase {
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
    private var inkID: UUID!
    private var addedStickers: [UUID] = []

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "Nov15Test", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // 頁面上有一筆字（頁面內容座標 100…200, 300）
        let ink = InkStroke(colorHex: "#1A1A1AFF", points: (0...10).map { InkPoint(CGPoint(x: 100 + CGFloat($0) * 10, y: 300), width: 2) })
        inkID = ink.id
        editor.updatePage(0, undoable: false) { $0.ink = [ink] }
        editor.setTool(.lasso)
    }

    override func tearDown() {
        for id in addedStickers { StickerStore.shared.remove(id) }
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func doc(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// 有透明邊的紅色方塊（貼紙的樣子）
    private func redSquare(margin: CGFloat = 10, side: CGFloat = 60) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side + margin * 2, height: side + margin * 2), format: fmt).image { _ in
            UIColor.red.setFill()
            UIRectFill(CGRect(x: margin, y: margin, width: side, height: side))
        }
    }

    // MARK: 狀態列

    func testTappingTheStatusBarDoesNotJumpToTheFirstPage() {
        XCTAssertFalse(editor.canvas.scrollsToTop, "點狀態列不能捲回最上面（常常誤觸）")
    }

    // MARK: 拿掉選取工具：套索就能選

    func testTheToolbarHasStickersButNoSelect() {
        let tools = NotebookViewController.toolbarTools.map(\.0)
        XCTAssertFalse(tools.contains(.select), "「選取」和套索重複，拿掉")
        XCTAssertTrue(tools.contains(.sticker), "工具列有「貼紙」")
        XCTAssertNil(editor.toolButtons[.select])
        XCTAssertNotNil(editor.toolButtons[.sticker])
    }

    func testTappingAnObjectWithTheLassoSelectsIt() throws {
        editor.insertImage(redSquare(margin: 0, side: 120), jpeg: false, at: doc(300, 500))
        let e = try XCTUnwrap(editor.pages[0].elements.last)
        editor.setTool(.lasso)
        let o = editor.contentOrigin(0)
        editor.handleTap(FakeTap(CGPoint(x: o.x + e.frame.midX, y: o.y + e.frame.midY)))
        XCTAssertEqual(editor.selected, ElementRef(pageID: editor.pages[0].id, elementID: e.id), "點一下圖片就選起來")
        XCTAssertEqual(editor.toolButtons[.lasso]?.configuration?.baseForegroundColor, .systemBlue, "選著物件時工具列亮著套索")
    }

    func testTappingAStrokeWithTheLassoSelectsIt() {
        editor.handleTap(FakeTap(doc(150, 300)))
        XCTAssertEqual(editor.lassoSel?.ink.map(\.id), [inkID], "點一下筆跡就選起來")
        XCTAssertEqual(editor.tool, .lasso, "選筆跡還是在套索")
        editor.handleTap(FakeTap(doc(400, 700)))
        XCTAssertNil(editor.lassoSel, "點空白處取消")
    }

    // MARK: 套索照圈的形狀

    private func lasso(_ pts: [CGPoint]) {
        let g = TouchPan()
        for (i, p) in pts.enumerated() {
            g.fake = i == 0 ? .began : (i == pts.count - 1 ? .ended : .changed)
            editor.handleLassoPan(g, p)
        }
    }

    /// 圈得比筆跡大很多的三角形
    private var triangle: [CGPoint] { [doc(20, 450), doc(150, 150), doc(300, 450), doc(22, 448)] }

    func testTheSelectionKeepsTheShapeThatWasDrawn() throws {
        lasso(triangle)
        let sel = try XCTUnwrap(editor.lassoSel, "圈到那一筆")
        XCTAssertEqual(sel.outline, triangle, "記住圈的形狀")
        let path = try XCTUnwrap(editor.overlay.lassoSelLayer.path)
        let box = path.boundingBoxOfPath
        let drawn = InkShapes.bounds(triangle)
        XCTAssertEqual(box.minY, drawn.minY, accuracy: 0.5, "選取框照圈的形狀，不縮成筆跡的外框")
        XCTAssertEqual(box.width, drawn.width, accuracy: 0.5)
        XCTAssertFalse(path.contains(doc(70, 230)), "三角形外面的角落不算選取框")
        XCTAssertFalse(sel.contains(doc(70, 230), margin: 2), "也點不到")
        // 點在圈的範圍裡（離筆跡很遠）也打開選單
        editor.handleTap(FakeTap(doc(150, 400)))
        XCTAssertNotNil(editor.pendingMenu, "點圈的範圍裡打開選單")
    }

    func testTheDrawnShapeMovesWithTheSelection() throws {
        lasso(triangle)
        TouchPan().drag(from: doc(150, 380), to: doc(190, 430)) { editor.handleLassoPan($0, $0.point) }
        let sel = try XCTUnwrap(editor.lassoSel)
        let moved = try XCTUnwrap(sel.outline)
        XCTAssertEqual(moved[1].x, triangle[1].x + 40, accuracy: 0.5, "圈的形狀跟著移動")
        XCTAssertEqual(moved[1].y, triangle[1].y + 50, accuracy: 0.5)
        let ink = try XCTUnwrap(editor.pages[0].ink.first)
        XCTAssertEqual(ink.points[0].point.y, 350, accuracy: 0.01, "筆跡也移動了")
    }

    func testTappedSelectionsStillUseABox() throws {
        editor.handleTap(FakeTap(doc(150, 300)))
        let sel = try XCTUnwrap(editor.lassoSel)
        XCTAssertNil(sel.outline, "點選的沒有圈的形狀")
        XCTAssertEqual(sel.frame, sel.bounds)
    }

    // MARK: 貼紙

    func testTheStickerStoreKeepsStickersAcrossLaunches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stickers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StickerStore(directory: dir)
        let a = try XCTUnwrap(store.add(redSquare()))
        let b = try XCTUnwrap(store.add(redSquare()))
        XCTAssertEqual(store.stickers.map(\.id), [b.id, a.id], "新做的排最前面")
        let reopened = StickerStore(directory: dir)
        XCTAssertEqual(reopened.stickers.map(\.id), [b.id, a.id], "重新打開 App 還在")
        XCTAssertNotNil(reopened.image(for: a))
        reopened.remove(a.id)
        XCTAssertEqual(StickerStore(directory: dir).stickers.map(\.id), [b.id])
    }

    func testTransparentEdgesAreTrimmed() throws {
        let out = StickerMaker.trimmedTransparentEdges(redSquare(margin: 10, side: 60))
        let cg = try XCTUnwrap(out.cgImage)
        XCTAssertEqual(cg.width, 60)
        XCTAssertEqual(cg.height, 60)
    }

    func testAnImageWithoutASubjectStillBecomesASticker() {
        let out = StickerMaker.makeSticker(from: redSquare(margin: 0, side: 80))
        XCTAssertGreaterThan(out.size.width, 0)
        XCTAssertGreaterThan(out.size.height, 0)
    }

    func testTappingAStickerPutsItOnThePage() throws {
        let s = try XCTUnwrap(StickerStore.shared.add(redSquare(margin: 0, side: 300)))
        addedStickers.append(s.id)
        editor.setTool(.sticker)
        let views = editor.subBarStack.arrangedSubviews
        XCTAssertTrue(views.contains { $0.accessibilityLabel == "加貼紙" }, "第二列有 ＋")
        XCTAssertNotNil(findView(id: "sticker.\(s.id.uuidString)", in: editor.subBarStack), "第二列有這張貼紙")
        let before = editor.pages[0].elements.count
        let ref = try XCTUnwrap(editor.placeSticker(s))
        XCTAssertEqual(editor.pages[0].elements.count, before + 1)
        let e = try XCTUnwrap(editor.pages[0].elements.first { $0.id == ref.elementID })
        guard case let .image(d) = e.content else { return XCTFail("貼紙是圖片") }
        XCTAssertTrue(d.file.hasSuffix(".png"), "存成 PNG，背景透明")
        XCTAssertEqual(max(e.frame.width, e.frame.height), NotebookViewController.stickerSide, accuracy: 1)
        XCTAssertEqual(editor.tool, .sticker, "留在貼紙工具，可以接著貼")
        let second = try XCTUnwrap(editor.placeSticker(s))
        let e2 = try XCTUnwrap(editor.pages[0].elements.first { $0.id == second.elementID })
        XCTAssertNotEqual(e2.frame.origin, e.frame.origin, "連續貼往旁邊錯開")
    }

    func testAnImageOnThePageCanBecomeASticker() throws {
        editor.insertImage(redSquare(margin: 0, side: 120), jpeg: false, at: doc(300, 500))
        let e = try XCTUnwrap(editor.pages[0].elements.last)
        let ref = ElementRef(pageID: editor.pages[0].id, elementID: e.id)
        let titles = editor.elementMenu(ref, at: doc(300, 500)).children.map(\.title)
        XCTAssertTrue(titles.contains("變成貼紙"), "圖片的選單有「變成貼紙」：\(titles)")
        let count = StickerStore.shared.stickers.count
        let done = expectation(description: "貼紙做好")
        editor.makeStickers(from: [redSquare()]) { done.fulfill() }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(StickerStore.shared.stickers.count, count + 1, "加進貼紙")
        if let s = StickerStore.shared.stickers.first { addedStickers.append(s.id) }
    }

    private func findView(id: String, in v: UIView) -> UIView? {
        if v.accessibilityIdentifier == id { return v }
        for s in v.subviews { if let f = findView(id: id, in: s) { return f } }
        return nil
    }
}
