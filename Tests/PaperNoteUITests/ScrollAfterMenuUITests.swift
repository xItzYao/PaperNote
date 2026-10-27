import XCTest

/// 用真的觸控操作 App（單元測試做不到的：系統選單、手勢之間的互動）
final class ScrollAfterMenuUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestNotebook"]
        app.launch()
    }

    private var indicator: XCUIElement { app.descendants(matching: .any)["pageIndicator"] }
    private var gestureDump: String { app.descendants(matching: .any)["gestureDump"].label }

    /// 在畫布中間往上（往後面的頁）或往下滑一下（有慣性）
    private func swipe(up: Bool = true) {
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.75 : 0.35))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.75))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func waitForPageChange(from label: String, timeout: TimeInterval = 4) -> Bool {
        let changed = NSPredicate(format: "label != %@", label)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: indicator)], timeout: timeout) == .completed
    }

    /// 回報的問題：打開工具列＋的選單後直接滑動，之後頁面就捲不動了，要切換工具才會好
    func testPageStillScrollsAfterSwipingWithTheInsertMenuOpen() {
        XCTAssertTrue(indicator.waitForExistence(timeout: 20), "要打開測試用的筆記本")
        // 平常捲得動
        let start = indicator.label
        swipe()
        swipe()
        XCTAssertTrue(waitForPageChange(from: start), "平常要捲得動（\(start)）")
        let normal = gestureDump

        // 打開＋的選單、開著直接滑，做兩次（系統可能重複用同一個手勢）
        for round in 1...2 {
            app.buttons["插入"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["文字框"].waitForExistence(timeout: 5), "＋的選單要打開")
            swipe(up: round == 1)
            sleep(1)

            let before = indicator.label
            for _ in 0..<3 { swipe(up: round != 1) }
            XCTAssertTrue(waitForPageChange(from: before),
                          "第 \(round) 次：選單關掉之後頁面要還能捲動（\(before)）。手指按下時的手勢：\(gestureDump)｜平常：\(normal)")
        }
    }
}
