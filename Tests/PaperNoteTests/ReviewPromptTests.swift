import XCTest
@testable import PaperNote

/// 需求：第二次打開 App 時請使用者寫評論，只問一次
final class ReviewPromptTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "ReviewPromptTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testAsksOnTheSecondLaunchOnly() {
        let asks = (1...5).map { _ in ReviewPrompt.recordLaunch(defaults) }
        XCTAssertEqual(asks, [false, true, false, false, false])
    }

    /// 更新前就裝過、開過很多次的人：更新後第一次打開就問（也只問一次）
    func testExistingUsersAreAskedOnce() {
        defaults.set(10, forKey: ReviewPrompt.launchesKey)
        XCTAssertTrue(ReviewPrompt.recordLaunch(defaults))
        XCTAssertFalse(ReviewPrompt.recordLaunch(defaults))
    }

    /// 測試跑起來的 App 不跳評論視窗
    func testNotAskedWhileTesting() {
        XCTAssertTrue(ReviewPrompt.isTestRun)
    }
}
