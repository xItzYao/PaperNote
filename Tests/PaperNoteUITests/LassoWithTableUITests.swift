import XCTest

/// 回報的問題：加入表格後套索沒反應。在模擬器上真的用手指（開「用手指書寫」）拖套索
final class LassoWithTableUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launch(table: Bool) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "zh-Hant", "-uiTestNotebook", "-fingerDrawing", "<true/>"] + (table ? ["-uiTestTable"] : [])
        app.launch()
        XCTAssertTrue(app.buttons["套索"].waitForExistence(timeout: 20), "要打開測試用的筆記本")
    }

    private var log: String { app.descendants(matching: .any)["debugTail"].label }

    /// 斜斜拖過頁面上半部（表格在那裡）
    private func dragLasso(_ y: CGFloat) {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: y))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y + 0.25)),
                   withVelocity: .slow, thenHoldForDuration: 0)
    }

    private func waitForLog(_ text: String, after count: Int, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if log.components(separatedBy: text).count - 1 > count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func checkLasso(_ name: String, y: CGFloat) {
        let before = log.components(separatedBy: "lasso end").count - 1
        dragLasso(y)
        XCTAssertTrue(waitForLog("lasso end", after: before), "\(name)：套索要有反應｜\(log)")
    }

    func testLassoWorksWithATableOnThePage() {
        launch(table: true)
        app.buttons["套索"].tap()
        checkLasso("有表格", y: 0.12)
        // 換到筆再換回套索（回報的步驟）
        app.buttons["筆"].firstMatch.tap()
        app.buttons["套索"].tap()
        checkLasso("換回套索", y: 0.3)
    }

    func testLassoWorksOnAPlainPage() {
        launch(table: false)
        app.buttons["套索"].tap()
        checkLasso("沒有表格", y: 0.12)
    }
}
