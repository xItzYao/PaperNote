import XCTest
@testable import PaperNote

/// 關於我：換成自己的照片
final class AboutViewTests: XCTestCase {
    func testAboutPhotoIsInTheApp() throws {
        let img = try XCTUnwrap(UIImage(named: "AboutPhoto"), "Assets 裡要有關於我的照片")
        XCTAssertEqual(img.size.width, img.size.height, "照片是正方形（裁成圓形）")
    }

    /// 上架 1.0.0：還沒有內購贊助，App 裡不提贊助（App Store 審查指南 3.1.1）
    func testBlurbDoesNotAskForMoney() {
        XCTAssertTrue(AboutView.blurb.hasSuffix("希望大家用的開心！"))
        XCTAssertFalse(AboutView.blurb.contains("贊助"))
    }

    /// 上架：App 裡要有隱私權政策的連結
    func testPrivacyPolicyLink() {
        XCTAssertEqual(AboutView.privacyPolicyURL.absoluteString, "https://papernote.yaoyaoyao.in/privacy/")
    }

    /// 上架：隱私權清單有包進 App，用到的 required reason API 都有申報原因（沒有的話 App Store Connect 不收）
    func testPrivacyManifestIsInTheApp() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "App 裡要有隱私權清單")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var declared: [String: [String]] = [:]
        for api in apis {
            if let type = api["NSPrivacyAccessedAPIType"] as? String {
                declared[type] = api["NSPrivacyAccessedAPITypeReasons"] as? [String]
            }
        }
        XCTAssertEqual(declared["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(declared["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
    }
}
