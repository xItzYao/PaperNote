import XCTest

/// 上傳 TestFlight 需要的 Info.plist 設定
final class AppInfoTests: XCTestCase {
    /// 只用系統的 HTTPS（Google 雲端備份），不算需要申報的加密：上傳時不用每次手動回答出口合規
    func testDeclaresNoNonExemptEncryption() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, false)
    }

    /// TestFlight 用新版 Xcode 編譯：維持目前的介面外觀，和測試過的一樣
    func testKeepsTheCurrentDesign() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility") as? Bool, true)
    }

    func testPhotoPermissionsAreExplained() {
        for key in ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"] {
            XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").isEmpty, key)
        }
    }
}
