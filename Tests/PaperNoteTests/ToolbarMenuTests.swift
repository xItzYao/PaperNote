import XCTest
@testable import PaperNote

/// 回報的需求：
/// - 使用說明收進右上角「⋯」；工具列不放說明按鈕
/// - 頁面選單拿掉和工具列重複的「全部頁面」「跳到頁碼」「擴展此頁空白」
/// - 點頁碼直接輸入要跳到的頁碼
final class ToolbarMenuTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "ToolbarMenu", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        for _ in 0..<5 { session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid))) }
        session.save()
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func titles(_ items: [UIMenuElement]) -> [String] {
        items.flatMap { ($0 as? UIMenu).map { titles($0.children) } ?? [$0.title] }
    }

    private func allButtons(_ v: UIView) -> [UIButton] {
        (v as? UIButton).map { [$0] } ?? [] + v.subviews.flatMap(allButtons)
    }

    func testHelpLivesInTheMoreMenu() {
        let t = titles(editor.makeSettingsMenuItems())
        XCTAssertTrue(t.contains("使用說明…"), "「⋯」裡要有使用說明")
        XCTAssertEqual(t.last, "關於我…", "關於我在「⋯」最下面")
        XCTAssertFalse(t.contains("匯出…"), "匯出不在「⋯」裡")
        XCTAssertFalse(allButtons(editor.topBar).contains { $0.accessibilityLabel == "說明" }, "工具列不再放說明按鈕")
        let buttons = allButtons(editor.topBar)
        let export = buttons.firstIndex { $0.accessibilityLabel == "匯出" }
        let more = buttons.firstIndex { $0 === editor.settingsButton }
        XCTAssertNotNil(export, "匯出是「⋯」旁邊的一個按鈕")
        if let export, let more { XCTAssertEqual(export + 1, more, "匯出在「⋯」左邊") }
    }

    /// 選單最多兩層（選單 → 子選單），不要再往下一層
    private func depth(_ e: UIMenuElement) -> Int {
        guard let m = e as? UIMenu else { return 0 }
        let inner = m.children.map(depth).max() ?? 0
        return m.options.contains(.displayInline) ? inner : 1 + inner
    }

    func testMenusAreAtMostTwoLevels() throws {
        XCTAssertLessThanOrEqual(editor.makeSettingsMenuItems().map(depth).max() ?? 0, 1, "「⋯」選單")
        XCTAssertLessThanOrEqual(editor.makePageMenuItems().map(depth).max() ?? 0, 1, "頁面選單")
        let t = TableData.make(rows: 2, cols: 2)
        let o = editor.contentOrigin(0)
        let ref = try XCTUnwrap(editor.insertElement(.table(t), size: t.size, at: CGPoint(x: o.x + 200, y: o.y + 200)))
        let cell = CGPoint(x: o.x + 200, y: o.y + 200)
        XCTAssertLessThanOrEqual(editor.elementMenu(ref, at: cell).children.map(depth).max() ?? 0, 1, "長按表格格子的選單")
        XCTAssertLessThanOrEqual(editor.tableRowColItems().map(depth).max() ?? 0, 1, "表格標頭的選單")
    }

    func testPageMenuHasNoDuplicates() {
        let t = titles(editor.makePageMenuItems())
        for gone in ["全部頁面…", "跳到頁碼…", "擴展此頁空白…"] {
            XCTAssertFalse(t.contains(gone), "頁面選單不放「\(gone)」（工具列已經有）")
        }
        XCTAssertTrue(t.contains("在此頁後新增頁面…"))
    }

    func testTappingThePageNumberJumpsToTheTypedPage() throws {
        XCTAssertEqual(editor.currentPageIndex, 0)
        editor.pageLabelTapped()
        let field = try XCTUnwrap(editor.pageJumpField, "點頁碼要變成輸入框")
        XCTAssertFalse(field.isHidden)
        XCTAssertEqual(field.text, "1", "先放目前的頁碼")
        field.text = "4"
        editor.finishPageJump()
        XCTAssertTrue(field.isHidden)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(editor.currentPageIndex, 3, "跳到第 4 頁")
        // 超過範圍：到最後一頁
        editor.pageLabelTapped()
        field.text = "99"
        editor.finishPageJump()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(editor.currentPageIndex, editor.pages.count - 1)
    }
}
