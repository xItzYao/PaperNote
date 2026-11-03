import XCTest

/// 回報的問題：畫完螢光筆、按上一步拿掉，再用螢光筆畫一筆，筆離開螢幕時剛才拿掉的又跑出來。
/// 螢光筆用的是 PencilKit 真正的書寫流程，單元測試模擬不了，這裡用手指在模擬器上真的畫
final class HighlighterUndoUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ extra: [String] = []) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestNotebook", "-fingerDrawing", "<true/>"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["螢光筆"].waitForExistence(timeout: 20), "要打開測試用的筆記本")
        app.buttons["螢光筆"].tap()
        XCTAssertTrue(waitForStrokes(0))
    }

    private var strokes: String { app.descendants(matching: .any)["pkStrokes"].label }
    private var log: String { app.descendants(matching: .any)["debugTail"].label }

    private func waitForStrokes(_ n: Int, timeout: TimeInterval = 5) -> Bool {
        let p = NSPredicate(format: "label == %@", "\(n)")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: app.descendants(matching: .any)["pkStrokes"])], timeout: timeout) == .completed
    }

    /// hold：畫完停在終點不放（停住變直線）
    private func draw(y: CGFloat, hold: TimeInterval = 0) {
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: y))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: y + 0.03))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: hold)
    }

    private func check(hold: TimeInterval, waitBeforeUndo: UInt32, _ extra: [String] = []) {
        launch(extra)
        draw(y: 0.4, hold: hold)
        XCTAssertTrue(waitForStrokes(1), "畫了一筆：\(strokes)｜\(log)")
        if waitBeforeUndo > 0 { sleep(waitBeforeUndo) }
        app.buttons["上一步"].tap()
        XCTAssertTrue(waitForStrokes(0), "上一步拿掉：\(strokes)｜\(log)")

        draw(y: 0.55, hold: hold)
        XCTAssertTrue(waitForStrokes(1), "只有新的這一筆：\(strokes)｜\(log)")
        sleep(3)
        XCTAssertEqual(strokes, "1", "過一下也不會跑回來｜\(log)")
    }

    func testPlainStroke() {
        check(hold: 0, waitBeforeUndo: 1, ["-shapeSnap", "<false/>", "-smartHighlight", "<false/>"])
    }

    /// 預設設定（停住變直線、對齊 PDF 文字都開著）
    func testDefaultSettings() {
        check(hold: 0, waitBeforeUndo: 1)
    }

    /// 停住變直線，等直線換好才按上一步
    func testHeldLine() {
        check(hold: 1, waitBeforeUndo: 3)
    }

    /// 停住變直線，放開馬上按上一步
    func testHeldLineUndoneRightAway() {
        check(hold: 1, waitBeforeUndo: 0)
    }
}
