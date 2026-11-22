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
        // 點表格真正在螢幕上的位置：捲到哪裡、螢幕多大都不一定
        let spot = app.descendants(matching: .any)["tablePoint"]
        var point: [Double] = []
        let ready = Date().addingTimeInterval(10)
        while Date() < ready {
            let now = spot.label.split(separator: ",").compactMap { Double($0) }
            // 版面排好、位置不再變
            if now.count == 2, now == point { break }
            point = now
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        }
        guard point.count == 2 else { return XCTFail("表格要在畫面上｜\(spot.label)") }
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point[0], dy: point[1])).doubleTap()
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
