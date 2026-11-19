import XCTest
import Translation
@testable import PaperNote

/// 回報的問題（11/19）：放到最大（回彈後）再放大，放開時頁面跳到左上角又很快滑回來。
/// 回彈是系統的動畫縮放：同一輪裡新加進來的頁面（看得到的範圍變了）也被套進動畫，從 (0,0) 飛到自己的位置
final class EditorRequestsNov19Tests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!

    override func setUpWithError() throws {
        let meta = LibraryStore.shared.createNotebook(title: "Nov19", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        let session = try NotebookSession(id: meta.id)
        for _ in 0..<11 { session.document.pages.append(Page(background: .paper(width: 595, height: 842, style: .grid))) }
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

    private func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private func animationKeys(_ v: UIView) -> [String] {
        (v.layer.animationKeys() ?? []).map { "\(type(of: v)).\($0)" } + v.subviews.flatMap(animationKeys)
    }

    func testPagesThatComeIntoViewDuringAnAnimatedZoomDoNotFlyInFromTheCorner() throws {
        let canvas = editor.canvas
        // 放很大、捲到中間的頁面：上下只留旁邊幾頁
        canvas.zoomScale = canvas.maximumZoomScale
        editor.scrollToPage(6, animated: false)
        spin(0.2)
        let before = Set(editor.pageViews.keys)

        // 回彈這類的動畫縮放（縮小一點，看得到的範圍變大，多出新的頁面）
        UIView.animate(withDuration: 0.4) { canvas.zoomScale = self.editor.fitZoom * 0.5 }
        let added = editor.pageViews.filter { !before.contains($0.key) }.map(\.value)
        XCTAssertFalse(added.isEmpty, "縮小後多出新的頁面（測試的前提）")
        XCTAssertTrue(editor.pagesContainer.layer.animationKeys()?.contains("transform") ?? false, "頁面整體跟著系統的動畫縮放")
        for v in added {
            XCTAssertEqual(animationKeys(v), [], "新加進來的頁面直接放在自己的位置，不是從左上角動畫過去")
            XCTAssertEqual(animationKeys(v.inkView), [])
        }
        XCTAssertEqual(animationKeys(editor.overlay), [], "選取框、控制點也不跟著飛")
        spin(0.6)
    }

    /// 回報的問題：PDF 選字翻譯有時閃退。閃退紀錄是 iPadOS 27.0.1 在翻譯視窗上面再跳系統的「下載語言」視窗時，
    /// UIKit 自己出錯（-[_UISceneHostingController _setSheetConfiguration:]）。原文語言猜錯就會碰到沒下載的語言。
    /// 只有已經下載的語言才交給系統翻；沒下載的在視窗裡說明，不讓系統跳下載視窗
    func testOnlyDownloadedLanguagesAreHandedToTheSystemTranslator() {
        XCTAssertEqual(TranslatePanel.readiness(.installed), .ready)
        XCTAssertEqual(TranslatePanel.readiness(.supported), .needsDownload, "沒下載：不翻（系統會跳下載視窗）")
        XCTAssertEqual(TranslatePanel.readiness(.unsupported), .unsupported)
    }
}
