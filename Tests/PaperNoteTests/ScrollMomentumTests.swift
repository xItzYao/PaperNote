import XCTest
@testable import PaperNote

/// 回報的問題：頁面還在慣性捲動時筆尖已經下筆，頁面應該馬上停住
/// （慣性沒辦法用程式觸發，動畫捲動在 CI 上也不一定會動，所以直接看有沒有叫頁面停在目前的位置）
final class ScrollMomentumTests: XCTestCase {
    private final class RecordingScrollView: UIScrollView {
        var decelerating = false
        var stops: [(CGPoint, Bool)] = []
        override var isDecelerating: Bool { decelerating }
        override func setContentOffset(_ offset: CGPoint, animated: Bool) {
            stops.append((offset, animated))
            super.setContentOffset(offset, animated: animated)
        }
    }

    private func scrollView(at y: CGFloat) -> RecordingScrollView {
        let v = RecordingScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        v.contentSize = CGSize(width: 400, height: 50_000)
        v.contentOffset = CGPoint(x: 0, y: y)
        return v
    }

    func testPencilDownStopsCoasting() {
        let v = scrollView(at: 1234)
        v.decelerating = true
        v.stopMomentum()
        XCTAssertEqual(v.stops.count, 1, "還在慣性捲動：要叫它停下來")
        XCTAssertEqual(v.stops.first?.0, CGPoint(x: 0, y: 1234), "停在目前的位置")
        XCTAssertEqual(v.stops.first?.1, false, "馬上停（不要動畫）")
    }

    func testDoesNothingWhenStill() {
        let v = scrollView(at: 300)
        v.stopMomentum()
        XCTAssertTrue(v.stops.isEmpty, "沒有在捲動就什麼都不做")
        XCTAssertEqual(v.contentOffset.y, 300)
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
