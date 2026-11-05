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

    /// 選這支筆，再打開工具列最左邊的「筆型」選單
    private func openStyleMenu(_ pen: String = "鉛筆") {
        let button = app.buttons[pen].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 20), "要打開測試用的筆記本")
        button.tap()
        // 已經是目前的筆：點一下會打開筆刷設定，點旁邊的頁面關掉它
        if app.buttons["把這個顏色加進色票"].waitForExistence(timeout: 1.5) {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.8)).tap()
            XCTAssertTrue(app.buttons["把這個顏色加進色票"].waitForNonExistence(timeout: 5), "點旁邊關掉筆刷設定")
        }
        let picker = app.buttons["筆型"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "筆工具列最左邊是筆型")
        picker.tap()
        XCTAssertTrue(app.descendants(matching: .any)["水彩"].waitForExistence(timeout: 5), "筆型選單要打開")
    }

    private func draw(y: CGFloat) {
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: y))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: y + 0.05))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0)
    }

    /// 設定一樣的情況在同一次啟動裡依序做，省下重開 App 的時間
    func testTheStyleMenu() {
        // 筆型選單開著，直接在畫布上寫：選單收起，App 不能閃退
        openStyleMenu()
        draw(y: 0.6)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "不能閃退")
        XCTAssertTrue(app.buttons["鉛筆"].exists, "還在筆記本裡")
        draw(y: 0.75)
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground, "之後照常寫")

        // 回報的版本每支筆都用自製筆刷：選單開著時用自製筆刷寫
        openStyleMenu("原子筆")
        draw(y: 0.6)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "自製筆刷：不能閃退")
        XCTAssertTrue(app.buttons["原子筆"].firstMatch.exists, "自製筆刷：還在筆記本裡")
        draw(y: 0.75)
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground, "自製筆刷：之後照常寫")

        // 選一個筆型：選單收起，工具列的筆型跟著換
        openStyleMenu()
        app.descendants(matching: .any)["水彩"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "選筆型：不能閃退")
        let picker = app.buttons["筆型"].firstMatch
        XCTAssertEqual(picker.value as? String, "水彩", "工具列的筆型換成水彩")
        // 改回鉛筆（筆刷存在 App 裡，之後的測試還要用「鉛筆」；工具列那支現在叫「水彩」，選單裡的才是「鉛筆」）
        picker.tap()
        let pencil = app.descendants(matching: .any)["鉛筆"].firstMatch
        XCTAssertTrue(pencil.waitForExistence(timeout: 5))
        pencil.tap()
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(picker.value as? String, "鉛筆")
    }
}
