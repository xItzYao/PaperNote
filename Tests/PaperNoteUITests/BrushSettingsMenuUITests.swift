import XCTest

/// 回報的問題（TestFlight）：修改筆刷時閃退。系統收起選單時，選單所在的畫面已經不在視窗裡
/// （-[UIPreviewTarget initWithContainer:center:transform:] 的 assertion）
final class BrushSettingsMenuUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "zh-Hant", "-uiTestNotebook", "-fingerDrawing", "<true/>"]
        app.launch()
    }

    /// 選這支筆，再點一下打開它的顏色選單（筆型在最上面）
    private func openBrushSettings(_ pen: String = "鉛筆") {
        let button = app.buttons[pen].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "要打開測試用的筆記本")
        button.tap()
        // 還不是目前的筆：第一下只選筆，再點一下才打開
        if !app.buttons["把這個顏色加進色票"].waitForExistence(timeout: 1.5) { button.tap() }
        XCTAssertTrue(app.buttons["把這個顏色加進色票"].waitForExistence(timeout: 5), "顏色選單要打開")
        XCTAssertTrue(app.buttons["penStyle.watercolor"].waitForExistence(timeout: 5), "筆型在顏色選單裡")
    }

    private func draw(y: CGFloat) {
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: y))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: y + 0.05))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0)
    }

    /// 設定一樣的情況在同一次啟動裡依序做，省下重開 App 的時間
    func testTheStyleMenu() {
        // 工具列沒有另外的筆型按鈕
        XCTAssertTrue(app.buttons["鉛筆"].firstMatch.waitForExistence(timeout: 20), "要打開測試用的筆記本")
        XCTAssertFalse(app.buttons["筆型"].exists, "筆型併回顏色選單")

        // 在顏色選單換筆型：選單還開著，筆換成水彩
        openBrushSettings()
        app.buttons["penStyle.watercolor"].tap()
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground, "選筆型：不能閃退")
        XCTAssertTrue(app.buttons["penStyle.watercolor"].isSelected, "勾著水彩")
        XCTAssertTrue(app.buttons["把這個顏色加進色票"].exists, "選單還開著，可以接著改顏色")

        // 選單開著直接在頁面上寫：選單收起（這一筆不寫），App 不能閃退
        draw(y: 0.6)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "不能閃退")
        XCTAssertTrue(app.buttons["把這個顏色加進色票"].waitForNonExistence(timeout: 5), "碰到頁面就關掉選單")
        draw(y: 0.75)
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground, "之後照常寫")

        // 改回鉛筆（筆刷存在 App 裡，之後的測試還要用「鉛筆」；工具列那支現在叫「水彩」）
        openBrushSettings("水彩")
        app.buttons["penStyle.pencil"].tap()
        sleep(1)
        XCTAssertTrue(app.buttons["penStyle.pencil"].isSelected)
        draw(y: 0.6)
        XCTAssertTrue(app.buttons["鉛筆"].firstMatch.waitForExistence(timeout: 5), "工具列的筆換回鉛筆")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
