import XCTest
@testable import PaperNote

/// 防誤觸：寫完字馬上用手指滑頁面要能捲動，壓在筆尖旁的手掌要擋住
final class PalmRejectionTests: XCTestCase {
    private var window: UIWindow!
    private var editor: NotebookViewController!
    private var notebookID: UUID!
    private var modeBefore = "right"

    override func setUpWithError() throws {
        modeBefore = EditorSettings.shared.palmRejection
        EditorSettings.shared.palmRejection = "right"
        let meta = LibraryStore.shared.createNotebook(title: "PalmTest", folder: nil, paper: .blank, landscape: false)
        notebookID = meta.id
        editor = NotebookViewController(session: try NotebookSession(id: meta.id), initialPageID: nil, onClose: {})
        window = try TestWindow.make()
        window.rootViewController = editor
        window.makeKeyAndVisible()
        editor.view.layoutIfNeeded()
    }

    override func tearDown() {
        EditorSettings.shared.palmRejection = modeBefore
        window.isHidden = true
        window = nil
        editor = nil
        LibraryStore.shared.deleteNotebook(notebookID)
        super.tearDown()
    }

    /// 筆剛在 (500, 600) 離開螢幕 seconds 秒
    private func pencilLifted(_ seconds: CFTimeInterval, at p: CGPoint = CGPoint(x: 500, y: 600)) {
        editor.pencilDown = false
        editor.lastPencilPoint = p
        editor.lastPencilTime = CACurrentMediaTime() - seconds
    }

    /// 回報的問題：開右手防誤觸，寫完字用手指滑很多下才捲得動。
    /// 使用者的手指觸碰大小（除錯紀錄裡的 r）有 31.3、41.7、52.1，常常在筆尖右下方滑
    func testUsersFingerRightAfterWritingIsNotAPalm() {
        for r in [31.3, 41.7, 52.1] as [CGFloat] {
            for t in [0.1, 0.5, 1.2] {
                pencilLifted(t)
                let finger = FakeTouch(type: .direct, radius: r, location: CGPoint(x: 620, y: 700))
                XCTAssertFalse(editor.isPalmTouch(finger), "筆離開 \(t) 秒後、半徑 \(r) 的手指被當成手掌")
            }
        }
    }

    func testPalmNextToThePenIsStillBlocked() {
        // 寫字中：手掌一定擋
        editor.pencilDown = true
        editor.lastPencilTime = CACurrentMediaTime()
        XCTAssertTrue(editor.isPalmTouch(FakeTouch(type: .direct, radius: 31.3, location: CGPoint(x: 620, y: 700))))
        // 剛寫完：筆尖右下方的大面積觸碰（手掌）
        pencilLifted(0.5)
        XCTAssertTrue(editor.isPalmTouch(FakeTouch(type: .direct, radius: 72.9, location: CGPoint(x: 620, y: 700))))
        // 很大的觸碰不管什麼時候都算手掌
        pencilLifted(100)
        XCTAssertTrue(editor.isPalmTouch(FakeTouch(type: .direct, radius: 93.8, location: CGPoint(x: 100, y: 100))))
    }

    func testOffMeansNothingIsAPalm() {
        EditorSettings.shared.palmRejection = "off"
        editor.pencilDown = true
        editor.lastPencilTime = CACurrentMediaTime()
        XCTAssertFalse(editor.isPalmTouch(FakeTouch(type: .direct, radius: 93.8)))
    }

    /// 回報的問題（11/20）：開右手防誤觸，右手放上去頁面會快速跑掉。實機的除錯紀錄（筆尖在 (500, 600)）：
    /// 手掌的觸碰半徑常常只有 31～62，跟手指差不多，但手放下去是好幾個觸碰一起出現
    func testAHandPutDownIsAPalmEvenWhenItsTouchesAreFingerSized() {
        // 寫完 6 秒後手放下：41.7、52.1、62.6 三個一起（62.6 比手指最大的 52.1 大一格）
        pencilLifted(6.0)
        XCTAssertTrue(editor.isPalmTouch(FakeTouch(type: .direct, radius: 62.6, location: CGPoint(x: 498, y: 674))), "比手指大一格")
        XCTAssertTrue(editor.isPalmTouch(FakeTouch(type: .direct, radius: 41.7, location: CGPoint(x: 583, y: 756)), together: 3), "三個一起按下")
        // 寫完 0.9 秒：三個 52.1 一起
        pencilLifted(0.9)
        XCTAssertTrue(editor.isPalmTouch(FakeTouch(type: .direct, radius: 52.1, location: CGPoint(x: 764, y: 614)), together: 3))
    }

    /// 回報的問題（11/26）：手一拿開就兩指縮放，常常縮放不了。縮放的地方通常就是剛寫完的字，
    /// 兩根手指一前一後放下，第二根放下時「兩個一起、剛寫完、在筆尖右下方」就被當成手掌。
    /// 防誤觸不看筆離開多久：筆離開螢幕之後才放下的兩根手指，一律可以捲動、縮放
    func testPinchingRightWhereYouJustWroteZooms() {
        for t in [0.05, 0.3, 0.58, 1.0, 1.4] {
            pencilLifted(t)
            // 第一根在筆尖右下方，第二根再右下一點（兩指張開）
            XCTAssertFalse(editor.isPalmTouch(FakeTouch(type: .direct, radius: 41.7, location: CGPoint(x: 560, y: 650))),
                           "筆離開 \(t) 秒：第一根手指")
            XCTAssertFalse(editor.isPalmTouch(FakeTouch(type: .direct, radius: 52.1, location: CGPoint(x: 680, y: 760)), together: 2),
                           "筆離開 \(t) 秒：第二根手指")
        }
    }

    /// 寫字時就壓在螢幕上的手：筆抬起來換下一個字，手還壓著，一直算手掌到手離開為止
    func testAHandRestingWhileWritingStaysAPalmAfterThePencilLifts() {
        editor.pencilDown = true
        editor.lastPencilTime = CACurrentMediaTime()
        let hand = FakeTouch(type: .direct, radius: 41.7, location: CGPoint(x: 620, y: 720))
        editor.palmBlocker.touchesBegan([hand], with: FakeEvent([hand]))
        XCTAssertTrue(editor.palmBlocker.holdingPalm)
        pencilLifted(0.2)
        let other = FakeTouch(type: .direct, radius: 41.7, location: CGPoint(x: 700, y: 760))
        editor.palmBlocker.touchesBegan([other], with: FakeEvent([hand, other]))
        XCTAssertTrue(editor.palmBlocker.holdingPalm, "手還壓著，頁面不能被捲動、縮放")
        XCTAssertEqual(editor.palmBlocker.state, .began)
        editor.palmBlocker.touchesEnded([hand, other], with: FakeEvent([hand, other]))
    }

    func testFingersStillScrollAndZoom() {
        // 寫完馬上一個手指滑（之前的需求）
        pencilLifted(0.5)
        XCTAssertFalse(editor.isPalmTouch(FakeTouch(type: .direct, radius: 52.1, location: CGPoint(x: 620, y: 700))))
        // 紀錄裡真的兩指縮放：很久沒寫字；寫完 1.7 秒在右邊縮放
        pencilLifted(80)
        XCTAssertFalse(editor.isPalmTouch(FakeTouch(type: .direct, radius: 52.1, location: CGPoint(x: 620, y: 700)), together: 2))
        XCTAssertFalse(editor.isPalmTouch(FakeTouch(type: .direct, radius: 41.7, location: CGPoint(x: 478, y: 592)), together: 2))
        pencilLifted(1.73)
        XCTAssertFalse(editor.isPalmTouch(FakeTouch(type: .direct, radius: 31.3, location: CGPoint(x: 1008, y: 766)), together: 2))
        // 寫完 0.58 秒，在筆尖的另一邊（左手）兩指縮放
        pencilLifted(0.58)
        XCTAssertFalse(editor.isPalmTouch(FakeTouch(type: .direct, radius: 41.7, location: CGPoint(x: 250, y: 700)), together: 2))
    }

    func testThreeTouchesLandingTogetherKeepThePageStill() {
        // 擋住捲動、縮放的辨識器：三個一起按下（手放下去）就開始，頁面不會跟著滑
        pencilLifted(6.0)
        let hand = Set([41.7, 52.1, 52.1].enumerated().map { i, r in
            FakeTouch(type: .direct, radius: r, location: CGPoint(x: 580 + CGFloat(i) * 30, y: 760)) as UITouch
        })
        editor.palmBlocker.touchesBegan(hand, with: FakeEvent(hand))
        XCTAssertEqual(editor.palmBlocker.state, .began)
        XCTAssertTrue(editor.palmBlocker.holdingPalm)
        editor.palmBlocker.touchesEnded(hand, with: FakeEvent(hand))
    }

}
