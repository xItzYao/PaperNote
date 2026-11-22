import XCTest

/// 回報的問題（11/22）：手指點兩下表格要能編輯，不管有沒有開「用手指書寫」。
/// 在模擬器上真的點：單元測試測不到系統有沒有辨識出點兩下（寫字的手勢會先開始）
final class FingerDoubleTapUITests: XCTestCase {
    private func checkDoubleTapEdits(fingerDrawing: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "zh-Hant", "-uiTestNotebook", "-uiTestTable",
                               "-fingerDrawing", fingerDrawing ? "<true/>" : "<false/>"]
        app.launch()
        XCTAssertTrue(app.buttons["套索"].waitForExistence(timeout: 20), "要打開測試用的筆記本")
        // 表格在第一頁的上面（x 60…420、y 120…264，頁寬 595）
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.33)).doubleTap()
        let log = app.descendants(matching: .any)["debugTail"]
        let end = Date().addingTimeInterval(5)
        while Date() < end, !log.label.contains("double tap edit table") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(log.label.contains("double tap edit table"), "點兩下要進入編輯｜\(log.label)")
    }

    func testFingerDoubleTapEditsTheTable() {
        checkDoubleTapEdits(fingerDrawing: false)
    }

    func testFingerDoubleTapEditsTheTableWhenWritingWithFingers() {
        checkDoubleTapEdits(fingerDrawing: true)
    }
}
