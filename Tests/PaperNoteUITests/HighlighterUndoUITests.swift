import XCTest

/// 回報的問題：畫完螢光筆、按上一步拿掉，再用螢光筆畫一筆，筆離開螢幕時剛才拿掉的又跑出來。
/// 螢光筆用的是 PencilKit 真正的書寫流程，單元測試模擬不了，這裡用手指在模擬器上真的畫
final class HighlighterUndoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // 手指可以寫；不要停住變直線、不要對齊 PDF 文字，只看最單純的一筆
        app.launchArguments = ["-uiTestNotebook", "-fingerDrawing", "<true/>", "-shapeSnap", "<false/>", "-smartHighlight", "<false/>"]
        app.launch()
    }

    private var strokes: String { app.descendants(matching: .any)["pkStrokes"].label }
    private var log: String { app.descendants(matching: .any)["debugTail"].label }

    private func waitForStrokes(_ n: Int, timeout: TimeInterval = 5) -> Bool {
        let p = NSPredicate(format: "label == %@", "\(n)")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: app.descendants(matching: .any)["pkStrokes"])], timeout: timeout) == .completed
    }

    private func draw(y: CGFloat) {
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: y))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: y + 0.03))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0)
    }

    func testUndoneHighlightDoesNotComeBackWithTheNextOne() {
        XCTAssertTrue(app.buttons["螢光筆"].waitForExistence(timeout: 20), "要打開測試用的筆記本")
        app.buttons["螢光筆"].tap()
        XCTAssertTrue(waitForStrokes(0))

        draw(y: 0.4)
        XCTAssertTrue(waitForStrokes(1), "畫了一筆：\(strokes)｜\(log)")
        sleep(1)
        app.buttons["上一步"].tap()
        XCTAssertTrue(waitForStrokes(0), "上一步拿掉：\(strokes)｜\(log)")

        draw(y: 0.55)
        XCTAssertTrue(waitForStrokes(1), "只有新的這一筆：\(strokes)｜\(log)")
        sleep(2)
        XCTAssertEqual(strokes, "1", "過一下也不會跑回來｜\(log)")
    }
}
