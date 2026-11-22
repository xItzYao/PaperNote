import XCTest
@testable import PaperNote

/// 回報的需求：頁碼選單「在此頁前新增頁面」下面加「將該頁加入大綱」，跳出視窗命名；
/// 「全部頁面」長按把該頁加入大綱；每頁右上角的星星按下去跳出備註，加入我的最愛
final class OutlineBookmarkTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "OutlineBookmarks", folder: nil, paper: .ruled, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        for _ in 0..<3 { session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .ruled))) }
        editor = NotebookViewController(session: session, initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
        spin(0.3)
    }

    override func tearDown() {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private var topAlert: UIAlertController? {
        var vc = editor.presentedViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc as? UIAlertController
    }

    func testThePageMenuHasAddToOutlineRightBelowAddingAPageBefore() throws {
        let titles = editor.makePageMenuItems().map(\.title)
        let before = try XCTUnwrap(titles.firstIndex(of: "在此頁前新增頁面…"))
        XCTAssertEqual(titles[safe: before + 1], "將該頁加入大綱…", "在「在此頁前新增頁面」下面：\(titles)")
        editor.promptAddToOutline(1)
        spin(0.5)
        let alert = try XCTUnwrap(topAlert, "跳出視窗為大綱命名")
        XCTAssertEqual(alert.title, "將該頁加入大綱")
        XCTAssertEqual(alert.textFields?.count, 1)
    }

    func testBookmarksFollowTheirPageAndAreSaved() throws {
        let p2 = editor.pages[2].id
        editor.addOutlineBookmark(pageIndex: 2, title: "第三章")
        editor.addOutlineBookmark(pageIndex: 0, title: "  ")
        XCTAssertEqual(editor.outlineBookmarks.map(\.bookmark.title), ["第 1 頁", "第三章"], "照頁面順序；沒取名用頁碼")
        XCTAssertEqual(editor.outlineBookmarks.last?.pageIndex, 2)
        editor.movePage(from: 2, to: 1)
        XCTAssertEqual(editor.outlineBookmarks.last?.pageIndex, editor.pageIndex(of: p2), "跟著那一頁移動")
        let id = try XCTUnwrap(editor.outlineBookmarks.last?.bookmark.id)
        editor.renameOutlineBookmark(id, to: "電路分析")
        // 重新打開筆記本還在
        let reopened = try NotebookSession(id: notebookID)
        XCTAssertEqual(reopened.document.outline?.map(\.title).sorted(), ["第 1 頁", "電路分析"])
        editor.removeOutlineBookmark(id)
        XCTAssertEqual(editor.outlineBookmarks.map(\.bookmark.title), ["第 1 頁"])
    }

    func testOldNotebooksWithoutAnOutlineStillOpen() throws {
        let json = #"{"version":1,"pages":[]}"#.data(using: .utf8)!
        let doc = try JSONDecoder.app.decode(NotebookDocument.self, from: json)
        XCTAssertNil(doc.outline)
    }

    private func presentOverview() throws -> PageOverviewController {
        let overview = PageOverviewController(editor: editor)
        editor.present(UINavigationController(rootViewController: overview), animated: false)
        spin(0.5)
        return overview
    }

    private func collection(_ overview: PageOverviewController) throws -> UICollectionView {
        func find(_ v: UIView) -> UICollectionView? {
            if let c = v as? UICollectionView { return c }
            for s in v.subviews { if let c = find(s) { return c } }
            return nil
        }
        let c = try XCTUnwrap(find(overview.view))
        c.layoutIfNeeded()
        return c
    }

    func testTheOutlineTabListsBookmarksAndJumpsToThem() throws {
        editor.addOutlineBookmark(pageIndex: 2, title: "第三章")
        let overview = try presentOverview()
        overview.filter.selectedSegmentIndex = PageOverviewController.outlineSegment
        overview.filter.sendActions(for: .valueChanged)
        XCTAssertEqual(overview.bookmarks.map(\.bookmark.title), ["第三章"])
        XCTAssertNil(overview.outlineTable.backgroundView, "有大綱")
        let ip = IndexPath(row: 0, section: PageOverviewController.bookmarkSection)
        XCTAssertEqual(overview.outlineEntry(at: ip)?.pageIndex, 2)
        XCTAssertEqual(overview.tableView(overview.outlineTable, titleForHeaderInSection: PageOverviewController.bookmarkSection), "我的大綱")
        let swipe = overview.tableView(overview.outlineTable, trailingSwipeActionsConfigurationForRowAt: ip)
        XCTAssertEqual(Set(swipe?.actions.compactMap(\.title) ?? []), ["刪除", "重新命名"], "往左滑可以重新命名、刪除")
        overview.openOutline(at: ip)
        spin(0.8)
        XCTAssertNil(editor.presentedViewController)
        XCTAssertEqual(editor.currentPageIndex, 2, "跳到那一頁")
    }

    func testLongPressingAPageWithoutDraggingAddsItToTheOutline() throws {
        let overview = try presentOverview()
        let c = try collection(overview)
        let cell = try XCTUnwrap(c.cellForItem(at: IndexPath(item: 1, section: 0)))
        let p = CGPoint(x: cell.frame.midX, y: cell.frame.midY)
        overview.handlePress(.began, at: p)
        overview.handlePress(.ended, at: CGPoint(x: p.x + 3, y: p.y + 2))
        spin(0.5)
        let alert = try XCTUnwrap(topAlert, "長按放開：跳出視窗命名")
        XCTAssertEqual(alert.title, "將該頁加入大綱")
        XCTAssertEqual(alert.message, "第 2 頁：幫這個大綱取個名字")
        alert.dismiss(animated: false)
        spin(0.3)
        // 長按拖曳是調整順序，不會加入大綱
        overview.handlePress(.began, at: p)
        overview.handlePress(.changed, at: CGPoint(x: p.x + 200, y: p.y))
        overview.handlePress(.ended, at: CGPoint(x: p.x + 200, y: p.y))
        spin(0.5)
        XCTAssertNil(topAlert, "拖曳不跳出命名")
    }

    func testEveryThumbnailHasAStarThatAddsTheFavoriteWithANote() throws {
        let overview = try presentOverview()
        let c = try collection(overview)
        let cell = try XCTUnwrap(c.cellForItem(at: IndexPath(item: 1, section: 0)) as? PageThumbCell)
        XCTAssertFalse(cell.starButton.isHidden, "還不是我的最愛也有星號")
        XCTAssertGreaterThanOrEqual(cell.starButton.frame.width, 44, "好點")
        XCTAssertGreaterThan(cell.starButton.frame.midX, cell.bounds.midX, "在右上角")
        XCTAssertLessThan(cell.starButton.frame.midY, cell.bounds.midY)
        cell.starButton.sendActions(for: .touchUpInside)
        spin(0.5)
        let alert = try XCTUnwrap(topAlert, "跳出備註")
        XCTAssertEqual(alert.title, "加入我的最愛")
        XCTAssertEqual(alert.textFields?.count, 1)
        alert.dismiss(animated: false)
        spin(0.3)
        XCTAssertFalse(editor.pages[1].favorite, "取消就不加")
    }
}
