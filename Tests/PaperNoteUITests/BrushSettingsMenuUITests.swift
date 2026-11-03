import XCTest

/// 回報的問題（TestFlight）：修改筆刷時閃退。系統收起選單時，選單所在的畫面已經不在視窗裡
/// （-[UIPreviewTarget initWithContainer:center:transform:] 的 assertion）
final class BrushSettingsMenuUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestNotebook", "-fingerDrawing", "<true/>"]
        app.launch()
    }

    /// 打開鉛筆的筆刷設定，再打開「筆型」選單
    private func openStyleMenu() {
        let pencil = app.buttons["鉛筆"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 20), "要打開測試用的筆記本")
        pencil.tap()
        sleep(1)
        pencil.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "筆型")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "再點一下打開筆刷設定")
        picker.tap()
        XCTAssertTrue(app.descendants(matching: .any)["水彩"].waitForExistence(timeout: 5), "筆型選單要打開")
    }

    private func draw(y: CGFloat) {
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: y))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: y + 0.05))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0)
    }

    /// 筆型選單開著，直接在畫布上寫：筆刷設定關掉、選單收起，App 不能閃退
    func testWritingWithTheStyleMenuOpen() {
        openStyleMenu()
        draw(y: 0.6)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "不能閃退")
        XCTAssertTrue(app.buttons["鉛筆"].exists, "還在筆記本裡")
        draw(y: 0.75)
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground, "之後照常寫")
    }

    /// 選一個筆型：選單收起，筆刷設定還開著
    func testPickingAStyle() {
        openStyleMenu()
        app.descendants(matching: .any)["水彩"].firstMatch.tap()
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "不能閃退")
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "筆型")).firstMatch
        XCTAssertTrue(picker.exists, "筆刷設定還開著")
    }
}
