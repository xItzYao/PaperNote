import XCTest

/// 回報的問題：畫完螢光筆、按上一步拿掉，再用螢光筆畫一筆，筆離開螢幕時剛才拿掉的又跑出來。
/// 螢光筆用的是 PencilKit 真正的書寫流程，單元測試模擬不了，這裡用手指在模擬器上真的畫
final class HighlighterUndoUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(_ extra: [String] = [], tool: String = "螢光筆") {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "zh-Hant", "-uiTestNotebook", "-fingerDrawing", "<true/>"] + extra
        app.launch()
        XCTAssertTrue(app.buttons[tool].waitForExistence(timeout: 20), "要打開測試用的筆記本")
        app.buttons[tool].tap()
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

    /// 畫一筆、上一步、再畫一筆：只剩新的那一筆
    private func check(_ name: String, hold: TimeInterval, waitBeforeUndo: UInt32) {
        draw(y: 0.4, hold: hold)
        XCTAssertTrue(waitForStrokes(1), "\(name)：畫了一筆：\(strokes)｜\(log)")
        if waitBeforeUndo > 0 { sleep(waitBeforeUndo) }
        app.buttons["上一步"].tap()
        XCTAssertTrue(waitForStrokes(0), "\(name)：上一步拿掉：\(strokes)｜\(log)")

        draw(y: 0.55, hold: hold)
        XCTAssertTrue(waitForStrokes(1), "\(name)：只有新的這一筆：\(strokes)｜\(log)")
        sleep(3)
        XCTAssertEqual(strokes, "1", "\(name)：過一下也不會跑回來｜\(log)")
    }

    /// 下一個情況從空白的頁面開始
    private func clear(_ name: String) {
        app.buttons["上一步"].tap()
        XCTAssertTrue(waitForStrokes(0), "\(name)之後清掉：\(strokes)｜\(log)")
    }

    func testPlainStroke() {
        launch(["-shapeSnap", "<false/>", "-smartHighlight", "<false/>"])
        check("一般的一筆", hold: 0, waitBeforeUndo: 1)
    }

    /// 對照：PencilKit 的筆（不關自製筆刷時），不會被拉直
    func testPencilKitPen() {
        launch(["-customInk", "<false/>", "-shapeSnap", "<false/>"], tool: "筆")
        check("PencilKit 的筆", hold: 0, waitBeforeUndo: 1)
    }

    /// 預設設定（停住變直線、對齊 PDF 文字都開著）。設定一樣的情況在同一次啟動裡依序做，省下重開 App 的時間
    func testDefaultSettings() {
        launch()
        check("預設設定", hold: 0, waitBeforeUndo: 1)
        clear("預設設定")

        // 停住變直線，等直線換好才按上一步
        check("停住變直線", hold: 1, waitBeforeUndo: 3)
        clear("停住變直線")

        // 停住變直線，放開馬上按上一步
        check("停住變直線、馬上上一步", hold: 1, waitBeforeUndo: 0)
        clear("停住變直線、馬上上一步")

        // 上一步、下一步、再上一步，接著畫：下一步換回來的那一版也不會讓筆跡跑回來
        draw(y: 0.4)
        XCTAssertTrue(waitForStrokes(1), "下一步：畫了一筆：\(strokes)｜\(log)")
        sleep(1)
        app.buttons["上一步"].tap()
        XCTAssertTrue(waitForStrokes(0), "下一步：上一步：\(strokes)｜\(log)")
        app.buttons["下一步"].tap()
        XCTAssertTrue(waitForStrokes(1), "下一步：下一步：\(strokes)｜\(log)")
        app.buttons["上一步"].tap()
        XCTAssertTrue(waitForStrokes(0), "下一步：再上一步：\(strokes)｜\(log)")

        draw(y: 0.55)
        XCTAssertTrue(waitForStrokes(1), "下一步：只有新的這一筆：\(strokes)｜\(log)")
        sleep(3)
        XCTAssertEqual(strokes, "1", "下一步：過一下也不會跑回來｜\(log)")
    }
}
