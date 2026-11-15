import XCTest
import PencilKit
@testable import PaperNote

/// 回報的需求：電路名稱的下標像 Desmos：打 _ 就直接在下面的框裡打字，不用寫 R_1；可以勾「純文字」切回 R_1 的寫法
final class CircuitNameEditorTests: XCTestCase {
    private var savedPlain: Any?

    override func setUp() {
        savedPlain = UserDefaults.standard.object(forKey: CircuitNameEditorViewController.plainDefaultsKey)
        UserDefaults.standard.set(false, forKey: CircuitNameEditorViewController.plainDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedPlain, forKey: CircuitNameEditorViewController.plainDefaultsKey)
    }

    private func editor(_ text: String = "") -> CircuitNameEditorViewController {
        let vc = CircuitNameEditorViewController(title: "元件名稱", text: text, placeholder: "R1")
        vc.view.frame = CGRect(x: 0, y: 0, width: 540, height: 400)
        vc.view.layoutIfNeeded()
        return vc
    }

    func testTypingAnUnderscoreMovesIntoTheSubscript() {
        let vc = editor()
        vc.type("R")
        vc.type("_")
        XCTAssertEqual(vc.mode, .sub, "打 _ 進到下標的框")
        XCTAssertEqual(vc.textView.text, "R", "_ 不會出現在字裡")
        vc.type("12")
        XCTAssertEqual(vc.value, "R_12", "好幾個字的下標（後面沒字不用大括號）")
        vc.type(" ")
        XCTAssertEqual(vc.mode, .normal, "空白回到一般的字")
        vc.type("x")
        XCTAssertEqual(vc.value, "R_{12}x")
        XCTAssertEqual(CircuitText.runs(vc.value).map(\.script), [.normal, .sub, .normal])
    }

    func testTheButtonsSwitchBetweenSubscriptAndNormalText() {
        let vc = editor()
        vc.type("V")
        vc.subButton.sendActions(for: .touchUpInside)
        vc.type("in")
        vc.exitButton.sendActions(for: .touchUpInside)
        vc.type("+")
        XCTAssertEqual(vc.value, "V_in+")
        vc.supButton.sendActions(for: .touchUpInside)
        vc.type("2")
        XCTAssertEqual(vc.value, "V_in+^2")
    }

    func testExistingNamesShowAsSubscripts() {
        let vc = editor("R_1")
        XCTAssertEqual(vc.textView.text, "R1", "看到的是 R 加上下標 1，不是 R_1")
        XCTAssertEqual(vc.mode, .sub, "游標在下標後面，接著打還是下標")
        XCTAssertEqual(vc.value, "R_1")
        vc.type("0")
        XCTAssertEqual(vc.value, "R_10")
    }

    func testAPlainTextModeShowsTheRawSyntax() {
        let vc = editor("V_{out}")
        vc.plainToggle.sendActions(for: .touchUpInside)
        XCTAssertTrue(vc.plain)
        XCTAssertEqual(vc.textView.text, "V_out", "純文字：直接看到寫法")
        vc.type("_")
        XCTAssertEqual(vc.textView.text, "V_out_", "純文字模式打 _ 就是 _")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: CircuitNameEditorViewController.plainDefaultsKey), "下次也用純文字")
        vc.plainToggle.sendActions(for: .touchUpInside)
        XCTAssertFalse(vc.plain)
        XCTAssertEqual(vc.textView.text, "Vout_", "切回來又是下標的樣子")
    }

    func testThePreviewIsLarge() {
        let vc = editor("R_1")
        XCTAssertGreaterThanOrEqual(vc.textView.bounds.height, 120, "預覽的框放大")
        XCTAssertGreaterThanOrEqual(CircuitNameEditorViewController.fontSize, 40)
        let font = vc.textView.attributedText.attribute(.font, at: 1, effectiveRange: nil) as? UIFont
        XCTAssertGreaterThanOrEqual(font?.pointSize ?? 0, 28, "下標在 iPad 上也夠大")
    }

    func testSerializingKeepsBracesWhenTheNextLetterWouldJoin() {
        let s = NSMutableAttributedString(attributedString: CircuitNameEditorViewController.rich("R_1"))
        s.append(NSAttributedString(string: "2", attributes: CircuitNameEditorViewController.attributes(.normal)))
        XCTAssertEqual(CircuitNameEditorViewController.serialize(s), "R_{1}2", "後面接著英數字要用大括號，不然 2 也變下標")
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
    private var addedCategories: [UUID] = []

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
        for id in addedCategories { StickerStore.shared.removeCategory(id) }
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

    // MARK: 截圖的分享

    /// 回報的需求：截圖的「分享」不要藏到第二頁（選單列放不下時後面的會收到下一頁）
    func testShareIsFirstInTheCaptureMenu() {
        let titles = editor.captureMenu(redSquare(), viewRect: CGRect(x: 100, y: 100, width: 80, height: 80)).children.map(\.title)
        XCTAssertEqual(titles.first, "分享…", "分享放最前面：\(titles)")
        XCTAssertEqual(Set(titles), ["分享…", "釘選在畫面上", "拷貝", "翻譯文字", "拷貝文字", "存到照片"], "其他的都還在")
    }

    private func capture(from a: CGPoint, to b: CGPoint) {
        TouchPan().drag(from: a, to: b) { editor.handleCapturePan($0, $0.point) }
    }

    /// 回報的需求：截圖的範圍要有錨點可以調整大小
    func testTheCaptureRegionHasHandlesToResizeIt() throws {
        editor.setTool(.capture)
        capture(from: doc(100, 100), to: doc(300, 250))
        let r0 = try XCTUnwrap(editor.captureRegion).bounds
        XCTAssertEqual(r0.width, 200, accuracy: 0.5)
        XCTAssertEqual(editor.overlay.captureHandleLayer.path?.boundingBox.isEmpty, false, "畫出錨點")
        XCTAssertNotNil(editor.pendingMenu)
        editor.pendingMenu = nil

        // 拉右下角：左上角不動
        capture(from: CGPoint(x: r0.maxX, y: r0.maxY), to: CGPoint(x: r0.maxX + 100, y: r0.maxY + 50))
        let r1 = try XCTUnwrap(editor.captureRegion).bounds
        XCTAssertEqual(r1.minX, r0.minX, accuracy: 0.5, "左上角不動")
        XCTAssertEqual(r1.minY, r0.minY, accuracy: 0.5)
        XCTAssertEqual(r1.maxX, r0.maxX + 100, accuracy: 0.5)
        XCTAssertEqual(r1.maxY, r0.maxY + 50, accuracy: 0.5)
        XCTAssertNotNil(editor.pendingMenu, "調整完再跳出選單")

        // 拉左邊中間：只動左邊
        capture(from: CGPoint(x: r1.minX, y: r1.midY), to: CGPoint(x: r1.minX + 30, y: r1.midY + 40))
        let r2 = try XCTUnwrap(editor.captureRegion).bounds
        XCTAssertEqual(r2.minX, r1.minX + 30, accuracy: 0.5)
        XCTAssertEqual(r2.minY, r1.minY, accuracy: 0.5, "上下不動")
        XCTAssertEqual(r2.maxY, r1.maxY, accuracy: 0.5)
        XCTAssertEqual(r2.maxX, r1.maxX, accuracy: 0.5)

        // 框裡拖：整個移動
        capture(from: CGPoint(x: r2.midX, y: r2.midY), to: CGPoint(x: r2.midX + 20, y: r2.midY + 10))
        let r3 = try XCTUnwrap(editor.captureRegion).bounds
        XCTAssertEqual(r3.origin.x, r2.origin.x + 20, accuracy: 0.5)
        XCTAssertEqual(r3.size.width, r2.size.width, accuracy: 0.5, "移動不改大小")

        // 框外拖：重新截一個
        capture(from: doc(100, 600), to: doc(170, 680))
        XCTAssertEqual(try XCTUnwrap(editor.captureRegion).bounds.width, 70, accuracy: 0.5)

        // 點框外：取消
        editor.handleTap(FakeTap(doc(400, 400)))
        XCTAssertNil(editor.captureRegion)
        XCTAssertNil(editor.overlay.captureHandleLayer.path)
    }

    /// 回報的問題：截圖的分享視窗只畫出一半（指著很大的範圍，沒有地方放）
    func testTheShareSheetPointsAtASpotOnScreen() {
        let huge = editor.view.bounds.insetBy(dx: -50, dy: -50)
        let a = editor.captureAnchor(huge)
        XCTAssertEqual(a.size, CGSize(width: 1, height: 1), "指著一點，不是整個範圍")
        XCTAssertTrue(editor.view.bounds.insetBy(dx: 10, dy: 10).contains(a.origin), "在畫面裡")
        let small = CGRect(x: 300, y: 400, width: 100, height: 80)
        XCTAssertEqual(editor.captureAnchor(small).origin, CGPoint(x: 350, y: 400), "範圍上緣中間")
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

    /// 回報的問題：加入表格後套索沒反應。點表格會選起來（換到看不到的「選取」，工具列上亮著套索），
    /// 這時用 Pencil 從空白處圈，選取工具不理會 → 套索沒反應。要和套索一樣開始圈
    func testLassoingFromEmptySpaceWorksWhileATableIsSelected() throws {
        editor.updatePage(0, undoable: false) {
            $0.elements.append(PageElement(frame: CGRect(x: 300, y: 520, width: 240, height: 96), content: .table(TableData.make(rows: 3, cols: 3))))
        }
        let table = try XCTUnwrap(editor.pages[0].elements.last)
        editor.handleTap(FakeTap(doc(table.frame.midX, table.frame.midY)))
        XCTAssertEqual(editor.selected?.elementID, table.id, "點表格選起來")
        XCTAssertEqual(editor.tool, .select)
        XCTAssertEqual(editor.toolButtons[.lasso]?.configuration?.baseForegroundColor, .systemBlue, "工具列亮著套索")

        // Pencil 在空白處按下去拖
        let start = triangle[0]
        let g = TouchPan()
        editor.toolPan = g
        g.point = start
        g.fake = .began
        XCTAssertTrue(editor.gestureRecognizer(g, shouldReceive: FakeTouch(type: .pencil, location: start)))
        XCTAssertTrue(editor.gestureRecognizerShouldBegin(g), "Pencil 從空白處拖要開始圈")
        for (i, p) in triangle.enumerated() {
            g.fake = i == 0 ? .began : (i == triangle.count - 1 ? .ended : .changed)
            g.point = p
            g.moved = CGPoint(x: p.x - start.x, y: p.y - start.y)
            if i == 0 { g.moved = .zero }
            editor.handleToolPan(g)
        }
        XCTAssertEqual(editor.tool, .lasso, "換回套索")
        XCTAssertNil(editor.selected, "表格不再選著")
        XCTAssertEqual(editor.lassoSel?.ink.map(\.id), [inkID], "圈到那一筆字")
    }

    func testAFingerOnEmptySpaceStillScrollsWhileATableIsSelected() throws {
        let saved = EditorSettings.shared.fingerDrawing
        EditorSettings.shared.fingerDrawing = false
        defer { EditorSettings.shared.fingerDrawing = saved }
        editor.updatePage(0, undoable: false) {
            $0.elements.append(PageElement(frame: CGRect(x: 300, y: 520, width: 240, height: 96), content: .table(TableData.make(rows: 3, cols: 3))))
        }
        let table = try XCTUnwrap(editor.pages[0].elements.last)
        editor.handleTap(FakeTap(doc(table.frame.midX, table.frame.midY)))
        XCTAssertEqual(editor.tool, .select)
        let g = TouchPan()
        editor.toolPan = g
        g.point = doc(50, 700)
        _ = editor.gestureRecognizer(g, shouldReceive: FakeTouch(type: .direct, location: doc(50, 700)))
        XCTAssertFalse(editor.gestureRecognizerShouldBegin(g), "手指在空白處拖是捲動頁面")
    }

    // MARK: 套索照圈的形狀

    private func lasso(_ pts: [CGPoint]) {
        let g = TouchPan()
        for (i, p) in pts.enumerated() {
            g.fake = i == 0 ? .began : (i == pts.count - 1 ? .ended : .changed)
            editor.handleLassoPan(g, p)
        }
    }

    /// 圈得比筆跡大很多的三角形（每邊 10 點，套索至少要 5 點）
    private var triangle: [CGPoint] {
        let corners = [doc(20, 450), doc(150, 150), doc(300, 450), doc(22, 448)]
        var pts: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            for i in 0..<10 {
                let t = CGFloat(i) / 10
                pts.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return pts + [corners[3]]
    }

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
        XCTAssertEqual(moved[10].x, triangle[10].x + 40, accuracy: 0.5, "圈的形狀跟著移動")
        XCTAssertEqual(moved[10].y, triangle[10].y + 50, accuracy: 0.5)
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

    /// 測試用的分類（tearDown 刪掉，不留在 App 裡）
    private func testCategory(_ name: String = "測試分類") -> StickerCategory {
        let c = StickerStore.shared.addCategory(named: name)
        addedCategories.append(c.id)
        StickerStore.shared.select(c.id)
        return c
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stickers-\(UUID().uuidString)")
    }

    func testStickersLiveInCategoriesThatSurviveARelaunch() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StickerStore(directory: dir)
        let animals = store.addCategory(named: "動物")
        let food = store.addCategory(named: "  ")
        XCTAssertEqual(food.name, "分類 2", "沒取名就用預設的名字")
        let a = try XCTUnwrap(store.add(redSquare(), to: animals.id))
        let b = try XCTUnwrap(store.add(redSquare(), to: animals.id))
        XCTAssertEqual(store.categories[0].stickers.map(\.id), [a.id, b.id], "新的排在後面，第一張（預設封面）不變")
        XCTAssertEqual(store.categories[0].cover?.id, a.id, "封面預設是第一張")
        store.setCover(b.id)
        store.select(food.id)
        let reopened = StickerStore(directory: dir)
        XCTAssertEqual(reopened.categories.map(\.name), ["動物", "分類 2"], "重新打開 App 分類還在")
        XCTAssertEqual(reopened.categories[0].cover?.id, b.id, "封面還在")
        XCTAssertEqual(reopened.selectedCategory?.id, food.id, "記得上次選的分類")
        XCTAssertNotNil(reopened.image(for: a))
        reopened.remove(b.id)
        XCTAssertEqual(reopened.categories[0].cover?.id, a.id, "刪掉封面就回到第一張")
        reopened.removeCategory(animals.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(a.file).path), "刪分類連貼紙一起刪")
        XCTAssertEqual(StickerStore(directory: dir).categories.map(\.name), ["分類 2"])
    }

    func testStickersFromTheFirstVersionMoveIntoACategory() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = StickerRecord(file: "sticker-old.png")
        try XCTUnwrap(redSquare().pngData()).write(to: dir.appendingPathComponent(old.file))
        try JSONEncoder().encode([old]).write(to: dir.appendingPathComponent("stickers.json"))
        let store = StickerStore(directory: dir)
        XCTAssertEqual(store.categories.map(\.name), ["我的貼紙"])
        XCTAssertEqual(store.categories.first?.stickers, [old], "舊的貼紙沒有不見")
        XCTAssertEqual(StickerStore(directory: dir).categories.first?.stickers, [old], "搬過去之後重新打開也還在")
    }

    func testTransparentEdgesAreTrimmed() throws {
        let out = StickerMaker.trimmedTransparentEdges(redSquare(margin: 10, side: 60))
        let cg = try XCTUnwrap(out.cgImage)
        XCTAssertEqual(cg.width, 60)
        XCTAssertEqual(cg.height, 60)
    }

    /// 遮罩：sq 裡是白（主體），其他黑（背景）
    private func mask(_ sq: CGRect, in full: CGRect) -> CIImage {
        CIImage(color: .white).cropped(to: sq).composited(over: CIImage(color: .black).cropped(to: full))
    }

    func testCroppingAndRemovingTheBackground() throws {
        let img = redSquare(margin: 0, side: 100)
        let cropped = try XCTUnwrap(StickerMaker.render(img, crop: CGRect(x: 10, y: 20, width: 40, height: 30), mask: nil).cgImage)
        XCTAssertEqual([cropped.width, cropped.height], [40, 30], "照裁切範圍")
        let full = CGRect(x: 0, y: 0, width: 100, height: 100)
        let lifted = try XCTUnwrap(StickerMaker.render(img, crop: nil, mask: mask(CGRect(x: 20, y: 20, width: 30, height: 30), in: full)).cgImage)
        XCTAssertEqual([lifted.width, lifted.height], [30, 30], "背景透明，四周裁掉")
    }

    private func loadedEditor(_ img: UIImage) -> StickerEditorViewController {
        let vc = StickerEditorViewController(image: img)
        vc.view.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
        vc.view.layoutIfNeeded()
        return vc
    }

    func testTheEditorCropsWithTheFrame() throws {
        let vc = loadedEditor(redSquare(margin: 0, side: 200))
        vc.maskComputed(nil, background: nil)
        XCTAssertFalse(vc.removeBackground, "認不出主體：不去背")
        XCTAssertFalse(vc.backgroundSwitch.isEnabled)
        let r = vc.cropView.cropRect
        XCTAssertEqual(r, vc.imageRect, "一開始框住整張")
        XCTAssertGreaterThan(r.width, 100)
        // 右下角往左上拖一半
        vc.cropView.dragged(from: CGPoint(x: r.maxX, y: r.maxY), to: CGPoint(x: r.midX, y: r.midY), began: true)
        XCTAssertEqual(vc.unitCrop.width, 0.5, accuracy: 0.01)
        XCTAssertEqual(vc.unitCrop.height, 0.5, accuracy: 0.01)
        let out = try XCTUnwrap(vc.makeSticker().cgImage)
        XCTAssertEqual(Double(out.width), 100, accuracy: 1)
        XCTAssertEqual(Double(out.height), 100, accuracy: 1)
        // 框內拖曳是移動，不能拖出圖片
        let c = vc.cropView.cropRect
        vc.cropView.dragged(from: CGPoint(x: c.midX, y: c.midY), to: CGPoint(x: c.midX + 1000, y: c.midY), began: true)
        XCTAssertEqual(vc.cropView.cropRect.maxX, vc.imageRect.maxX, accuracy: 0.5)
        XCTAssertEqual(vc.cropView.cropRect.width, c.width, accuracy: 0.5, "移動不改大小")
    }

    func testTheEditorCanTurnBackgroundRemovalOff() throws {
        let vc = loadedEditor(redSquare(margin: 0, side: 100))
        let m = mask(CGRect(x: 20, y: 20, width: 30, height: 30), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        vc.maskComputed(m, background: StickerMaker.backgroundAlpha(m))
        XCTAssertTrue(vc.removeBackground, "預設去背")
        XCTAssertTrue(vc.backgroundSwitch.isOn)
        XCTAssertEqual(try XCTUnwrap(vc.makeSticker().cgImage).width, 30)
        vc.setRemoveBackground(false)
        XCTAssertEqual(try XCTUnwrap(vc.makeSticker().cgImage).width, 100, "關掉去背就是整張")
    }

    func testTheStickerToolShowsCategoriesAndAStripOfStickers() throws {
        let c = testCategory()
        let a = try XCTUnwrap(StickerStore.shared.add(redSquare(margin: 0, side: 300), to: c.id))
        let b = try XCTUnwrap(StickerStore.shared.add(redSquare(margin: 0, side: 300), to: c.id))
        editor.setTool(.sticker)
        XCTAssertNotNil(findView(id: "stickerCategory.\(c.id.uuidString)", in: editor.subBarStack), "工具列那一行是分類")
        XCTAssertNotNil(findView(label: "新增分類", in: editor.subBarStack))
        XCTAssertFalse(editor.stickerStrip.isHidden, "貼紙列在畫面下面")
        XCTAssertTrue(editor.photoStrip.isHidden)
        XCTAssertEqual(editor.stickerStrip.stickerButtons.map(\.accessibilityIdentifier),
                       ["sticker.\(a.id.uuidString)", "sticker.\(b.id.uuidString)"])
        let menu = try XCTUnwrap(editor.stickerStrip.stickerButtons[1].menu)
        XCTAssertEqual(Set(menu.children.map(\.title)), ["刪除", "設為分類封面"], "長按：刪除、設為分類封面")
        editor.stickerStrip.onSetCover?(b)
        XCTAssertEqual(StickerStore.shared.selectedCategory?.cover?.id, b.id)
        editor.stickerStrip.onDelete?(a)
        XCTAssertEqual(editor.stickerStrip.stickerButtons.count, 1, "刪掉了")
        editor.setTool(.pen)
        XCTAssertTrue(editor.stickerStrip.isHidden, "換工具就收起來")
    }

    func testTappingAStickerPutsItOnThePage() throws {
        let c = testCategory()
        let s = try XCTUnwrap(StickerStore.shared.add(redSquare(margin: 0, side: 300), to: c.id))
        editor.setTool(.sticker)
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

    func testTheCategoryMenuStartsWithCreatingOne() {
        let c = testCategory("我的測試分類")
        let titles = editor.stickerCategoryMenuItems(source: { nil }, then: { _, _ in }).map(\.title)
        XCTAssertEqual(titles.first, "創建新分類", "第一格是創建新分類")
        XCTAssertTrue(titles.contains(c.name), "接著是已經有的分類：\(titles)")
    }

    func testAnImageOnThePageCanBecomeASticker() throws {
        editor.insertImage(redSquare(margin: 0, side: 120), jpeg: false, at: doc(300, 500))
        let e = try XCTUnwrap(editor.pages[0].elements.last)
        let ref = ElementRef(pageID: editor.pages[0].id, elementID: e.id)
        let item = editor.elementMenu(ref, at: doc(300, 500)).children.first { $0.title == "變成貼紙" }
        let sub = try XCTUnwrap(item as? UIMenu, "圖片的選單有「變成貼紙」，裡面選分類")
        XCTAssertEqual(sub.children.first?.title, "創建新分類")
    }

    func testTheLassoMenuCanAddTheSelectionToStickers() throws {
        let c = testCategory()
        lasso(triangle)
        XCTAssertNotNil(editor.lassoSel)
        editor.presentLassoMenu()
        let menu = try XCTUnwrap(editor.pendingMenu, "點選取範圍跳出選單")
        let item = menu.children.first { $0.title == "添加至貼紙" }
        let sub = try XCTUnwrap(item as? UIMenu, "套索選單有「添加至貼紙」：\(menu.children.map(\.title))")
        XCTAssertEqual(sub.children.first?.title, "創建新分類", "第一格是創建新分類")
        XCTAssertTrue(sub.children.contains { $0.title == c.name })
        let img = try XCTUnwrap(editor.lassoStickerImage())
        let trimmed = StickerMaker.trimmedTransparentEdges(img)
        XCTAssertLessThan(trimmed.size.height, trimmed.size.width / 4, "只有那一筆字，背景透明（紙張不算）")
        editor.saveSticker(trimmed, into: c.id)
        XCTAssertEqual(StickerStore.shared.categories.first { $0.id == c.id }?.stickers.count, 1, "加進這個分類")
    }

    private func findView(label: String, in v: UIView) -> UIView? {
        if v.accessibilityLabel == label { return v }
        for s in v.subviews { if let f = findView(label: label, in: s) { return f } }
        return nil
    }

    private func findView(id: String, in v: UIView) -> UIView? {
        if v.accessibilityIdentifier == id { return v }
        for s in v.subviews { if let f = findView(id: id, in: s) { return f } }
        return nil
    }
}
