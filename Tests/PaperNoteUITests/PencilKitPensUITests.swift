import XCTest

/// 回報的問題：原子筆以外的筆（自製筆刷）寫的時候和放開後都很怪，不像 PencilKit。
/// 這些筆要交給 PencilKit 畫：真的在模擬器上寫一筆，看筆跡是不是 PencilKit 用同一種墨水畫的
final class PencilKitPensUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestNotebook", "-fingerDrawing", "<true/>", "-shapeSnap", "<false/>"]
        app.launch()
    }

    private func label(_ id: String) -> String { app.descendants(matching: .any)[id].label }

    private func waitForStrokes(_ n: Int, timeout: TimeInterval = 5) -> Bool {
        let p = NSPredicate(format: "label == %@", "\(n)")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: app.descendants(matching: .any)["pkStrokes"])], timeout: timeout) == .completed
    }

    private func write(with pen: String, y: CGFloat) {
        let b = app.buttons[pen].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 20), "要打開測試用的筆記本，工具列有「\(pen)」")
        b.tap()
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: y))
            .press(forDuration: 0.05, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: y + 0.06)),
                   withVelocity: .slow, thenHoldForDuration: 0)
    }

    func testPencilAndBrushPenAreDrawnByPencilKit() {
        write(with: "鉛筆", y: 0.35)
        XCTAssertTrue(waitForStrokes(1), "鉛筆是 PencilKit 畫的：\(label("pkStrokes"))｜\(label("debugTail"))")
        XCTAssertTrue(label("pkInk").lowercased().contains("pencil"), "PencilKit 的鉛筆墨水：\(label("pkInk"))")

        write(with: "毛筆／沾水筆", y: 0.5)
        XCTAssertTrue(waitForStrokes(2), "毛筆／沾水筆也是 PencilKit 畫的：\(label("pkStrokes"))｜\(label("debugTail"))")
        XCTAssertTrue(label("pkInk").lowercased().contains("fountain"), "PencilKit 的沾水筆墨水：\(label("pkInk"))")

        // 對照：原子筆照樣用自製筆刷（不是 PencilKit 的筆跡）。同一次啟動裡接著寫，省下重開 App 的時間
        write(with: "原子筆", y: 0.65)
        sleep(2)
        XCTAssertEqual(label("pkStrokes"), "2", "原子筆用自製筆刷畫，PencilKit 的筆跡還是兩筆：\(label("debugTail"))")
    }
}
