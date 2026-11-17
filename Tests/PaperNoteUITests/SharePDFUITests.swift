import XCTest

/// 回報的問題：從「檔案」用分享的方式以 PaperNote 打開 PDF，選好資料夾按「匯入」後沒有自動打開匯入的 PDF。
final class SharePDFUITests: XCTestCase {
    private func importSharedPDF(_ extra: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "zh-Hant"] + extra + ["-uiTestSharePDF"]
        app.launch()
        let importButton = app.buttons["匯入"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 20), "跳出選資料夾的視窗")
        importButton.tap()
        return app
    }

    /// 分頁列上選著的是匯入的 PDF（模擬器裡可能還有之前測試匯入的「Shared Test 2」之類，所以看開頭）
    private func sharedPDFIsShown(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let tabs = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Shared Test'"))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if tabs.allElementsBoundByIndex.contains(where: { $0.isSelected }) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        return false
    }

    /// 在資料庫裡分享進來
    func testImportingASharedPDFOpensIt() {
        let app = importSharedPDF([])
        XCTAssertTrue(app.buttons["套索"].waitForExistence(timeout: 10), "匯入完直接打開 PDF")
        XCTAssertTrue(sharedPDFIsShown(app), "目前顯示的是匯入的 PDF")
    }

    /// 筆記本開著的時候分享進來（回報的情況）：要切到匯入的 PDF，不是停在原本的筆記本
    func testImportingASharedPDFWhileANotebookIsOpenSwitchesToIt() {
        let app = importSharedPDF(["-uiTestNotebook"])
        XCTAssertTrue(sharedPDFIsShown(app), "切到匯入的 PDF")
    }
}
