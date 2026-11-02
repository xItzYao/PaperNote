import XCTest
@testable import PaperNote

/// 回報的需求：
/// - 導線可以加名稱，名稱可以拖動
/// - 套索圈到一部分就選到電路圖（不想被圈到就上鎖，見 CircuitGroupTests）
/// - 匯出 SVG（只匯出電路圖）
/// - 導線點第二下跳出刪除；元件旁邊有叉叉和複製
/// - 元件庫放下面兩列，「⋯」可以改放左邊
/// - 移動電路圖時，寫在上面的字跟著走
/// - 橡皮擦：擦到的先變透明灰色，筆尖離開才刪；Pencil 筆身點兩下切換橡皮擦
final class CircuitEditingTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var ref: ElementRef!
    private var wireID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "CircuitEditing", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // 一條橫的導線、下面一個電阻（原尺寸，內容座標＝文件座標的距離）
        var d = CircuitData()
        let wire = CircuitWire(points: [CGPoint(x: 40, y: 60), CGPoint(x: 200, y: 60)])
        wireID = wire.id
        d.wires = [wire]
        d.components = [CircuitComponent(part: .resistor, position: CGPoint(x: 120, y: 160))]
        let o = editor.contentOrigin(0)
        ref = try XCTUnwrap(editor.insertElement(.circuit(d), size: CGSize(width: 260, height: 220), at: CGPoint(x: o.x + 250, y: o.y + 300)))
        editor.setTool(.circuit)
        editor.selectCircuitMode(.select)
        editor.circuitTarget = ref
        // 同一輪 run loop 記的動作會併成一步：讓插入電路圖自己是一步
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private var data: CircuitData? { editor.circuitInfo(ref)?.data }
    private var wire: CircuitWire? { data?.wires.first { $0.id == wireID } }
    private var frame: CGRect {
        guard let info = editor.circuitInfo(ref) else { return .zero }
        return editor.docFrame(of: info.element, pageIndex: info.pi)
    }

    /// 導線上（從左端往右 dx）的文件座標
    private func onWire(_ dx: CGFloat) -> CGPoint {
        guard let w = wire else { return .zero }
        return editor.circuitDoc(CGPoint(x: w.points[0].x + dx, y: w.points[0].y), ref)
    }

    // MARK: 導線名稱

    func testNamingAWire() throws {
        editor.promptWireLabel(ref, wire: wireID, near: .zero)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let alert = try XCTUnwrap(editor.presentedViewController as? UIAlertController, "選單的「導線名稱」：跳出輸入名稱")
        XCTAssertEqual(alert.title, "導線名稱")
        alert.dismiss(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let w0 = try XCTUnwrap(wire)
        editor.setWireLabel(ref, wire: wireID, to: " Vout ", near: CGPoint(x: w0.points[0].x + 80, y: w0.points[0].y))
        let w = try XCTUnwrap(wire)
        XCTAssertEqual(w.label, "Vout")
        let pos = try XCTUnwrap(w.labelPosition)
        XCTAssertEqual(pos.x, w.points[0].x + 80, accuracy: 0.01, "名稱放在點的位置")
        XCTAssertLessThan(pos.y, w.points[0].y, "橫的導線：名稱在上面")
        XCTAssertTrue(frame.contains(editor.circuitDoc(pos, ref)), "外框包含名稱")
        XCTAssertEqual(editor.circuitHit(at: editor.circuitDoc(pos, ref))?.selection, .wire(wireID), "點名稱也是選到這條導線")

        editor.setWireLabel(ref, wire: wireID, to: "", near: .zero)
        XCTAssertNil(wire?.label, "留空＝拿掉名稱")
        XCTAssertNil(wire?.labelPosition)
    }

    func testDraggingTheNameMovesOnlyTheName() throws {
        let w0 = try XCTUnwrap(wire)
        editor.setWireLabel(ref, wire: wireID, to: "CLK", near: CGPoint(x: w0.points[0].x + 80, y: w0.points[0].y))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let before = try XCTUnwrap(wire)
        let start = editor.circuitDoc(try XCTUnwrap(before.labelPosition), ref)
        XCTAssertTrue(editor.circuitPanShouldBegin(at: start), "按在名稱上可以拖")
        let s = try XCTUnwrap(data).scale
        TouchPan().drag(from: start, to: CGPoint(x: start.x + 33, y: start.y + 27)) { editor.handleCircuitPan($0, $0.location(in: nil)) }
        let after = try XCTUnwrap(wire)
        let b = try XCTUnwrap(before.labelPosition), a = try XCTUnwrap(after.labelPosition)
        XCTAssertEqual(a.x - after.points[0].x, b.x - before.points[0].x + 33 / s, accuracy: 0.01, "名稱跟著手指走（不吸格點）")
        XCTAssertEqual(a.y - after.points[0].y, b.y - before.points[0].y + 27 / s, accuracy: 0.01)
        XCTAssertEqual(after.points.count, 2, "導線本身不變")
        XCTAssertEqual(after.points[1].x - after.points[0].x, 160)
        XCTAssertEqual(after.points[1].y, after.points[0].y)
        XCTAssertEqual(editor.circuitSel, .wire(wireID))

        editor.undoTapped()
        let undone = try XCTUnwrap(wire)
        XCTAssertEqual(try XCTUnwrap(undone.labelPosition).y - undone.points[0].y, b.y - before.points[0].y, accuracy: 0.01, "可以復原")
        XCTAssertEqual(undone.label, "CLK")
    }

    /// 回報的需求：選到名稱時外面一圈藍框（拖的時候確定有選到）；右下角斜的雙箭頭拖曳調整大小
    func testSelectedNameHasAFrameAndAResizeHandle() throws {
        let w0 = try XCTUnwrap(wire)
        editor.setWireLabel(ref, wire: wireID, to: "CLK", near: CGPoint(x: w0.points[0].x + 80, y: w0.points[0].y))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let pos = editor.circuitDoc(try XCTUnwrap(wire?.labelPosition), ref)
        editor.handleCircuitTap(at: pos)
        XCTAssertEqual(editor.circuitSel, .wire(wireID), "點名稱選到導線")
        let box = try XCTUnwrap(editor.selectedLabelRect()?.rect)
        XCTAssertTrue(box.contains(pos))
        let drawn = try XCTUnwrap(editor.overlay.circuitSelLayer.path?.boundingBox, "名稱外面有藍框")
        XCTAssertEqual(drawn.minX, box.minX, accuracy: 0.5)
        XCTAssertEqual(drawn.maxY, box.maxY, accuracy: 0.5)

        let handle = try XCTUnwrap(editor.labelResizePoint())
        XCTAssertFalse(editor.overlay.circuitLabelResizeHandle.isHidden, "右下角有縮放箭頭")
        XCTAssertGreaterThan(handle.x, box.maxX)
        XCTAssertGreaterThan(handle.y, box.maxY)
        XCTAssertTrue(editor.circuitPanShouldBegin(at: handle))

        let before = try XCTUnwrap(wire)
        let offset = CGPoint(x: before.labelPosition!.x - before.points[0].x, y: before.labelPosition!.y - before.points[0].y)
        TouchPan().drag(from: handle, to: CGPoint(x: handle.x + 20, y: handle.y + 10)) { editor.handleCircuitPan($0, $0.location(in: nil)) }
        let bigger = try XCTUnwrap(wire)
        XCTAssertGreaterThan(bigger.labelFont, before.labelFont * 1.3, "往外拖：字變大")
        XCTAssertEqual(bigger.labelPosition!.x - bigger.points[0].x, offset.x, accuracy: 0.01, "中心不動")
        XCTAssertEqual(bigger.labelPosition!.y - bigger.points[0].y, offset.y, accuracy: 0.01)
        XCTAssertEqual(editor.circuitSel, .wire(wireID), "還是選著")
        XCTAssertTrue(CircuitRenderer.svg(try XCTUnwrap(data)).contains(#"font-size="\#(CircuitRenderer.num(bigger.labelFont))""#), "SVG 也用新的大小")

        let h2 = try XCTUnwrap(editor.labelResizePoint())
        TouchPan().drag(from: h2, to: CGPoint(x: h2.x - 60, y: h2.y - 40)) { editor.handleCircuitPan($0, $0.location(in: nil)) }
        XCTAssertEqual(wire?.labelFont ?? 0, CircuitWire.labelSizeRange.lowerBound, accuracy: 0.01, "往內拖到底：最小字級")
    }

    // MARK: 元件名稱

    private var part: CircuitComponent? { data?.components.first }

    /// 回報的需求：元件也可以命名（選取中再點一下，或工具列的「元件名稱」）
    func testTapASelectedComponentToNameIt() throws {
        let c = try XCTUnwrap(part)
        editor.handleCircuitTap(at: editor.circuitDoc(c.position, ref))
        editor.handleCircuitTap(at: editor.circuitDoc(c.position, ref))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let alert = try XCTUnwrap(editor.presentedViewController as? UIAlertController, "再點一下：跳出輸入名稱")
        XCTAssertEqual(alert.title, "元件名稱")
        XCTAssertEqual(editor.circuitSel, .component(c.id))
        alert.dismiss(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(editor.buildCircuitRibbon().contains { $0.accessibilityLabel == "元件名稱" }, "工具列也可以命名")

        editor.setComponentName(ref, component: c.id, to: " R1 ")
        let named = try XCTUnwrap(part)
        XCTAssertEqual(named.name, "R1")
        let pos = try XCTUnwrap(named.namePosition)
        XCTAssertLessThan(pos.y, CircuitGeometry.bounds(named).minY, "名稱在元件上方")
        XCTAssertTrue(frame.contains(editor.circuitDoc(pos, ref)), "外框包含名稱")
        XCTAssertEqual(editor.circuitHit(at: editor.circuitDoc(pos, ref))?.selection, .component(c.id), "點名稱也是選到這個元件")
        XCTAssertTrue(CircuitRenderer.svg(try XCTUnwrap(data)).contains(">R1</text>"), "SVG 也有名稱")

        editor.setComponentName(ref, component: c.id, to: "")
        XCTAssertNil(part?.name, "留空＝拿掉名稱")
        XCTAssertNil(part?.nameOffset)
    }

    /// 移動元件：名稱跟著走（和元件的相對位置不變）
    func testTheNameFollowsTheComponent() throws {
        let c = try XCTUnwrap(part)
        editor.setComponentName(ref, component: c.id, to: "R1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let before = try XCTUnwrap(part)
        let start = editor.circuitDoc(before.position, ref)
        let s = try XCTUnwrap(data).scale
        TouchPan().drag(from: start, to: CGPoint(x: start.x + 40 * s, y: start.y + 30 * s)) { editor.handleCircuitPan($0, $0.location(in: nil)) }
        let after = try XCTUnwrap(part)
        let docBefore = editor.circuitDoc(before.position, ref), docAfter = editor.circuitDoc(after.position, ref)
        XCTAssertGreaterThan(docAfter.x - docBefore.x, 0, "元件有移動")
        XCTAssertEqual(after.nameOffset, before.nameOffset, "名稱和元件的相對位置不變")
        let nameDoc = editor.circuitDoc(try XCTUnwrap(after.namePosition), ref)
        XCTAssertEqual(nameDoc.x - docAfter.x, (before.namePosition!.x - before.position.x) * s, accuracy: 0.5)
    }

    /// 拖名稱：只動名稱；拖右下角：字變大
    func testDraggingAndResizingTheComponentName() throws {
        let c = try XCTUnwrap(part)
        editor.setComponentName(ref, component: c.id, to: "R1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let before = try XCTUnwrap(part)
        let start = editor.circuitDoc(try XCTUnwrap(before.namePosition), ref)
        XCTAssertTrue(editor.circuitPanShouldBegin(at: start), "按在名稱上可以拖")
        let s = try XCTUnwrap(data).scale
        TouchPan().drag(from: start, to: CGPoint(x: start.x + 33, y: start.y - 21)) { editor.handleCircuitPan($0, $0.location(in: nil)) }
        let moved = try XCTUnwrap(part)
        XCTAssertEqual(moved.nameOffset!.x, before.nameOffset!.x + 33 / s, accuracy: 0.01, "名稱跟著手指走（不吸格點）")
        XCTAssertEqual(moved.nameOffset!.y, before.nameOffset!.y - 21 / s, accuracy: 0.01)
        XCTAssertEqual(editor.circuitDoc(moved.position, ref), editor.circuitDoc(before.position, ref), "元件本身不動")
        XCTAssertEqual(editor.circuitSel, .component(c.id))

        editor.updateCircuitChrome()
        let box = try XCTUnwrap(editor.selectedLabelRect()?.rect, "選到元件：名稱有藍框")
        let drawn = try XCTUnwrap(editor.overlay.circuitSelLayer.path?.boundingBox)
        XCTAssertTrue(drawn.contains(box), "藍框包含名稱")
        let handle = try XCTUnwrap(editor.labelResizePoint())
        XCTAssertFalse(editor.overlay.circuitLabelResizeHandle.isHidden, "右下角有縮放箭頭")
        XCTAssertTrue(editor.circuitPanShouldBegin(at: handle))
        let buttons = try XCTUnwrap(editor.circuitPartHandleCenters())
        for b in [buttons.rotate, buttons.flip, buttons.copy, buttons.delete] {
            XCTAssertGreaterThan(handle.distance(to: b), buttons.radius, "縮放箭頭不會和旁邊的按鈕疊在一起")
        }
        TouchPan().drag(from: handle, to: CGPoint(x: handle.x + 20, y: handle.y + 10)) { editor.handleCircuitPan($0, $0.location(in: nil)) }
        let bigger = try XCTUnwrap(part)
        XCTAssertGreaterThan(bigger.nameFont, before.nameFont * 1.3, "往外拖：字變大")
        XCTAssertEqual(bigger.nameOffset!.x, moved.nameOffset!.x, accuracy: 0.01, "中心不動")
        XCTAssertEqual(editor.circuitSel, .component(c.id), "還是選著")

        editor.undoTapped()
        XCTAssertEqual(try XCTUnwrap(part).nameFont, before.nameFont, accuracy: 0.01, "可以復原")
    }

    // MARK: 刪除、複製

    /// 回報的需求：導線第一下選取，第二下跳出選單（不用長按）
    func testSecondTapOnAWireShowsTheMenu() throws {
        XCTAssertFalse(editor.longPressGesture.isEnabled, "電路圖工具不用長按")
        for mode: CircuitMode in [.select, .wire] {
            editor.selectCircuitMode(mode)
            editor.circuitSel = nil
            editor.pendingMenu = nil
            editor.handleCircuitTap(at: onWire(80))
            XCTAssertEqual(editor.circuitSel, .wire(wireID), "第一下選取")
            XCTAssertNil(editor.pendingMenu, "第一下不跳選單")
            XCTAssertNotNil(editor.overlay.circuitWireSelLayer.path, "看得出選到了")

            editor.handleCircuitTap(at: onWire(40))
            let menu = try XCTUnwrap(editor.pendingMenu, "第二下跳選單")
            XCTAssertEqual(menu.children.map(\.title), ["導線名稱", "刪除"])
            let delete = try XCTUnwrap(menu.children.last as? UIAction)
            XCTAssertTrue(delete.attributes.contains(.destructive))
            XCTAssertNotNil(wire, "還沒按刪除，不會刪")
            XCTAssertEqual(editor.circuitMode, mode, "模式不變")
        }
        editor.deleteCircuitSelection()
        XCTAssertNil(wire)
        XCTAssertEqual(data?.components.count, 1, "元件還在")
        editor.undoTapped()
        XCTAssertNotNil(wire, "可以復原")
    }

    /// 第二下要點在同一條導線上：換點別的只是選取
    func testTappingSomethingElseDoesNotShowTheMenu() throws {
        let c = try XCTUnwrap(part)
        editor.handleCircuitTap(at: onWire(80))
        editor.handleCircuitTap(at: editor.circuitDoc(c.position, ref))
        XCTAssertEqual(editor.circuitSel, .component(c.id))
        XCTAssertNil(editor.pendingMenu)
        editor.handleCircuitTap(at: onWire(80))
        XCTAssertEqual(editor.circuitSel, .wire(wireID))
        XCTAssertNil(editor.pendingMenu, "從別的東西換過來是第一下")
        editor.handleCircuitTap(at: CGPoint(x: onWire(0).x, y: onWire(0).y + 300))
        XCTAssertNil(editor.circuitSel, "點空白處取消選取")
        editor.handleCircuitTap(at: onWire(80))
        XCTAssertNil(editor.pendingMenu, "取消後又是第一下")
    }

    /// 回報的需求：元件旁邊加回叉叉
    func testComponentXDeletes() throws {
        let c = try XCTUnwrap(part)
        editor.handleCircuitTap(at: editor.circuitDoc(c.position, ref))
        let h = try XCTUnwrap(editor.circuitPartHandleCenters())
        XCTAssertFalse(editor.overlay.circuitDeleteHandle.isHidden)
        XCTAssertFalse(editor.circuitPanShouldBegin(at: h.delete), "按在叉叉上是點擊")
        editor.handleCircuitTap(at: h.delete)
        XCTAssertEqual(data?.components.count, 0)
        XCTAssertNotNil(wire, "導線還在")
        XCTAssertNil(editor.circuitSel)
        XCTAssertTrue(editor.overlay.circuitDeleteHandle.isHidden, "沒選取就沒有按鈕")
        editor.undoTapped()
        XCTAssertEqual(data?.components.count, 1, "可以復原")
    }

    /// 回報的需求：元件旁邊加複製
    func testComponentCopyButton() throws {
        editor.setComponentName(ref, component: try XCTUnwrap(part).id, to: "R1")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let c = try XCTUnwrap(part)
        editor.handleCircuitTap(at: editor.circuitDoc(c.position, ref))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let h = try XCTUnwrap(editor.circuitPartHandleCenters())
        XCTAssertFalse(editor.overlay.circuitCopyHandle.isHidden)
        XCTAssertFalse(editor.circuitPanShouldBegin(at: h.copy), "按在複製上是點擊")
        for (i, a) in [h.rotate, h.flip, h.copy, h.delete].enumerated() {
            for b in [h.rotate, h.flip, h.copy, h.delete].dropFirst(i + 1) {
                XCTAssertGreaterThanOrEqual(a.distance(to: b), h.radius * 1.5, "按鈕不會疊在一起")
            }
        }

        editor.handleCircuitTap(at: h.copy)

        let parts = try XCTUnwrap(data?.components)
        XCTAssertEqual(parts.count, 2)
        let original = try XCTUnwrap(parts.first { $0.id == c.id })
        let copy = try XCTUnwrap(parts.first { $0.id != c.id })
        XCTAssertEqual(copy.part, c.part)
        XCTAssertEqual(copy.name, "R1")
        XCTAssertEqual(editor.circuitSel, .component(copy.id), "選起新的這個")
        XCTAssertFalse(CircuitGeometry.bounds(copy).intersects(CircuitGeometry.bounds(original)), "不會疊在一起")
        XCTAssertEqual(copy.position.y.truncatingRemainder(dividingBy: CircuitData.grid), 0, "在格點上")

        editor.undoTapped()
        XCTAssertEqual(data?.components.count, 1, "可以復原")
    }

    func testWiresHaveNoButtons() throws {
        editor.handleCircuitTap(at: onWire(80))
        XCTAssertEqual(editor.circuitSel, .wire(wireID))
        XCTAssertNil(editor.circuitPartHandleCenters(), "導線旁邊沒有按鈕")
        let c = try XCTUnwrap(data?.components.first)
        editor.handleCircuitTap(at: editor.circuitDoc(c.position, ref))
        XCTAssertNotNil(editor.circuitPartHandleCenters(), "元件旁邊有按鈕")
        let labels = editor.buildCircuitRibbon().compactMap(\.accessibilityLabel)
        XCTAssertFalse(labels.contains("刪除"), "第二排不放刪除工具")
    }

    // MARK: 元件庫的位置

    /// 回報的需求：元件庫預設放下面兩列，「⋯」可以改放左邊
    func testLibraryIsBelowInTwoRowsAndCanMoveLeft() throws {
        let saved = editor.settings.circuitLibraryOnLeft
        defer { editor.setCircuitLibraryOnLeft(saved) }
        let lib = editor.circuitLibrary
        XCTAssertFalse(lib.isHidden, "電路工具顯示元件庫")

        editor.setCircuitLibraryOnLeft(false)
        editor.view.layoutIfNeeded()
        XCTAssertGreaterThan(lib.frame.width, editor.view.bounds.width * 0.7, "橫跨下面")
        XCTAssertEqual(lib.frame.maxY, editor.view.bounds.height - editor.view.safeAreaInsets.bottom - 10, accuracy: 1)
        lib.layoutIfNeeded()
        let rows = Set(lib.visibleTiles.map { ($0.convert($0.bounds, to: lib).minY).rounded() })
        XCTAssertEqual(rows.count, 2, "元件排成兩列")
        XCTAssertEqual(lib.visibleTiles.count, CircuitPart.builtIn.count, "每種元件都有")
        XCTAssertEqual(editor.bottomInset, lib.bottomOverlap, accuracy: 0.5, "頁面可以多捲，最下面不會被擋住")
        XCTAssertGreaterThan(lib.bottomOverlap, 100)

        func item(_ elements: [UIMenuElement]) -> UIAction? {
            for e in elements {
                if let a = e as? UIAction, a.title == "電路元件庫放左邊" { return a }
                if let m = e as? UIMenu, let a = item(m.children) { return a }
            }
            return nil
        }
        XCTAssertEqual(item(editor.makeSettingsMenuItems())?.state, .off, "「⋯」裡有這個選項")

        editor.setCircuitLibraryOnLeft(true)
        editor.view.layoutIfNeeded()
        XCTAssertLessThan(lib.frame.width, 200, "放左邊是窄的")
        XCTAssertLessThan(lib.frame.minX, 50)
        XCTAssertEqual(lib.bottomOverlap, 0)
        XCTAssertEqual(lib.visibleTiles.count, CircuitPart.builtIn.count)
        XCTAssertEqual(item(editor.makeSettingsMenuItems())?.state, .on)
        XCTAssertTrue(editor.settings.circuitLibraryOnLeft, "記住選擇")
    }

    // MARK: 橡皮擦

    private var circuitView: DrawnElementView? {
        editor.pageViews[ref.pageID]?.elementView(ref.elementID) as? DrawnElementView
    }

    /// 回報的需求：擦到的先變灰，筆尖離開後才刪
    func testEraserDeletesOnlyWhenThePencilLifts() throws {
        editor.selectCircuitMode(.erase)
        let c = try XCTUnwrap(part)
        XCTAssertTrue(editor.circuitPanShouldBegin(at: CGPoint(x: onWire(0).x, y: onWire(0).y + 300)), "哪裡都可以開始擦")

        TouchPan().drag(from: onWire(20), to: onWire(60)) { g in
            if g.fake == .ended {
                XCTAssertNotNil(wire, "筆尖還沒離開，不會刪")
                XCTAssertEqual(editor.circuitErasing[ref], [wireID])
                XCTAssertEqual(circuitView?.circuitErasing, [wireID], "畫面上變灰")
            }
            editor.handleCircuitPan(g, g.location(in: nil))
        }

        XCTAssertNil(wire, "筆尖離開就刪")
        XCTAssertEqual(part?.id, c.id, "沒擦到的不動")
        XCTAssertTrue(editor.circuitErasing.isEmpty)
        XCTAssertEqual(circuitView?.circuitErasing, [], "不再是灰色")
        XCTAssertEqual(editor.circuitMode, .erase, "還是橡皮擦，可以繼續擦")

        editor.undoTapped()
        XCTAssertNotNil(wire, "可以復原")
    }

    /// 一筆擦到好幾個：一起刪、復原一次全部回來；全部擦完電路圖也不見
    func testOneStrokeErasesEverythingItTouches() throws {
        editor.selectCircuitMode(.erase)
        let c = try XCTUnwrap(part)
        TouchPan().drag(from: onWire(80), to: editor.circuitDoc(c.position, ref)) { editor.handleCircuitPan($0, $0.location(in: nil)) }
        XCTAssertNil(editor.circuitInfo(ref), "都擦掉了，電路圖也不留")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        editor.undoTapped()
        XCTAssertNotNil(wire, "復原一次：導線回來")
        XCTAssertEqual(part?.id, c.id, "同一次復原：元件也回來")
    }

    /// 筆動得快：兩次回報之間跨過導線也要擦到
    func testFastStrokeStillHitsWhatItCrosses() {
        editor.selectCircuitMode(.erase)
        let on = onWire(80)
        TouchPan().drag(from: CGPoint(x: on.x, y: on.y - 30), to: CGPoint(x: on.x, y: on.y + 30), steps: 1) { editor.handleCircuitPan($0, $0.location(in: nil)) }
        XCTAssertNil(wire)
    }

    func testCancelledEraseDeletesNothing() {
        editor.selectCircuitMode(.erase)
        let g = TouchPan()
        g.point = onWire(40)
        g.fake = .began
        editor.handleCircuitPan(g, g.point)
        XCTAssertEqual(circuitView?.circuitErasing, [wireID])
        g.fake = .cancelled
        editor.handleCircuitPan(g, g.point)
        XCTAssertNotNil(wire)
        XCTAssertEqual(circuitView?.circuitErasing, [])
        XCTAssertNil(editor.circuitEraseLast)
    }

    /// 擦到一半用筆身切回去：這一筆照樣收尾，不會一直灰著
    func testSwitchingModeMidStrokeStillFinishes() {
        editor.selectCircuitMode(.erase)
        let g = TouchPan()
        g.point = onWire(40)
        g.fake = .began
        editor.handleCircuitPan(g, g.point)
        editor.selectCircuitMode(.select)
        g.fake = .ended
        editor.handleCircuitPan(g, g.point)
        XCTAssertNil(wire)
        XCTAssertNil(editor.circuitEraseLast)
        XCTAssertEqual(circuitView?.circuitErasing, [])
    }

    func testLeavingTheToolDropsThePendingErase() {
        editor.selectCircuitMode(.erase)
        let g = TouchPan()
        g.point = onWire(40)
        g.fake = .began
        editor.handleCircuitPan(g, g.point)
        let view = circuitView
        editor.setTool(.select)
        XCTAssertTrue(editor.circuitErasing.isEmpty)
        XCTAssertEqual(view?.circuitErasing, [])
        XCTAssertNotNil(wire, "沒有收尾就不刪")
    }

    func testTappingWithTheEraserDeletes() throws {
        editor.selectCircuitMode(.erase)
        XCTAssertNil(editor.circuitSel, "進橡皮擦時取消選取")
        editor.handleCircuitTap(at: CGPoint(x: onWire(0).x, y: onWire(0).y + 300))
        XCTAssertNotNil(wire, "點空白處沒事")
        XCTAssertEqual(data?.components.count, 1)
        editor.handleCircuitTap(at: onWire(80))
        XCTAssertNil(wire)
        XCTAssertEqual(data?.components.count, 1)
        XCTAssertEqual(editor.circuitMode, .erase)
    }

    /// 回報的需求：電路圖模式筆身點兩下從切換接線改成切換橡皮擦
    func testPencilDoubleTapTogglesTheEraser() throws {
        try XCTSkipIf(UIPencilInteraction.preferredTapAction == .ignore, "系統設定成點兩下不做事")
        for mode: CircuitMode in [.select, .wire, .place(.resistor)] {
            editor.selectCircuitMode(mode)
            editor.handlePencilDoubleTap()
            XCTAssertEqual(editor.circuitMode, .erase)
            XCTAssertEqual(editor.tool, .circuit, "不是切到一般的橡皮擦")
            editor.handlePencilDoubleTap()
            XCTAssertEqual(editor.circuitMode, mode, "再點兩下切回原本的模式")
        }
    }

    func testEraserButtonIsOnTheSecondRow() throws {
        let eraser = try XCTUnwrap(editor.buildCircuitRibbon().compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == "橡皮擦" })
        eraser.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.circuitMode, .erase)
        let after = editor.buildCircuitRibbon().compactMap { $0 as? UIButton }
        XCTAssertEqual(after.first { $0.accessibilityLabel == "橡皮擦" }?.configuration?.baseForegroundColor, .systemBlue, "目前的模式亮起來")
    }

    /// 擦到的畫成透明灰色，沒擦到的不變
    func testErasedPartsAreDrawnTranslucentGray() throws {
        var d = CircuitData()
        let top = CircuitWire(points: [CGPoint(x: 10, y: 30), CGPoint(x: 90, y: 30)])
        let bottom = CircuitWire(points: [CGPoint(x: 10, y: 70), CGPoint(x: 90, y: 70)])
        d.wires = [top, bottom]
        let size = 100
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        UIGraphicsPushContext(ctx)
        CircuitRenderer.draw(d, in: CGRect(x: 0, y: 0, width: 100, height: 100), erasing: [top.id])
        UIGraphicsPopContext()
        let pixels = try XCTUnwrap(ctx.data).bindMemory(to: UInt8.self, capacity: size * size * 4)
        // x = 50 這一欄，y 附近最深的一點：(紅, 透明度)。CGContext 的 y 由下往上
        func darkest(_ y: Int) -> (red: Double, alpha: Double) {
            var best = (red: 0.0, alpha: 0.0)
            for row in (y - 4)...(y + 4) {
                let i = (size - 1 - row) * size * 4 + 50 * 4
                let a = Double(pixels[i + 3]) / 255
                if a > best.alpha { best = (a > 0 ? Double(pixels[i]) / 255 / a : 0, a) }
            }
            return best
        }
        let erased = darkest(30), kept = darkest(70)
        XCTAssertEqual(erased.alpha, 0.45, accuracy: 0.1, "透明")
        XCTAssertEqual(erased.red, 0.55, accuracy: 0.1, "灰色")
        XCTAssertGreaterThan(kept.alpha, 0.9, "沒擦到的不透明")
    }

    // MARK: 匯出 SVG

    func testSVGExportHasTheWholeCircuit() throws {
        let w0 = try XCTUnwrap(wire)
        editor.setWireLabel(ref, wire: wireID, to: "A&B", near: w0.points[0])
        let d = try XCTUnwrap(data)
        let svg = CircuitRenderer.svg(d)
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains(#"<svg xmlns="http://www.w3.org/2000/svg""#))
        XCTAssertEqual(svg.components(separatedBy: "<path").count - 1, 2, "電阻一條、導線一條")
        XCTAssertTrue(svg.contains(">A&amp;B</text>"), "導線名稱是文字（特殊字元有跳脫）")
        XCTAssertTrue(XMLParser(data: Data(svg.utf8)).parse(), "是合法的 XML")
        // viewBox 包含整個電路圖（含名稱）
        let box = try XCTUnwrap(svg.range(of: #"viewBox="([^"]+)""#, options: .regularExpression).map { String(svg[$0]) })
        let nums = box.dropFirst(9).dropLast().split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(nums.count, 4)
        let vb = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
        XCTAssertTrue(vb.contains(d.contentBounds), "整張圖都在畫面裡")

        // 曲線（電感的半圓）轉成 SVG 的貝茲曲線
        var coil = CircuitData()
        coil.components = [CircuitComponent(part: .inductor, position: CGPoint(x: 60, y: 60))]
        XCTAssertTrue(CircuitRenderer.svg(coil).contains(" C"), "弧線變成 C 指令")
        XCTAssertEqual(CircuitRenderer.num(12.50), "12.5")
        XCTAssertEqual(CircuitRenderer.num(-0.001), "0")
    }

    func testExportButtonIsOnTheToolbarAndInTheMenu() {
        let labels = editor.buildCircuitRibbon().compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains("匯出 SVG"), "電路工具列有「匯出 SVG」")
        let titles = editor.elementMenu(ref, at: frame.center).children.map(\.title)
        XCTAssertTrue(titles.contains("匯出 SVG"), "長按電路圖也能匯出")
    }

    /// 回報的需求：「選取」「接線」放在第二列工具列，不放說明文字
    func testModeButtonsAreOnTheSecondRow() throws {
        let views = editor.buildCircuitRibbon()
        let buttons = views.compactMap { $0 as? UIButton }
        let select = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "選取" })
        let wire = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "接線" })
        XCTAssertTrue(views.prefix(2).contains(select) && views.prefix(2).contains(wire), "放在最前面")
        XCTAssertEqual(select.configuration?.baseForegroundColor, .systemBlue, "目前的模式亮起來")
        XCTAssertFalse(views.contains { ($0 as? UILabel)?.text?.isEmpty == false }, "不放說明文字")
        wire.sendActions(for: .touchUpInside)
        XCTAssertEqual(editor.circuitMode, .wire)
        let after = editor.buildCircuitRibbon().compactMap { $0 as? UIButton }
        XCTAssertEqual(after.first { $0.accessibilityLabel == "接線" }?.configuration?.baseForegroundColor, .systemBlue)
    }

    // MARK: 套索、移動

    func testLassoTakesTheCircuitWhenPartlyCircled() {
        editor.setTool(.lasso)
        func lasso(_ r: CGRect) {
            let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY + 2), CGPoint(x: r.minX + 1, y: r.minY + 1)]
            let g = TouchPan()
            for (i, p) in pts.enumerated() {
                g.fake = i == 0 ? .began : (i == pts.count - 1 ? .ended : .changed)
                editor.handleLassoPan(g, p)
            }
        }
        let f = frame
        lasso(CGRect(x: f.minX + 20, y: f.minY + 20, width: f.width / 2, height: f.height / 2))
        XCTAssertEqual(editor.lassoSel?.elements, [ref], "圈到一部分就選到，和圖片一樣")
        editor.clearLassoSelection()
        lasso(f.insetBy(dx: -20, dy: -20))
        XCTAssertEqual(editor.lassoSel?.elements, [ref])
    }

    private func word(at p: CGPoint) -> InkStroke {
        let page = editor.contentOrigin(0)
        return InkStroke(colorHex: "#1A1A1AFF", points: (0...5).map { InkPoint(CGPoint(x: p.x - page.x + CGFloat($0) * 10, y: p.y - page.y), width: 2) })
    }

    func testMovingTheCircuitCarriesTheHandwriting() throws {
        let f = frame
        let onCircuit = word(at: CGPoint(x: f.minX + 60, y: f.minY + 100))
        let outside = word(at: CGPoint(x: f.minX - 200, y: f.minY - 100))
        editor.updatePage(0) { $0.ink = [onCircuit, outside] }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.setTool(.select)
        editor.select(ref)
        let grab = CGPoint(x: f.midX, y: f.midY)
        guard case .move? = editor.dragTarget(at: grab)?.1 else { return XCTFail("按在電路圖上可以拖") }
        TouchPan().drag(from: grab, to: CGPoint(x: grab.x, y: grab.y + 80)) { editor.handleElementPan($0, $0.location(in: nil)) }
        let moved = frame.minY - f.minY
        XCTAssertGreaterThan(moved, 40, "電路圖移動了")
        let ink = editor.pages[0].ink
        XCTAssertEqual(ink.first { $0.id == onCircuit.id }?.points[0].point.y ?? 0, onCircuit.points[0].point.y + moved, accuracy: 0.01, "寫在電路圖上的字跟著走")
        XCTAssertEqual(ink.first { $0.id == outside.id }?.points[0].point, outside.points[0].point, "外面的字不動")
        editor.undoTapped()
        XCTAssertEqual(frame.minY, f.minY, accuracy: 0.5, "復原一次：電路圖回去")
        XCTAssertEqual(editor.pages[0].ink.first { $0.id == onCircuit.id }?.points[0].point, onCircuit.points[0].point, "同一次復原：字也回去")
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
