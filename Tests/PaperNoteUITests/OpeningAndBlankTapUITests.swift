import XCTest

/// 回報的問題（11/23）：打開筆記本要停在最上面；手指點空白處要取消選取。
/// 一次開 App 測兩件事（每開一次要十幾秒）
final class OpeningAndBlankTapUITests: XCTestCase {
    func testOpensAtTheTopAndABlankTapClearsTheSelection() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "zh-Hant", "-uiTestNotebook", "-uiTestTable", "-fingerDrawing", "<false/>"]
        app.launch()
        guard app.buttons["套索"].waitForExistence(timeout: 20) else { return XCTFail("要打開測試用的筆記本") }
        let window = app.windows.firstMatch
        let spot = app.descendants(matching: .any)["tablePoint"]
        var point: [Double] = []
        let ready = Date().addingTimeInterval(10)
        while Date() < ready {
            let now = spot.label.split(separator: ",").compactMap { Double($0) }
            if now.count == 2, now == point { break }
            point = now
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        }
        let offset = app.descendants(matching: .any)["scrollOffset"].label
        XCTAssertLessThanOrEqual(abs(Int(offset) ?? 999), 1, "打開時要停在最上面（捲了 \(offset)）")
        guard point.count == 2 else { return XCTFail("表格要在畫面上｜\(spot.label)") }

        let origin = window.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: point[0], dy: point[1])).doubleTap()
        let log = app.descendants(matching: .any)["debugTail"]
        func waitFor(_ text: String) -> Bool {
            let end = Date().addingTimeInterval(8)
            while Date() < end {
                if log.label.contains(text) { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            return false
        }
        guard waitFor("double tap edit table") else { return XCTFail("先進入編輯｜\(log.label)") }
        // 表格右邊、同樣高度的空白處
        origin.withOffset(CGVector(dx: Double(window.frame.width) * 0.88, dy: point[1])).tap()
        XCTAssertTrue(waitFor("tap clears selection"), "點空白處要取消選取｜\(log.label)")
    }
}
