import XCTest
@testable import PaperNote

/// 回報的問題：頁面還在慣性捲動時筆尖已經下筆，頁面應該馬上停住
final class ScrollMomentumTests: XCTestCase {
    /// 模擬「正在慣性捲動」的捲動畫面（慣性本身沒辦法用程式觸發，用動畫捲動代替）
    private final class CoastingScrollView: UIScrollView {
        override var isDecelerating: Bool { true }
    }

    private var window: UIWindow!
    private var scroll: CoastingScrollView!

    override func setUpWithError() throws {
        window = try TestWindow.make()
        scroll = CoastingScrollView(frame: window.bounds)
        scroll.contentSize = CGSize(width: window.bounds.width, height: 50_000)
        window.addSubview(scroll)
        window.makeKeyAndVisible()
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        scroll = nil
        super.tearDown()
    }

    private func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// 開始動畫捲動，等到真的開始動就回來（量的時候動畫還在很前段，不受 CI 快慢影響）
    private func startCoasting() -> CGFloat {
        scroll.setContentOffset(CGPoint(x: 0, y: 40_000), animated: true)
        for _ in 0..<60 where scroll.contentOffset.y <= 0 { spin(1.0 / 120) }
        return scroll.contentOffset.y
    }

    func testPencilDownStopsCoasting() {
        let atPencilDown = startCoasting()
        XCTAssertGreaterThan(atPencilDown, 0, "測試前提：頁面在捲動")
        XCTAssertLessThan(atPencilDown, 39_000, "測試前提：還沒捲到底")
        scroll.stopMomentum()
        spin(0.4)
        XCTAssertEqual(scroll.contentOffset.y, atPencilDown, accuracy: 0.5, "下筆後頁面要停住")
    }

    func testDoesNothingWhenStill() {
        let still = UIScrollView(frame: window.bounds)
        still.contentSize = CGSize(width: window.bounds.width, height: 5_000)
        still.contentOffset = CGPoint(x: 0, y: 300)
        still.stopMomentum()
        XCTAssertEqual(still.contentOffset.y, 300)
    }
}

final class EraserSizeTests: XCTestCase {
    /// 小、中、大各往上調一級（原本的大變成中、中變成小）
    func testThreeSizesOneLevelUp() {
        XCTAssertEqual(EditorSettings.eraserSizes, [16, 32, 60])
        let before = UserDefaults.standard.object(forKey: "eraserWidth")
        defer { UserDefaults.standard.set(before, forKey: "eraserWidth") }
        // 舊版存的大小取最接近的
        UserDefaults.standard.set(CGFloat(8), forKey: "eraserWidth")
        XCTAssertEqual(EditorSettings.shared.eraserWidth, 16)
        UserDefaults.standard.set(CGFloat(48), forKey: "eraserWidth")
        XCTAssertEqual(EditorSettings.shared.eraserWidth, 60)
    }
}
