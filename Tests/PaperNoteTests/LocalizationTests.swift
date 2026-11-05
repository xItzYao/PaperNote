import XCTest
@testable import PaperNote

/// 介面語言：L("中文") 查英文表、插入的值、跟隨系統的判斷
final class LocalizationTests: XCTestCase {
    private var wasEnglish = false

    override func setUp() {
        super.setUp()
        wasEnglish = Loc.isEnglish
    }

    override func tearDown() {
        Loc.isEnglish = wasEnglish
        super.tearDown()
    }

    /// 模擬器是英文系統；測試靠 -appLanguage zh-Hant 跑中文，其他測試比對的中文字串才對得上
    func testTestsRunInChinese() {
        XCTAssertFalse(Loc.isEnglish)
        XCTAssertEqual(L("取消"), "取消")
        let n = 3
        XCTAssertEqual(L("已還原 \(n) 本筆記本"), "已還原 3 本筆記本")
    }

    func testEnglishLookupFillsInTheValues() {
        Loc.isEnglish = true
        XCTAssertEqual(L("取消"), "Cancel")
        XCTAssertEqual(L("垃圾桶"), "Trash")
        let n = 3, total = 7
        XCTAssertEqual(L("已還原 \(n) 本筆記本"), "Restored 3 notebooks")
        XCTAssertEqual(L("備份中…（\(n)/\(total)）"), "Backing up… (3/7)")
        XCTAssertEqual(L("不透明度：\(50)%"), "Opacity: 50%")
        XCTAssertEqual(L("跟隨系統"), "Follow System")
    }

    func testAStringWithoutATranslationStaysChinese() {
        Loc.isEnglish = true
        XCTAssertEqual(L("表裡沒有的字串 \(1)"), "表裡沒有的字串 1")
    }

    func testPlaceholders() {
        XCTAssertEqual(Loc.fill("%2$@ before %1$@", ["a", "b"]), "b before a")
        XCTAssertEqual(Loc.fill("%@%", ["5"]), "5%")
        XCTAssertEqual(Loc.fill("100% done", []), "100% done")
        XCTAssertEqual(Loc.fill("%@ and %@", ["x"]), "x and ")
    }

    /// 英文表有載入，每個譯文都有內容，插入值的數量和中文一樣
    func testEveryTranslationIsFilledIn() throws {
        XCTAssertGreaterThan(Loc.english.count, 600)
        let ph = try NSRegularExpression(pattern: "%(?:\\d+\\$)?@")
        func count(_ s: String) -> Int { ph.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) }
        for (zh, en) in Loc.english {
            XCTAssertFalse(en.trimmingCharacters(in: .whitespaces).isEmpty, zh)
            XCTAssertEqual(count(zh), count(en), "\(zh) → \(en)")
        }
    }

    func testFollowSystemUsesChineseOnlyForAChineseSystem() {
        XCTAssertFalse(AppLanguage.system.usesEnglish(preferredLanguages: ["zh-Hant-TW", "en-US"]))
        XCTAssertFalse(AppLanguage.system.usesEnglish(preferredLanguages: ["zh-Hans-CN"]))
        XCTAssertTrue(AppLanguage.system.usesEnglish(preferredLanguages: ["en-US", "zh-Hant-TW"]))
        XCTAssertTrue(AppLanguage.system.usesEnglish(preferredLanguages: ["ja-JP"]))
        XCTAssertFalse(AppLanguage.chinese.usesEnglish(preferredLanguages: ["en-US"]))
        XCTAssertTrue(AppLanguage.english.usesEnglish(preferredLanguages: ["zh-Hant-TW"]))
    }

    /// 選單上的語言名稱：中文、English 用各自的語言寫，看不懂目前介面的人也認得
    func testLanguageNamesInTheMenu() {
        Loc.isEnglish = true
        XCTAssertEqual(AppLanguage.allCases.map(\.menuTitle), ["Follow System", "繁體中文", "English"])
        Loc.isEnglish = false
        XCTAssertEqual(AppLanguage.allCases.map(\.menuTitle), ["跟隨系統", "繁體中文", "English"])
    }
}
