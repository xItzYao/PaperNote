import XCTest
@testable import PaperNote

/// 回報的問題：從「檔案」用分享的方式以 PaperNote 打開 PDF，匯入了卻沒有打開。
/// 筆記本開著的時候分享進來：匯入後 TabStore 記下要打開新的那本，但分頁畫面沒有跟著換
final class SharedImportTabTests: XCTestCase {
    private var window: UIWindow!
    private var ids: [UUID] = []

    override func setUpWithError() throws {
        window = try TestWindow.make()
    }

    override func tearDown() {
        (window.rootViewController as? TabsViewController)?.exitToLibrary()
        window.isHidden = true
        window = nil
        for id in ids {
            TabStore.shared.close(id)
            LibraryStore.shared.deleteNotebook(id)
        }
        super.tearDown()
    }

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private func notebook(_ title: String) -> UUID {
        let id = LibraryStore.shared.createNotebook(title: title, folder: nil, paper: .blank, landscape: false).id
        ids.append(id)
        return id
    }

    func testOpeningANotebookWhileTheTabsAreShowingSwitchesToIt() {
        let a = notebook("開著的"), b = notebook("分享進來的")
        TabStore.shared.open(a, page: nil)
        let tabs = TabsViewController()
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        tabs.view.layoutIfNeeded()
        spin(0.3)
        XCTAssertEqual(tabs.shownNotebookID, a)

        // 匯入完成後 RootView.open 做的事
        TabStore.shared.open(b, page: nil)
        spin(0.3)
        XCTAssertEqual(tabs.shownNotebookID, b, "切到剛匯入的筆記本")
        XCTAssertEqual(TabStore.shared.state.active, b)

        // 已經開著的那本：切回去
        TabStore.shared.open(a, page: nil)
        spin(0.3)
        XCTAssertEqual(tabs.shownNotebookID, a)
    }
}
