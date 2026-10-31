import XCTest
@testable import PaperNote

/// 關於我：換成自己的照片；「希望大家用的開心！」後面換行
final class AboutViewTests: XCTestCase {
    func testAboutPhotoIsInTheApp() throws {
        let img = try XCTUnwrap(UIImage(named: "AboutPhoto"), "Assets 裡要有關於我的照片")
        XCTAssertEqual(img.size.width, img.size.height, "照片是正方形（裁成圓形）")
    }

    func testBlurbBreaksAfterTheGreeting() {
        let lines = AboutView.blurb.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("希望大家用的開心！"))
        XCTAssertTrue(lines[1].hasPrefix("想支持的話"))
    }
}
