import XCTest
@testable import PaperNote

/// 回報的需求（11/16）：
/// - 手指可以移動選起來的東西，不能選沒選起來的
/// - 放到最大再拉、回彈後，頁面從右上角跳回目前的位置
/// - 電路圖：框選拖動時，接在一起的地方要拉出線；可以新增分類，畫完元件就問放哪個分類；
///   「⋯」的「電路圖選取模式」；長按選單拿掉「固定位置」（和鎖頭重複）
final class EditorRequestsNov16Tests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var savedFingerDrawing = false

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "Nov16", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        savedFingerDrawing = EditorSettings.shared.fingerDrawing
        EditorSettings.shared.fingerDrawing = false
    }

    override func tearDown() {
        EditorSettings.shared.fingerDrawing = savedFingerDrawing
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private func doc(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(0)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    private func center(_ ref: ElementRef) -> CGPoint {
        guard case let (pi, ei)? = editor.locate(ref) else { return .zero }
        let r = editor.docFrame(of: editor.pages[pi].elements[ei], pageIndex: pi)
        return CGPoint(x: r.midX, y: r.midY)
    }

    // MARK: 手指

    func testFingersOnlyReachWhatIsAlreadySelected() throws {
        let a = try XCTUnwrap(editor.insertElement(.table(TableData.make(rows: 2, cols: 2)), size: CGSize(width: 200, height: 80), at: doc(200, 200)))
        let b = try XCTUnwrap(editor.insertElement(.table(TableData.make(rows: 2, cols: 2)), size: CGSize(width: 200, height: 80), at: doc(200, 520)))
        editor.setTool(.select)
        editor.select(nil)
        let onA = FakeTouch(type: .direct, location: center(a)), onB = FakeTouch(type: .direct, location: center(b))
        let tap = try XCTUnwrap(editor.tapGesture), pan = try XCTUnwrap(editor.toolPan)
        XCTAssertFalse(editor.gestureRecognizer(tap, shouldReceive: onA), "沒選起來的不能用手指選")
        XCTAssertFalse(editor.gestureRecognizer(try XCTUnwrap(editor.doubleTapGesture), shouldReceive: onA))
        XCTAssertTrue(editor.gestureRecognizer(tap, shouldReceive: FakeTouch(type: .pencil, location: center(a))), "Pencil 照樣可以選")

        editor.select(a)
        XCTAssertTrue(editor.gestureRecognizer(tap, shouldReceive: onA), "選起來的可以點")
        XCTAssertTrue(editor.gestureRecognizer(pan, shouldReceive: onA), "選起來的可以拖")
        XCTAssertFalse(editor.gestureRecognizer(tap, shouldReceive: onB), "旁邊沒選的還是不能選")
        XCTAssertFalse(editor.gestureRecognizer(pan, shouldReceive: FakeTouch(type: .direct, location: doc(400, 760))), "空白處是捲動")

        // 筆：手指點表格也不會選起來
        editor.select(nil)
        editor.setTool(.pen)
        XCTAssertFalse(editor.gestureRecognizer(tap, shouldReceive: onA))

        // 開了「用手指書寫」：手指和 Pencil 一樣
        EditorSettings.shared.fingerDrawing = true
        editor.setTool(.select)
        XCTAssertTrue(editor.gestureRecognizer(tap, shouldReceive: onB))
    }

    func testAFingerDragsTheSelectedCircuitPartEvenInWireMode() throws {
        var d = CircuitData()
        let part = CircuitComponent(part: .resistor, position: CGPoint(x: 120, y: 120))
        d.components = [part]
        let ref = try XCTUnwrap(editor.insertElement(.circuit(d), size: CGSize(width: 240, height: 200), at: doc(300, 300)))
        editor.setTool(.circuit)
        editor.selectCircuitMode(.wire)
        func data() -> CircuitData? { editor.circuitInfo(ref)?.data }
        let start = editor.circuitDoc(try XCTUnwrap(data()?.components.first).position, ref)
        let finger = FakeTouch(type: .direct, location: start)
        XCTAssertFalse(editor.gestureRecognizer(try XCTUnwrap(editor.toolPan), shouldReceive: finger), "沒選起來：手指是捲動")
        editor.circuitTarget = ref
        editor.circuitSel = .component(part.id)
        XCTAssertTrue(editor.gestureRecognizer(try XCTUnwrap(editor.toolPan), shouldReceive: finger), "選起來的可以用手指拖")
        let h = try XCTUnwrap(editor.circuitPartHandleCenters())
        XCTAssertTrue(editor.gestureRecognizer(try XCTUnwrap(editor.tapGesture), shouldReceive: FakeTouch(type: .direct, location: h.rotate)),
                      "旁邊的旋轉按鈕也可以用手指點")

        let g = TouchPan()
        editor.toolPan = g
        editor.toolPanByDrawingTouch = false
        let s = try XCTUnwrap(data()).scale
        g.drag(from: start, to: CGPoint(x: start.x, y: start.y + 40 * s)) { editor.handleCircuitPan($0, $0.location(in: nil)) }
        // 放開後電路圖會重新整理座標（內容貼齊外框），所以比頁面上的位置
        let moved = editor.circuitDoc(try XCTUnwrap(data()?.components.first).position, ref)
        XCTAssertEqual(moved.y - start.y, 40 * s, accuracy: 0.5, "接線模式下手指也是拖動選起來的元件")
        XCTAssertEqual(moved.x, start.x, accuracy: 0.5)
        XCTAssertTrue(data()?.wires.isEmpty ?? false, "沒有畫出導線")
    }

    // MARK: 縮放回彈

    /// 放到最大再拉、放開後系統用動畫縮回來：頁面要跟著同一個動畫，不能一下就跳到最後的大小
    func testThePagesFollowAnAnimatedZoom() {
        let z = editor.canvas.zoomScale
        editor.pagesContainer.layer.removeAllAnimations()
        editor.canvas.zoomScale = z * 1.2
        XCTAssertNil(editor.pagesContainer.layer.animationKeys(), "不在動畫裡：直接縮放")
        UIView.animate(withDuration: 0.4) { self.editor.canvas.zoomScale = z }
        XCTAssertTrue(editor.pagesContainer.layer.animationKeys()?.contains("transform") ?? false, "頁面跟著動畫縮放")
        XCTAssertEqual(editor.pagesContainer.transform.a, editor.canvas.zoomScale, accuracy: 0.0001)
        spin(0.6)
    }

    // MARK: 電路圖

    /// 回報的問題：框選後拖動，接在一起的地方沒有拉出線。被拖的導線線頭接在沒動的接腳、導線（T 字）上
    func testAMovedWireStaysConnectedWhereItsEndsTouched() throws {
        var d = CircuitData()
        let r = CircuitComponent(part: .resistor, position: CGPoint(x: 100, y: 100))   // 接腳 (70,100) (130,100)
        let w = CircuitWire(points: [CGPoint(x: 130, y: 100), CGPoint(x: 200, y: 100)])
        let t = CircuitWire(points: [CGPoint(x: 200, y: 40), CGPoint(x: 200, y: 160)])   // w 的線頭在它中間：T 字
        d.components = [r]
        d.wires = [w, t]
        let before = d.nets()
        XCTAssertEqual(before.pins[1], before.wires[0])
        XCTAssertEqual(before.wires[0], before.wires[1], "測試前提：T 字接在一起")
        d.moveItems([w.id], by: CGPoint(x: 40, y: 40))
        XCTAssertEqual(d.wires.count, 4, "兩個線頭各拉一條線")
        let n = d.nets()
        let wi = try XCTUnwrap(d.wires.firstIndex { $0.id == w.id }), ti = try XCTUnwrap(d.wires.firstIndex { $0.id == t.id })
        XCTAssertEqual(n.pins[1], n.wires[wi], "電阻還接著")
        XCTAssertEqual(n.wires[ti], n.wires[wi], "T 字還接著")
        XCTAssertNotEqual(n.pins[0], n.wires[wi])
    }

    func testNewCategoriesAndAskingWhereANewSymbolGoes() throws {
        let store = CustomCircuitStore.shared
        let key = store.addCategory("我的分類")
        defer { store.removeCategory(key) }
        XCTAssertTrue(CircuitLibraryView.allSections.contains { $0.key == key && $0.name == "我的分類" })
        XCTAssertNil(try XCTUnwrap(CircuitLibraryView.sectionChoices.first).key, "第一個是自訂電路圖")
        editor.setTool(.circuit)
        XCTAssertEqual(CircuitLibraryView.allSections.count, CircuitLibraryView.sections.count + store.categories.count)
        XCTAssertEqual(editor.circuitLibrary.sectionBodies.count, CircuitLibraryView.allSections.count, "元件庫多一個分類")

        // 畫完符號按「下一步」選分類的流程見 EditorRequestsNov18Tests
        let symbol = CircuitSymbol(strokes: [.init(points: [CGPoint(x: -20, y: 0), CGPoint(x: 20, y: 0)])], pins: [CGPoint(x: -20, y: 0)])
        editor.saveCustomSymbol(id: nil, name: "OTA", symbol: symbol, section: key)
        let c = try XCTUnwrap(store.circuits.last)
        defer { store.remove(c.id) }
        XCTAssertEqual(c.section, key)
        XCTAssertEqual(CircuitLibraryView.customCircuits(in: key, from: store.circuits).map(\.id), [c.id])
        XCTAssertFalse(CircuitLibraryView.customCircuits(in: nil, from: store.circuits).contains { $0.id == c.id })
        store.removeCategory(key)
        XCTAssertNil(store.circuit(c.id)?.section, "刪掉分類：回到自訂電路圖")
        XCTAssertTrue(CircuitLibraryView.customCircuits(in: nil, from: store.circuits).contains { $0.id == c.id })
    }

    func testCircuitSelectionModes() throws {
        let saved = editor.settings.circuitLassoMode
        defer { editor.settings.circuitLassoMode = saved }
        let cw = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)]
        let ccw = Array(cw.reversed())
        for (mode, cwCrossing, ccwCrossing) in [("default", false, true), ("reversed", true, false), ("window", false, false), ("crossing", true, true)] {
            editor.settings.circuitLassoMode = mode
            XCTAssertEqual(editor.circuitLassoIsCrossing(cw), cwCrossing, mode)
            XCTAssertEqual(editor.circuitLassoIsCrossing(ccw), ccwCrossing, mode)
        }
        func find(_ items: [UIMenuElement]) -> UIMenu? {
            for e in items {
                guard let m = e as? UIMenu else { continue }
                if m.title == "電路圖選取模式" { return m }
                if let inner = find(m.children) { return inner }
            }
            return nil
        }
        let menu = try XCTUnwrap(find(editor.makeSettingsMenuItems()), "「⋯」裡有「電路圖選取模式」")
        XCTAssertEqual(menu.children.map(\.title), ["預設選取模式", "反轉選取模式", "僅窗選", "僅交集選取"])
        editor.settings.circuitLassoMode = "window"
        let checked = find(editor.makeSettingsMenuItems())?.children.compactMap { $0 as? UIAction }.filter { $0.state == .on }.map(\.title)
        XCTAssertEqual(checked, ["僅窗選"])
    }

    func testTheCircuitMenuHasNoFixPositionItem() throws {
        var d = CircuitData()
        d.components = [CircuitComponent(part: .resistor, position: CGPoint(x: 100, y: 100))]
        let ref = try XCTUnwrap(editor.insertElement(.circuit(d), size: CGSize(width: 200, height: 200), at: doc(300, 300)))
        let titles = editor.elementMenu(ref, at: center(ref)).children.map(\.title)
        XCTAssertFalse(titles.contains("固定位置"), "左上角有鎖頭")
        XCTAssertFalse(titles.contains("解除固定"))
        XCTAssertTrue(titles.contains("編輯電路"))
    }
}
