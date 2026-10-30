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

    func testMovingAFolderWithTheSameNameAddsANumber() throws {
        let dest = folder("LibraryMoveTests 目的地 \(UUID().uuidString.prefix(6))", in: nil)
        _ = folder("期中考", in: dest)
        let moving = folder("期中考", in: nil)
        XCTAssertTrue(store.moveFolder(moving, to: dest))
        XCTAssertEqual(store.folder(moving)?.parentId, dest)
        XCTAssertEqual(store.folder(moving)?.name, "期中考 (1)")
    }
}
