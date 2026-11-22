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

    /// 每次捲動、縮放的通知裡，正在看的頁面、頁碼、算出來的可見範圍（CI 紀錄裡看順序用）
    private func watchZoom(_ id: UUID, _ log: @escaping (String) -> Void) -> NSKeyValueObservation {
        editor.canvas.observe(\.contentOffset) { [unowned self] c, _ in
            let r = self.editor.visibleDocRect()
            log("ZOOMLOG offset=\(Int(c.contentOffset.y)) zoom=\(String(format: "%.3f", c.zoomScale)) container=\(String(format: "%.3f", self.editor.pagesContainer.transform.a)) docY=\(Int(r.minY)) page=\(self.editor.pageLabel.text ?? "") viewed=\(self.editor.pageViews[id] != nil)")
        }
    }

    private func zoomDeepInTheNotebook() throws -> (UUID, PageContainerView) {
        editor.canvas.zoomScale = editor.canvas.maximumZoomScale
        editor.scrollToPage(8, animated: false)
        spin(0.2)
        let id = editor.session.document.pages[8].id
        return (id, try XCTUnwrap(editor.pageViews[id]))
    }

    /// 回報的問題（11/19）：放到最大，手指放開回彈時，頁面一瞬間全白。
    /// 回報的問題（11/20）：有些筆記放大縮小時閃全白，頁碼也亂跳（後面的頁面比較會）。
    /// 縮放時系統先改好縮放和捲動位置才通知；頁面的容器在縮放的通知裡才跟上。
    /// 中間的捲動通知用容器算可見範圍，就是拿新的捲動位置配舊的縮放：偏了好幾頁，
    /// 正在看的這一頁被拿掉又重建（新的頁面背景還沒畫好，是白的），頁碼也跳到別頁
    func testZoomingDeepInTheNotebookKeepsTheViewedPage() throws {
        let (id, viewed) = try zoomDeepInTheNotebook()
        let label = editor.pageLabel.text
        var pages: [String] = [], removed = false
        let watch = watchZoom(id) { line in
            print(line)
            pages.append(self.editor.pageLabel.text ?? "")
            if self.editor.pageViews[id] == nil { removed = true }
        }
        editor.canvas.setZoomScale(editor.canvas.zoomScale * 0.8, animated: false)
        watch.invalidate()
        XCTAssertFalse(removed, "縮放中正在看的頁面沒有被拿掉")
        XCTAssertTrue(editor.pageViews[id] === viewed, "正在看的頁面沒有重建（重建的背景一開始是白的）")
        XCTAssertEqual(Set(pages + [editor.pageLabel.text ?? ""]), [label ?? ""], "頁碼沒有跳")
    }

    /// 實機的除錯紀錄（PDF 第 60 頁，放到最大再放大、放開）：回彈的動畫裡系統先把縮放改成最後的值、通知捲動，
    /// 這時捲動位置還是放開前的，之後才改捲動位置、再通知一次：
    ///   didScroll z=8.253 off=5460,379288 → page+ 81, page- 60
    ///   didScroll z=8.253 off=3103,278439 → page+ 60, page- 81
    /// 正在看的第 60 頁被拿掉又重建，PDF 的背景要畫一下，那一瞬間是白的（空白筆記畫得快、頁數也少，看不出來）
    func testThePageBeingViewedIsNotRebuiltDuringTheZoomBounce() throws {
        let (id, viewed) = try zoomDeepInTheNotebook()
        let canvas = editor.canvas
        let z = canvas.zoomScale, z2 = z * 0.8
        let old = canvas.contentOffset
        let half = CGPoint(x: canvas.bounds.width / 2, y: canvas.bounds.height / 2)
        let final = CGPoint(x: (old.x + half.x) * z2 / z - half.x, y: (old.y + half.y) * z2 / z - half.y)
        var removed = false
        UIView.animate(withDuration: 0.25) {
            // 照實機的順序：縮放先到最後的值，捲動位置還是舊的
            canvas.zoomScale = z2
            canvas.contentOffset = old
            self.editor.scrollViewDidScroll(canvas)
            if self.editor.pageViews[id] == nil { removed = true }
            canvas.contentOffset = final
            self.editor.scrollViewDidZoom(canvas)
            if self.editor.pageViews[id] == nil { removed = true }
        }
        XCTAssertFalse(removed, "回彈途中正在看的頁面沒有被拿掉")
        XCTAssertTrue(editor.pageViews[id] === viewed, "正在看的頁面沒有重建（重建的背景要重畫，PDF 會白一下）")
        spin(0.5)
        editor.scrollViewDidEndZooming(canvas, with: nil, atScale: z2)
        XCTAssertTrue(editor.pageViews[id] === viewed)
        let far = editor.session.document.pages[10].id
        XCTAssertNil(editor.pageViews[far], "縮放結束後，回彈途中多加的（看不到的）頁面會拿掉")
    }

    /// 放到最大再放大、放開回彈時頁面閃一下：模擬器做不出來，除錯紀錄記下放開後每一格頁面畫在哪裡
    func testTheDebugLogTracesEveryFrameAfterTheFingersLift() throws {
        _ = try zoomDeepInTheNotebook()
        editor.zoomTrace.begin()
        editor.canvas.setZoomScale(editor.canvas.zoomScale * 0.8, animated: true)
        spin(0.9)
        let log = DebugLog.text
        XCTAssertTrue(log.contains("zoom: didZoom"), "縮放的通知")
        XCTAssertTrue(log.contains("zoom: +"), "每一格畫面")
        XCTAssertTrue(log.contains("keys=transform"), "頁面跟著系統的縮放動畫")
        XCTAssertFalse(editor.zoomTrace.isTracing, "記一下就停")
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
