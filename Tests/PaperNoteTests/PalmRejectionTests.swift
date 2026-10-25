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
}
