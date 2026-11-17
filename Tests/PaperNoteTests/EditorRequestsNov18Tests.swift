import XCTest
import PencilKit
@testable import PaperNote

/// 回報的需求（11/18）：
/// - 電路圖自己加的分類刪不掉：元件庫長按分類跳出「刪除…」
/// - 畫自訂元件按「下一步」，下一頁像元件庫一樣看得到各分類和元件（可以展開、收合），選放哪裡
/// - 「⋯」分成四段；「管理常用筆刷」改「調色盤設定」；「清除畫面上所有貼圖」改「清除該頁面所有物件」；使用說明拿掉
/// - 匯出：留著打頁碼的欄位，加上縮圖勾選，兩邊同步
/// - 預覽模式不放「結束預覽」按鈕，長按頁面問要不要回到筆記模式
/// - 擴展頁面：手指按控制點拉不動，整頁被拖走
final class EditorRequestsNov18Tests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var savedFingerDrawing = false

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "Nov18", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        for _ in 0..<9 { session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid))) }
        session.save()
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
        editor.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private func doc(_ page: Int, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let o = editor.contentOrigin(page)
        return CGPoint(x: o.x + x, y: o.y + y)
    }

    private func buttons(_ v: UIView) -> [UIButton] {
        ((v as? UIButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons)
    }

    // MARK: 刪除分類

    func testLongPressingAUserCategoryOffersToDeleteIt() throws {
        let store = CustomCircuitStore.shared
        let key = store.addCategory("我的分類")
        defer { store.removeCategory(key) }
        let symbol = CircuitSymbol(strokes: [.init(points: [CGPoint(x: -20, y: 0), CGPoint(x: 20, y: 0)])], pins: [CGPoint(x: -20, y: 0)])
        let c = store.add(name: "OTA", data: CustomCircuit.symbolData(symbol))
        defer { store.remove(c.id) }
        store.move(c.id, toSection: key)
        editor.setTool(.circuit)
        let library = editor.circuitLibrary

        let menu = try XCTUnwrap(library.categoryMenu(key: key, name: "我的分類"), "自己加的分類有長按選單")
        XCTAssertEqual(menu.children.map(\.title), ["刪除「我的分類」"])
        XCTAssertNil(library.categoryMenu(key: "passive", name: "被動元件"), "內建分類不能刪")
        let headers = buttons(library).filter { $0.menu?.children.first?.title == "刪除「我的分類」" }
        XCTAssertEqual(headers.count, 2, "放左邊、放下面的分類標題都可以長按")

        let sections = library.sectionBodies.count
        library.onDeleteCategory?(key)
        spin(0.2)
        XCTAssertFalse(store.categories.contains { $0.key == key }, "分類刪掉了")
        XCTAssertNil(store.circuit(c.id)?.section, "裡面的元件還在，回到自訂電路圖")
        XCTAssertEqual(library.sectionBodies.count, sections - 1, "元件庫少一個分類")
    }

    // MARK: 畫完元件按「下一步」

    func testANewSymbolGoesToANextPageThatLooksLikeTheLibrary() throws {
        let store = CustomCircuitStore.shared
        let key = store.addCategory("我的分類")
        defer { store.removeCategory(key) }
        let symbol = CircuitSymbol(strokes: [.init(points: [CGPoint(x: -20, y: 0), CGPoint(x: 20, y: 0)])], pins: [CGPoint(x: -20, y: 0)])
        var saved = false
        var picked: String? = "none"
        let vc = CircuitSymbolEditorViewController(name: "OTA", symbol: symbol) { _, _ in saved = true }
        vc.asksForSection = true
        vc.onChooseSection = { picked = $0 }
        let nav = UINavigationController(rootViewController: vc)
        editor.present(nav, animated: false)
        spin(0.3)
        XCTAssertEqual(vc.navigationItem.rightBarButtonItems?.first?.title, "下一步", "新的元件：右上角是「下一步」")

        vc.finish()
        spin(0.6)
        let picker = try XCTUnwrap(nav.topViewController as? CircuitSectionPickerViewController, "下一頁選分類")
        XCTAssertFalse(saved, "還沒選分類不會存")
        XCTAssertEqual(picker.title, "放在哪個分類？")
        let names = picker.sections.map(\.name)
        XCTAssertEqual(names.first, "被動元件", "和元件庫一樣的順序")
        XCTAssertEqual(names.last, "自訂電路圖")
        XCTAssertTrue(names.contains("我的分類"))
        XCTAssertGreaterThan(try XCTUnwrap(picker.sections.first).tiles.count, 3, "看得到分類裡已經有的元件")
        XCTAssertNil(picker.selectedKey, "一開始放在自訂電路圖")
        let last = picker.bodies.count - 1
        XCTAssertTrue(try XCTUnwrap(picker.newTile).isDescendant(of: picker.bodies[last]), "新元件標在選好的分類")

        let mine = try XCTUnwrap(picker.sections.firstIndex { $0.key == key })
        picker.select(mine)
        XCTAssertEqual(picker.selectedKey, key)
        XCTAssertTrue(try XCTUnwrap(picker.newTile).isDescendant(of: picker.bodies[mine]), "新元件移到這個分類")
        XCTAssertFalse(picker.bodies[mine].isHidden, "選了就打開")
        XCTAssertTrue(picker.radioButtons[mine].accessibilityTraits.contains(.selected))

        // 展開、收合
        picker.toggleCollapsed(0)
        spin(0.3)
        let first = picker.bodies[0].isHidden
        picker.toggleCollapsed(0)
        spin(0.3)
        XCTAssertNotEqual(picker.bodies[0].isHidden, first, "標題點一下展開或收合")

        picker.doneTapped()
        XCTAssertEqual(picked, key)
        XCTAssertTrue(saved)
        spin(0.6)
    }

    func testEditingAnExistingSymbolStillJustSaysDone() {
        let vc = CircuitSymbolEditorViewController(name: "OTA", symbol: nil) { _, _ in }
        let nav = UINavigationController(rootViewController: vc)
        editor.present(nav, animated: false)
        spin(0.3)
        XCTAssertNotEqual(vc.navigationItem.rightBarButtonItems?.first?.title, "下一步", "改已經有的元件：直接完成")
    }

    // MARK: 「⋯」

    private func titles(_ items: [UIMenuElement]) -> [String] {
        items.flatMap { ($0 as? UIMenu).map { titles($0.children) } ?? [$0.title] }
    }

    func testTheMoreMenuIsGroupedByWhatItIsFor() throws {
        let items = editor.makeSettingsMenuItems()
        func section(_ name: String) -> [String] {
            titles((items.first { $0.title == name } as? UIMenu)?.children ?? [])
        }
        XCTAssertTrue(section("Apple Pencil 設定").contains("Pencil 點兩下時顯示調色盤圖示"))
        XCTAssertTrue(section("Apple Pencil 設定").contains("右手寫字"))
        XCTAssertTrue(section("書寫設定").contains("調色盤設定…"))
        XCTAssertTrue(section("書寫設定").contains("橡皮擦擦完自動切回筆"))
        XCTAssertTrue(section("電路圖設定").contains("預設選取模式"))
        XCTAssertTrue(section("電路圖設定").contains("電路元件庫放左邊"))
        XCTAssertTrue(section("其他").contains("清除該頁面所有物件"))
        let all = titles(items)
        XCTAssertFalse(all.contains("管理常用筆刷…"))
        XCTAssertFalse(all.contains("清除畫面上所有貼圖"))
        XCTAssertFalse(all.contains("使用說明…"))
    }

    func testClearingAPageRemovesEverythingOnItAndCanBeUndone() throws {
        let t = TableData.make(rows: 2, cols: 2)
        _ = try XCTUnwrap(editor.insertElement(.table(t), size: t.size, at: doc(0, 200, 200)))
        editor.updatePage(0) { $0.ink = [InkStroke(colorHex: "#000000FF", points: [InkPoint(CGPoint(x: 100, y: 500), width: 2), InkPoint(CGPoint(x: 300, y: 500), width: 2)])] }
        func stroke(_ a: CGPoint, _ b: CGPoint) -> PKStroke {
            let pts = (0...20).map { i -> PKStrokePoint in
                let k = CGFloat(i) / 20
                return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k), timeOffset: TimeInterval(i) / 100,
                                     size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
        }
        var d = editor.canvas.drawing
        d.strokes += [stroke(doc(0, 100, 300), doc(0, 300, 300)), stroke(doc(1, 100, 300), doc(1, 300, 300))]
        editor.setDrawing(d)
        spin(0.2)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 2)

        editor.clearPage(0)
        XCTAssertTrue(editor.pages[0].elements.isEmpty, "物件清掉")
        XCTAssertTrue(editor.pages[0].ink.isEmpty, "筆跡清掉")
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 1, "只清這一頁的筆跡，第 2 頁的還在")
        XCTAssertEqual(editor.nearestPageIndex(to: try XCTUnwrap(editor.canvas.drawing.strokes.first).renderBounds.center), 1)
        XCTAssertEqual(editor.pages.count, 10, "頁面本身留著")

        editor.undoTapped()
        spin(0.2)
        XCTAssertEqual(editor.pages[0].elements.count, 1, "上一步：回來")
        XCTAssertEqual(editor.pages[0].ink.count, 1)
        XCTAssertEqual(editor.canvas.drawing.strokes.count, 2)
    }

    // MARK: 匯出

    func testPageSelectionFormatting() {
        XCTAssertEqual(PageSelection.format([5], pageCount: 10), "6")
        XCTAssertEqual(PageSelection.format([5, 6], pageCount: 10), "6 7")
        XCTAssertEqual(PageSelection.format([0, 2, 5, 6, 7, 9], pageCount: 10), "1 3 6-8 10")
        XCTAssertEqual(PageSelection.format(Array(0..<10), pageCount: 10), "1-10")
        XCTAssertEqual(PageSelection.format([], pageCount: 10), "")
        for pages in [[0], [1, 2, 3], [0, 4, 5, 9]] {
            XCTAssertEqual(try PageSelection.parse(PageSelection.format(pages, pageCount: 10), pageCount: 10), pages, "寫回去再讀一樣")
        }
    }

    func testExportKeepsTheTextFieldAndTheCheckedPagesInSync() throws {
        let vc = ExportPagesViewController(session: editor.session)
        var exported: (Bool, [Int])?
        vc.onExport = { exported = ($0, $1) }
        editor.present(UINavigationController(rootViewController: vc), animated: false)
        spin(0.5)
        XCTAssertEqual(vc.field.text, "1-10", "一開始全部勾著")
        XCTAssertEqual(vc.selected.count, 10)

        // 打 6：第 6 頁勾起來
        vc.field.text = "6"
        vc.textChanged()
        XCTAssertEqual(vc.selected, [5])
        let cell6 = try XCTUnwrap(vc.collection.cellForItem(at: IndexPath(item: 5, section: 0)) as? PageThumbCell)
        XCTAssertTrue(cell6.checked, "縮圖上第 6 頁勾著")
        XCTAssertFalse(try XCTUnwrap(vc.collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? PageThumbCell).checked)

        // 勾第 7 頁：上面多寫 7
        vc.collectionView(vc.collection, didSelectItemAt: IndexPath(item: 6, section: 0))
        XCTAssertEqual(vc.field.text, "6 7")
        vc.toggle(7)
        XCTAssertEqual(vc.field.text, "6-8")
        vc.toggle(5)
        XCTAssertEqual(vc.field.text, "7 8", "取消也會同步")

        // 打到一半看不懂：勾選不動、不能匯出
        vc.field.text = "7-"
        vc.textChanged()
        XCTAssertEqual(vc.selected, [6, 7])
        XCTAssertNotNil(vc.textError)
        XCTAssertFalse(vc.pdfButton.isEnabled)
        vc.field.text = "2-4"
        vc.textChanged()
        XCTAssertEqual(vc.selected, [1, 2, 3])
        XCTAssertTrue(vc.pdfButton.isEnabled)

        // 清空：一頁都沒選，不能匯出
        vc.field.text = ""
        vc.textChanged()
        XCTAssertTrue(vc.selected.isEmpty)
        XCTAssertFalse(vc.paperNoteButton.isEnabled)

        vc.toggleAll()
        XCTAssertEqual(vc.field.text, "1-10")
        vc.field.text = "1 3"
        vc.textChanged()
        vc.export(paperNote: false)
        XCTAssertEqual(exported?.0, false)
        XCTAssertEqual(exported?.1, [0, 2], "匯出勾著的頁面")
    }

    // MARK: 預覽模式

    func testPreviewModeHasNoExitButtonAndALongPressAsksToGoBack() throws {
        editor.setTool(.pen)
        editor.setPreviewMode(true)
        XCTAssertFalse(buttons(editor.view).contains { $0.configuration?.title == "結束預覽" && !$0.isHidden && $0.window != nil },
                       "沒有「結束預覽」按鈕")
        XCTAssertTrue(editor.previewLongPress.isEnabled, "長按頁面")
        XCTAssertTrue(editor.previewLongPress.view === editor.canvas)
        editor.applyTool()
        XCTAssertTrue(editor.previewLongPress.isEnabled, "換工具、重設 PencilKit 手勢後還是開著")

        editor.askToLeavePreview()
        spin(0.3)
        let alert = try XCTUnwrap(editor.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "是否回到筆記模式？")
        XCTAssertEqual(alert.actions.map(\.title), ["取消", "回到筆記模式"])
        alert.dismiss(animated: false)
        spin(0.2)

        editor.setPreviewMode(false)
        XCTAssertFalse(editor.previewLongPress.isEnabled, "一般模式長按照原本的功能")
        XCTAssertEqual(editor.tool, .pen)
    }

    // MARK: 擴展頁面

    /// 回報的問題：擴展頁面時手指按控制點拉不動，整頁被拖走（手指只能動選起來的東西的規則沒算到控制點）
    func testAFingerOnAPageHandleResizesInsteadOfScrolling() throws {
        editor.setTool(.pageResize)
        editor.resizePageIndex = 0
        let corner = editor.pageHandlePoints(editor.pageResizeRects(0, insets: editor.pages[0].insets).full)[4]
        let pan = try XCTUnwrap(editor.toolPan)
        XCTAssertTrue(editor.gestureRecognizer(pan, shouldReceive: FakeTouch(type: .direct, location: corner)), "手指按在控制點上：拉控制點")
        XCTAssertFalse(editor.gestureRecognizer(pan, shouldReceive: FakeTouch(type: .direct, location: doc(0, 300, 400))), "頁面中間：捲動")
        XCTAssertTrue(editor.gestureRecognizer(try XCTUnwrap(editor.tapGesture), shouldReceive: FakeTouch(type: .direct, location: doc(1, 300, 400))),
                      "點別頁：換要擴展的頁面")

        // 拖曳要移動一小段才開始：開始時手指已經離開控制點，用剛按下的位置判斷
        let g = TouchPan()
        editor.toolPan = g
        let slop = CGPoint(x: 40 / editor.canvas.zoomScale, y: 0)
        g.point = CGPoint(x: corner.x + slop.x, y: corner.y)
        g.moved = slop
        XCTAssertTrue(editor.gestureRecognizerShouldBegin(g))
        let end = CGPoint(x: corner.x + 120, y: corner.y + 80)
        g.drag(from: corner, to: end, slop: slop) { editor.handleToolPan($0) }
        XCTAssertEqual(editor.pages[0].insets.right, 120, accuracy: 1, "往右拉")
        XCTAssertEqual(editor.pages[0].insets.bottom, 80, accuracy: 1, "往下拉")
    }
}
