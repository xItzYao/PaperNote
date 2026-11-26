import XCTest

/// 回報的問題：捲到最後一頁底下輕輕往上拉、放開新增下一頁時，畫面會先往一邊、再跳回來，然後才捲到新的一頁
final class PullToAddPageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "zh-Hant", "-uiTestNotebook"]
        app.launch()
    }

    private func label(_ id: String) -> String { app.descendants(matching: .any)[id].label }
    private var offset: Int { Int(label("scrollOffset")) ?? 0 }

    func testAddingAPageByPullingScrollsStraightToIt() throws {
        XCTAssertTrue(app.descendants(matching: .any)["pageIndicator"].waitForExistence(timeout: 20), "要打開測試用的筆記本")
        let w = app.windows.firstMatch
        // 捲到最後一頁的底
        var last = -1
        for _ in 0..<30 where offset != last {
            last = offset
            w.swipeUp(velocity: .fast)
            sleep(1)
        }
        XCTAssertTrue(label("pageIndicator").hasSuffix("/ 10"), label("pageIndicator"))
        // 輕輕往上拉（慢慢拉、停一下再放開）：拉過＋出現、還沒到選紙張的距離
        let a = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let b = w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        let trace = label("scrollTrace")
        print("PULLTRACE \(trace)")
        XCTAssertTrue(trace.hasPrefix("release blankPage"), "要是輕輕拉、放開新增空白頁的距離：\(trace)")
        XCTAssertTrue(label("pageIndicator").hasSuffix("/ 11"), "放開要多一頁：\(label("pageIndicator"))")
        // 放開之後只往新的一頁那邊捲（位置越來越大），中間不能往回跳
        let ys = trace.split(separator: ",").compactMap { Int($0.split(separator: " ").last ?? "") }
        var reversals: [String] = []
        for (p, q) in zip(ys, ys.dropFirst()) where q < p - 2 { reversals.append("\(p)→\(q)") }
        XCTAssertTrue(reversals.isEmpty, "放開後往回跳：\(reversals)。整段：\(trace)")
    }
}
