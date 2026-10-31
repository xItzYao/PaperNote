import XCTest
@testable import PaperNote

/// 資料庫：選資料夾的清單、拖進資料夾（移動）
final class LibraryMoveTests: XCTestCase {
    private let store = LibraryStore.shared
    private var folders: [UUID] = []
    private var notebooks: [UUID] = []

    override func tearDown() {
        for id in notebooks { store.deleteNotebook(id) }
        for id in folders.reversed() { store.deleteFolder(id) }
        super.tearDown()
    }

    private func folder(_ name: String, in parent: UUID?) -> UUID {
        let f = store.createFolder(name: name, parent: parent)
        folders.append(f.id)
        return f.id
    }

    private func notebook(_ title: String, in folder: UUID?) -> UUID {
        let n = store.createNotebook(title: title, folder: folder, paper: .blank, landscape: false)
        notebooks.append(n.id)
        return n.id
    }

    /// 回報的需求：選資料夾時不要全部展開，點 ＞ 才列出子資料夾
    func testFolderPickerStartsCollapsed() throws {
        let top = folder("LibraryMoveTests 上層 \(UUID().uuidString.prefix(6))", in: nil)
        let child = folder("子資料夾", in: top)
        let grandchild = folder("孫資料夾", in: child)

        let collapsed = store.folderRows(expanded: [])
        let row = try XCTUnwrap(collapsed.first { $0.folder.id == top })
        XCTAssertTrue(row.hasChildren, "有子資料夾：顯示 ＞")
        XCTAssertEqual(row.depth, 0)
        XCTAssertFalse(collapsed.contains { $0.folder.id == child }, "一開始不列出子資料夾")

        let open = store.folderRows(expanded: [top])
        let ids = open.map(\.folder.id)
        let i = try XCTUnwrap(ids.firstIndex(of: top))
        XCTAssertEqual(ids[i + 1], child, "展開：子資料夾排在下面")
        XCTAssertEqual(open[i + 1].depth, 1)
        XCTAssertTrue(open[i + 1].hasChildren)
        XCTAssertFalse(ids.contains(grandchild), "只展開一層")

        XCTAssertFalse(store.folderRows(expanded: [top, child]).first { $0.folder.id == grandchild }?.hasChildren ?? true,
                       "沒有子資料夾：不顯示 ＞")
    }

    /// 回報的需求：拖進資料夾＝移進去；裡面已經有同名的就加上 (1)
    func testMovingIntoAFolderWithTheSameNameAddsANumber() throws {
        let dest = folder("LibraryMoveTests 目的地 \(UUID().uuidString.prefix(6))", in: nil)
        _ = notebook("講義", in: dest)
        let a = notebook("講義", in: nil)
        let b = notebook("講義", in: nil)
        let other = notebook("作業", in: nil)

        store.moveNotebook(a, to: dest)
        XCTAssertEqual(store.notebook(a)?.folderId, dest)
        XCTAssertEqual(store.notebook(a)?.title, "講義 (1)")
        store.moveNotebook(b, to: dest)
        XCTAssertEqual(store.notebook(b)?.title, "講義 (2)")
        store.moveNotebook(other, to: dest)
        XCTAssertEqual(store.notebook(other)?.title, "作業", "沒有重名：名稱不變")

        store.moveNotebook(a, to: dest)
        XCTAssertEqual(store.notebook(a)?.title, "講義 (1)", "放回同一個資料夾：不會再加號碼")
    }

    /// 回報的需求：資料庫的我的最愛是文件（筆記本旁的星星），不是頁面
    func testStarringANotebookAddsItToFavoriteDocuments() throws {
        let inFolder = folder("LibraryMoveTests 星號 \(UUID().uuidString.prefix(6))", in: nil)
        let a = notebook("要收藏的筆記", in: inFolder)
        let b = notebook("不收藏的筆記", in: nil)
        let modified = try XCTUnwrap(store.notebook(a)?.modified)
        store.setStarred(a, true)
        let starred = store.favoriteNotebooks.map(\.id)
        XCTAssertTrue(starred.contains(a), "資料夾裡的筆記本也會出現在我的最愛文件")
        XCTAssertFalse(starred.contains(b))
        XCTAssertEqual(store.notebook(a)?.modified, modified, "加星號不算修改")
        store.setStarred(a, false)
        XCTAssertFalse(store.favoriteNotebooks.map(\.id).contains(a))
    }

    /// 我的最愛文件的視窗：最近修改的排上面
    func testFavoriteDocumentsAreNewestFirst() throws {
        let older = notebook("舊的收藏", in: nil)
        let newer = notebook("新的收藏", in: nil)
        store.setStarred(older, true)
        store.setStarred(newer, true)
        store.updateMeta(older) { $0.modified = Date().addingTimeInterval(-60) }
        store.updateMeta(newer) { $0.modified = Date() }
        let ids = store.favoriteNotebooks.map(\.id)
        let i = try XCTUnwrap(ids.firstIndex(of: newer)), j = try XCTUnwrap(ids.firstIndex(of: older))
        XCTAssertLessThan(i, j)
    }

    /// 舊的資料庫沒有 starred：讀進來是沒收藏
    func testOldNotebooksAreNotStarred() throws {
        let json = ##"{"id":"\##(UUID().uuidString)","title":"舊筆記","coverHex":"#2654A0FF"}"##
        let meta = try JSONDecoder().decode(NotebookMeta.self, from: Data(json.utf8))
        XCTAssertFalse(meta.starred)
    }

    /// 回報的需求：日期一行放得下、24 小時制
    func testDatesAreOneLineAnd24Hour() throws {
        let d = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 23, minute: 5)))
        XCTAssertEqual(LibraryDate.dateTime(d), "2026/10/30 23:05")
        XCTAssertEqual(LibraryDate.day(d), "2026/10/30")
    }

    func testMovingAFolderWithTheSameNameAddsANumber() throws {
        let dest = folder("LibraryMoveTests 目的地 \(UUID().uuidString.prefix(6))", in: nil)
        _ = folder("期中考", in: dest)
        let moving = folder("期中考", in: nil)
        XCTAssertTrue(store.moveFolder(moving, to: dest))
        XCTAssertEqual(store.folder(moving)?.parentId, dest)
        XCTAssertEqual(store.folder(moving)?.name, "期中考 (1)")
    }
}
