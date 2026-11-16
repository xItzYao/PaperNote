import XCTest

/// 回報的問題：從「檔案」用分享的方式以 PaperNote 打開 PDF，選好資料夾按「匯入」後沒有自動打開匯入的 PDF。
/// 之前是按下去 0.45 秒後就打開筆記本，選資料夾的視窗還沒收完，全螢幕的筆記本跳不出來
final class SharePDFUITests: XCTestCase {
    func testImportingASharedPDFOpensIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "zh-Hant", "-uiTestSharePDF"]
        app.launch()
        let importButton = app.buttons["匯入"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 20), "跳出選資料夾的視窗")
        importButton.tap()
        XCTAssertTrue(app.buttons["套索"].waitForExistence(timeout: 10), "匯入完直接打開 PDF")
    }
}
