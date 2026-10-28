import XCTest

/// 回報的問題：縮放頁面後沒辦法馬上捲動頁面
final class ZoomThenScrollUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestNotebook"]
        app.launch()
    }

    private var offset: Int { Int(app.descendants(matching: .any)["scrollOffset"].label) ?? 0 }
    private var gestureDump: String { app.descendants(matching: .any)["gestureDump"].label }

    /// 手指在畫布中間往上拖一段（慢慢拖，沒有慣性）
    private func dragUp() {
        let w = app.windows.firstMatch
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    private func assertScrollsRightAfter(_ what: String, zoom: () -> Void) {
        XCTAssertTrue(app.descendants(matching: .any)["pageIndicator"].waitForExistence(timeout: 20), "要打開測試用的筆記本")
        // 先往下捲一點，上下都有空間
        dragUp()
        sleep(1)
        zoom()
        // 縮放完馬上拖
        let before = offset
        let t = Date()
        dragUp()
        let moved = offset - before
        XCTAssertGreaterThan(moved, 50, "\(what)後馬上拖，頁面要跟著捲（只捲了 \(moved)，拖了 \(String(format: "%.1f", Date().timeIntervalSince(t)))s）。手指按下時的手勢：\(gestureDump)")
    }

    func testScrollRightAfterZoomingIn() {
        assertScrollsRightAfter("放大") {
            app.windows.firstMatch.pinch(withScale: 1.8, velocity: 2)
        }
    }

    func testScrollRightAfterZoomingOutPastTheLimit() {
        // 縮到比最小還小：放開後會彈回來
        assertScrollsRightAfter("縮小到彈回") {
            app.windows.firstMatch.pinch(withScale: 0.2, velocity: -3)
        }
    }
}
