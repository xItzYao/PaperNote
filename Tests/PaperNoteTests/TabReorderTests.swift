import XCTest
@testable import PaperNote

/// 分頁列長按拖曳排序
final class TabReorderTests: XCTestCase {
    private let store = TabStore.shared
    private var ids: [UUID] = []
    private var savedState: Data?

    override func setUp() {
        super.setUp()
        savedState = UserDefaults.standard.data(forKey: "tabs.state.v1")
        // 先清空，再開 a b c d 四個分頁
        for t in store.state.tabs { store.close(t.notebookID) }
        ids = (0..<4).map { _ in UUID() }
        for id in ids { store.open(id, page: nil) }
    }

    override func tearDown() {
        for id in ids { store.close(id) }
        if let savedState { UserDefaults.standard.set(savedState, forKey: "tabs.state.v1") }
        super.tearDown()
    }

    private var order: [UUID] { store.state.tabs.map(\.notebookID) }
    private func group(_ id: UUID) -> UUID? { store.state.tabs.first { $0.notebookID == id }?.groupID }

    func testMoveBeforeAndAfter() {
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        XCTAssertEqual(order, [a, b, c, d])
        store.reorder(d, next: a, after: false)
        XCTAssertEqual(order, [d, a, b, c])
        store.reorder(d, next: b, after: true)
        XCTAssertEqual(order, [a, b, d, c])
        store.reorder(a, next: nil, after: false)
        XCTAssertEqual(order, [b, d, c, a], "放到最後")
        store.reorder(a, next: a, after: true)
        XCTAssertEqual(order, [b, d, c, a], "放回自己旁邊不變")
    }

    func testDroppingBetweenGroupedTabsJoinsGroup() {
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        let g = store.createGroup(name: "G", with: a)
        store.move(b, to: g.id)
        XCTAssertEqual(order, [a, b, c, d])
        store.reorder(d, next: a, after: true)
        XCTAssertEqual(order, [a, d, b, c])
        XCTAssertEqual(group(d), g.id, "放在群組中間就加入群組")
    }

    /// 回報的問題：在群組裡的分頁開著時打開新筆記本，新分頁插進群組中間。新分頁一律放在最右邊
    func testNewTabOpensAtTheFarRight() {
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        let g = store.createGroup(name: "G", with: a)
        store.move(b, to: g.id)
        store.activate(a)
        let e = UUID()
        ids.append(e)
        store.open(e, page: nil)
        XCTAssertEqual(order, [a, b, c, d, e])
        XCTAssertNil(group(e), "新分頁不屬於任何群組")
        XCTAssertEqual(store.state.active, e)
    }

    func testDroppingAtGroupEdgeKeepsOutsiders() {
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        let g = store.createGroup(name: "G", with: a)
        store.move(b, to: g.id)
        store.reorder(d, next: a, after: false)
        XCTAssertEqual(order, [d, a, b, c])
        XCTAssertNil(group(d), "放在群組前面不加入")
        // 群組裡的分頁拖到群組最前面：還在群組裡
        store.reorder(b, next: a, after: false)
        XCTAssertEqual(order, [d, b, a, c])
        XCTAssertEqual(group(b), g.id)
        // 拖到群組外面：移出群組
        store.reorder(b, next: c, after: true)
        XCTAssertEqual(order, [d, a, c, b])
        XCTAssertNil(group(b))
    }
}
